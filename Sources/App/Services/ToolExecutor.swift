import Foundation

/// Executes agent tools with proper error handling and JSON formatting
@MainActor
class ToolExecutor {
    private let calendarService: CalendarService
    private let remindersService: RemindersService
    private let appViewModel: AppViewModel
    private let currentProjectID: UUID?
    
    init(
        calendarService: CalendarService,
        remindersService: RemindersService,
        appViewModel: AppViewModel,
        currentProjectID: UUID?
    ) {
        self.calendarService = calendarService
        self.remindersService = remindersService
        self.appViewModel = appViewModel
        self.currentProjectID = currentProjectID
    }
    
    /// Execute a tool by name with JSON arguments
    func execute(toolName: String, arguments: String) async -> String {
        do {
            let result = try await executeInternal(toolName: toolName, arguments: arguments)
            return result
        } catch {
            return errorResponse(error: error)
        }
    }
    
    private func executeInternal(toolName: String, arguments: String) async throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard let argsData = arguments.data(using: .utf8) else {
            throw ToolError.invalidArguments("Could not parse arguments as UTF-8")
        }
        
        switch toolName {
        // MARK: - Calendar Tools
        
        case "list_calendar_events":
            // Request authorization if needed
            if !calendarService.isAuthorized {
                let granted = await calendarService.requestAccess()
                if !granted {
                    throw ToolError.authorizationDenied("Calendar access was denied. Please grant permission in System Settings.")
                }
            }
            
            let args = try decoder.decode(ListEventsArgs.self, from: argsData)
            let formatter = ISO8601DateFormatter()
            
            guard let startDate = formatter.date(from: args.start_date) else {
                throw ToolError.invalidArguments("Invalid start_date format")
            }
            guard let endDate = formatter.date(from: args.end_date) else {
                throw ToolError.invalidArguments("Invalid end_date format")
            }
            
            let events = try await calendarService.listEvents(from: startDate, to: endDate)
            return formatEventsAsJSON(events)
            
        case "search_calendar_events":
            // Request authorization if needed
            if !calendarService.isAuthorized {
                let granted = await calendarService.requestAccess()
                if !granted {
                    throw ToolError.authorizationDenied("Calendar access was denied. Please grant permission in System Settings.")
                }
            }
            
            let args = try decoder.decode(SearchEventsArgs.self, from: argsData)
            let formatter = ISO8601DateFormatter()
            
            // Determine start date
            let startDate: Date
            if let startStr = args.start_date, let date = formatter.date(from: startStr) {
                startDate = date
            } else {
                startDate = Date()  // Default to today
            }
            
            // Determine end date
            let endDate: Date
            if let endStr = args.end_date, let date = formatter.date(from: endStr) {
                endDate = date
            } else if let daysAhead = args.days_ahead {
                endDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: startDate) ?? startDate
            } else {
                // Default to 7 days ahead
                endDate = Calendar.current.date(byAdding: .day, value: 7, to: startDate) ?? startDate
            }
            
            let events = try await calendarService.listEvents(from: startDate, to: endDate)
            return formatEventsAsJSON(events)
            
        case "create_calendar_event":
            // Request authorization if needed
            if !calendarService.isAuthorized {
                let granted = await calendarService.requestAccess()
                if !granted {
                    throw ToolError.authorizationDenied("Calendar access was denied. Please grant permission in System Settings.")
                }
            }
            
            let args = try decoder.decode(CreateEventArgs.self, from: argsData)
            let formatter = ISO8601DateFormatter()
            
            guard let startDate = formatter.date(from: args.start_date) else {
                throw ToolError.invalidArguments("Invalid start_date format")
            }
            guard let endDate = formatter.date(from: args.end_date) else {
                throw ToolError.invalidArguments("Invalid end_date format")
            }
            
            let eventURL = args.url.flatMap { URL(string: $0) }
            
            let eventID = try await calendarService.createEvent(
                title: args.title,
                startDate: startDate,
                endDate: endDate,
                location: args.location,
                notes: args.notes,
                url: eventURL,
                isAllDay: args.is_all_day ?? false,
                alertMinutesBefore: args.alert_minutes_before
            )
            
            return """
            {
                "success": true,
                "event_id": "\(eventID)",
                "message": "Calendar event '\(args.title)' created successfully"
            }
            """
            
        case "delete_calendar_event":
            // Request authorization if needed
            if !calendarService.isAuthorized {
                let granted = await calendarService.requestAccess()
                if !granted {
                    throw ToolError.authorizationDenied("Calendar access was denied. Please grant permission in System Settings.")
                }
            }
            
            let args = try decoder.decode(DeleteEventArgs.self, from: argsData)
            
            do {
                try calendarService.deleteEvent(withID: args.event_id)
                return """
                {
                    "success": true,
                    "message": "Calendar event deleted successfully"
                }
                """
            } catch {
                throw ToolError.custom("Failed to delete calendar event: \(error.localizedDescription)")
            }
            
        // MARK: - Project Tools
        
        case "list_projects":
            // Load all projects
            let projects = try appViewModel.projectStore.loadProjects()
            
            if projects.isEmpty {
                return """
                {
                    "success": true,
                    "projects": [],
                    "count": 0,
                    "message": "No projects found"
                }
                """
            }
            
            let projectsList = projects.map { project in
                """
                {
                    "id": "\(project.id.uuidString)",
                    "name": "\(escapeJSON(project.name))",
                    "color": "\(project.colorHex)"
                }
                """
            }.joined(separator: ",\n                ")
            
            return """
            {
                "success": true,
                "count": \(projects.count),
                "projects": [
                \(projectsList)
                ]
            }
            """
            
        // MARK: - Task Tools
        
        case "list_project_tasks":
            let args = try decoder.decode(ListTasksArgs.self, from: argsData)
            
            // Determine which project to query
            let targetProjectID: UUID
            if let projectIDStr = args.project_id, let uuid = UUID(uuidString: projectIDStr) {
                targetProjectID = uuid
            } else if let currentID = currentProjectID {
                targetProjectID = currentID
            } else {
                throw ToolError.custom("No project specified. Use list_projects to find a project, then provide its project_id.")
            }
            
            // Load all tasks
            let allTasks = try appViewModel.projectStore.loadTasks()
            
            // Filter to target project
            var projectTasks = allTasks.filter { $0.projectID == targetProjectID }
            
            // Optionally filter out completed tasks
            if args.include_completed == false || args.include_completed == nil {
                projectTasks = projectTasks.filter { !$0.isCompleted }
            }
            
            return formatTasksAsJSON(projectTasks)
        
        case "create_project_task":
            let args = try decoder.decode(CreateTaskArgs.self, from: argsData)
            
            // Determine which project to use
            let targetProjectID: UUID
            if let projectIDStr = args.project_id, let uuid = UUID(uuidString: projectIDStr) {
                targetProjectID = uuid
            } else if let currentID = currentProjectID {
                targetProjectID = currentID
            } else {
                throw ToolError.custom("No project specified. Use list_projects to find a project, then provide its project_id.")
            }
            
            // Validate project exists
            let projects = try appViewModel.projectStore.loadProjects()
            guard projects.contains(where: { $0.id == targetProjectID }) else {
                throw ToolError.projectNotFound
            }
            
            // Load tasks
            var tasks = try appViewModel.projectStore.loadTasks()
            
            // Parse priority
            let priority: TaskPriority
            if let priorityStr = args.priority?.lowercased() {
                switch priorityStr {
                case "low": priority = .low
                case "medium": priority = .medium
                case "high": priority = .high
                case "critical": priority = .critical
                default: priority = .medium
                }
            } else {
                priority = .medium
            }
            
            // Parse due date
            var dueDate: Date? = nil
            var hasDueTime = false
            if let dueDateStr = args.due_date {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: dueDateStr) {
                    dueDate = date
                    hasDueTime = dueDateStr.contains("T")
                }
            }
            
            // Parse status
            var taskStatus: TaskStatus? = nil
            if let statusStr = args.status {
                taskStatus = TaskStatus(rawValue: statusStr)
            }

            // Parse epic ID
            var epicID: UUID? = nil
            if let epicIDStr = args.epic_id {
                epicID = UUID(uuidString: epicIDStr)
            }

            // Create task
            let newTask = ProjectTask(
                id: UUID(),
                projectID: targetProjectID,
                title: args.title,
                notes: args.description ?? "",
                isCompleted: taskStatus == .done,
                completedAt: taskStatus == .done ? Date() : nil,
                assignee: nil,
                dueDate: dueDate,
                hasDueTime: hasDueTime,
                priority: priority,
                reminderID: nil,
                status: taskStatus,
                epicID: epicID
            )
            
            tasks.append(newTask)
            appViewModel.projectStore.debouncedSaveTasks(tasks)
            
            // Reload tasks in AppViewModel to update UI
            appViewModel.reloadTasks()
            
            return """
            {
                "success": true,
                "task_id": "\(newTask.id.uuidString)",
                "message": "Task '\(args.title)' created successfully in project"
            }
            """        
        case "update_project_task":
            let args = try decoder.decode(UpdateTaskArgs.self, from: argsData)
            
            // Determine which project to use
            let targetProjectID: UUID
            if let projectIDStr = args.project_id, let uuid = UUID(uuidString: projectIDStr) {
                targetProjectID = uuid
            } else if let currentID = currentProjectID {
                targetProjectID = currentID
            } else {
                throw ToolError.custom("No project specified. Use list_projects to find a project, then provide its project_id.")
            }
            
            // Parse task UUID
            guard let taskUUID = UUID(uuidString: args.task_id) else {
                throw ToolError.invalidArguments("Invalid task_id format")
            }
            
            // Load tasks
            var tasks = try appViewModel.projectStore.loadTasks()
            
            // Find the task
            guard let taskIndex = tasks.firstIndex(where: { $0.id == taskUUID && $0.projectID == targetProjectID }) else {
                throw ToolError.invalidArguments("Task not found in specified project")
            }
            
            var task = tasks[taskIndex]
            
            // Update fields if provided
            if let title = args.title {
                task.title = title
            }
            
            if let description = args.description {
                task.notes = description
            }
            
            if let priorityStr = args.priority?.lowercased() {
                switch priorityStr {
                case "low": task.priority = .low
                case "medium": task.priority = .medium
                case "high": task.priority = .high
                case "critical": task.priority = .critical
                default: break
                }
            }
            
            if let dueDateStr = args.due_date {
                if dueDateStr.isEmpty {
                    // Remove due date
                    task.dueDate = nil
                    task.hasDueTime = false
                } else {
                    let formatter = ISO8601DateFormatter()
                    if let date = formatter.date(from: dueDateStr) {
                        task.dueDate = date
                        task.hasDueTime = dueDateStr.contains("T")
                    }
                }
            }
            
            if let isCompleted = args.is_completed {
                task.isCompleted = isCompleted
            }
            
            if let assignee = args.assignee {
                task.assignee = assignee.isEmpty ? nil : assignee
            }

            if let statusStr = args.status, let newStatus = TaskStatus(rawValue: statusStr) {
                task.status = newStatus
                if newStatus == .done {
                    task.isCompleted = true
                    task.completedAt = task.completedAt ?? Date()
                } else {
                    task.isCompleted = false
                    task.completedAt = nil
                }
            }

            if let epicIDStr = args.epic_id {
                task.epicID = epicIDStr.isEmpty ? nil : UUID(uuidString: epicIDStr)
            }

            // Save updated tasks
            tasks[taskIndex] = task
            appViewModel.projectStore.debouncedSaveTasks(tasks)
            
            // Reload tasks in AppViewModel to update UI
            appViewModel.reloadTasks()
            
            return """
            {
                "success": true,
                "task_id": "\(task.id.uuidString)",
                "message": "Task '\(task.title)' updated successfully"
            }
            """
            
        case "delete_project_task":
            let args = try decoder.decode(DeleteTaskArgs.self, from: argsData)
            
            // Determine which project to use
            let targetProjectID: UUID
            if let projectIDStr = args.project_id, let uuid = UUID(uuidString: projectIDStr) {
                targetProjectID = uuid
            } else if let currentID = currentProjectID {
                targetProjectID = currentID
            } else {
                throw ToolError.custom("No project specified. Use list_projects to find a project, then provide its project_id.")
            }
            
            // Parse task UUID
            guard let taskUUID = UUID(uuidString: args.task_id) else {
                throw ToolError.invalidArguments("Invalid task_id format")
            }
            
            // Load tasks
            var tasks = try appViewModel.projectStore.loadTasks()
            
            // Find the task
            guard let taskIndex = tasks.firstIndex(where: { $0.id == taskUUID && $0.projectID == targetProjectID }) else {
                throw ToolError.invalidArguments("Task not found in specified project")
            }
            
            let taskTitle = tasks[taskIndex].title
            
            // Remove the task
            tasks.remove(at: taskIndex)
            appViewModel.projectStore.debouncedSaveTasks(tasks)
            
            // Reload tasks in AppViewModel to update UI
            appViewModel.reloadTasks()
            
            return """
            {
                "success": true,
                "task_id": "\(taskUUID.uuidString)",
                "message": "Task '\(taskTitle)' deleted successfully"
            }
            """            
        // MARK: - Epic & Board Tools

        case "list_project_epics":
            let args = try decoder.decode(ListEpicsArgs.self, from: argsData)

            let targetProjectID: UUID
            if let projectIDStr = args.project_id, let uuid = UUID(uuidString: projectIDStr) {
                targetProjectID = uuid
            } else if let currentID = currentProjectID {
                targetProjectID = currentID
            } else {
                throw ToolError.custom("No project specified.")
            }

            let epics = appViewModel.epicsForProject(targetProjectID)
            let items = epics.map { epic -> String in
                let taskCount = appViewModel.tasks.filter { $0.epicID == epic.id }.count
                return """
                {"id": "\(epic.id.uuidString)", "title": "\(epic.title)", "summary": "\(epic.summary)", "color": "\(epic.colorHex)", "task_count": \(taskCount)}
                """
            }
            return "[\(items.joined(separator: ","))]"

        case "create_project_epic":
            let args = try decoder.decode(CreateEpicArgs.self, from: argsData)

            let targetProjectID: UUID
            if let projectIDStr = args.project_id, let uuid = UUID(uuidString: projectIDStr) {
                targetProjectID = uuid
            } else if let currentID = currentProjectID {
                targetProjectID = currentID
            } else {
                throw ToolError.custom("No project specified.")
            }

            let colorHex = args.color_hex ?? Project.defaultColors.randomElement() ?? "#007AFF"
            appViewModel.createEpic(
                title: args.title,
                projectID: targetProjectID,
                colorHex: colorHex,
                summary: args.summary ?? ""
            )

            return """
            {"success": true, "message": "Epic '\(args.title)' created successfully"}
            """

        case "get_board_summary":
            let args = try decoder.decode(BoardSummaryArgs.self, from: argsData)

            let targetProjectID: UUID
            if let projectIDStr = args.project_id, let uuid = UUID(uuidString: projectIDStr) {
                targetProjectID = uuid
            } else if let currentID = currentProjectID {
                targetProjectID = currentID
            } else {
                throw ToolError.custom("No project specified.")
            }

            let allTasks = appViewModel.tasksForProject(targetProjectID)
            let statusCounts = Dictionary(grouping: allTasks, by: { $0.effectiveStatus })
            let overdue = allTasks.filter { task in
                guard let due = task.dueDate else { return false }
                return due < Date() && !task.isCompleted
            }
            let epics = appViewModel.epicsForProject(targetProjectID)

            var result = """
            {
                "total_tasks": \(allTasks.count),
                "columns": {
            """
            for (i, status) in TaskStatus.allCases.enumerated() {
                result += "        \"\(status.rawValue)\": \(statusCounts[status]?.count ?? 0)"
                if i < TaskStatus.allCases.count - 1 { result += "," }
                result += "\n"
            }
            result += "    },\n    \"overdue_count\": \(overdue.count)"

            if !epics.isEmpty {
                result += ",\n    \"epics\": ["
                for (i, epic) in epics.enumerated() {
                    let epicTasks = allTasks.filter { $0.epicID == epic.id }
                    let done = epicTasks.filter { $0.effectiveStatus == .done }.count
                    result += "{\"title\": \"\(epic.title)\", \"done\": \(done), \"total\": \(epicTasks.count)}"
                    if i < epics.count - 1 { result += "," }
                }
                result += "]"
            }
            result += "\n}"
            return result

        // MARK: - Reminder Tools

        case "list_reminders":
            // Request authorization if needed
            if !remindersService.isAuthorized {
                let granted = await remindersService.requestAccess()
                if !granted {
                    throw ToolError.authorizationDenied("Reminders access was denied. Please grant permission in System Settings.")
                }
            }
            
            let args = try decoder.decode(ListRemindersArgs.self, from: argsData)
            
            let reminders = try await remindersService.listReminders(
                includeCompleted: args.include_completed ?? false,
                listName: args.list_name,
                daysAhead: args.days_ahead
            )
            
            return formatRemindersAsJSON(reminders)
        
        case "create_reminder":
            // Request authorization if needed
            if !remindersService.isAuthorized {
                let granted = await remindersService.requestAccess()
                if !granted {
                    throw ToolError.authorizationDenied("Reminders access was denied. Please grant permission in System Settings.")
                }
            }
            
            let args = try decoder.decode(CreateReminderArgs.self, from: argsData)
            
            // Parse due date
            var dueDate: Date? = nil
            if let dueDateStr = args.due_date {
                let formatter = ISO8601DateFormatter()
                dueDate = formatter.date(from: dueDateStr)
            }
            
            let reminderID = try await remindersService.createReminder(
                title: args.title,
                notes: args.notes,
                dueDate: dueDate,
                priority: args.priority,
                listName: args.list_name
            )
            
            return """
            {
                "success": true,
                "reminder_id": "\(reminderID)",
                "message": "Reminder '\(args.title)' created successfully in Apple Reminders"
            }
            """
            
        case "delete_reminder":
            // Request authorization if needed
            if !remindersService.isAuthorized {
                let granted = await remindersService.requestAccess()
                if !granted {
                    throw ToolError.authorizationDenied("Reminders access was denied. Please grant permission in System Settings.")
                }
            }
            
            let args = try decoder.decode(DeleteReminderArgs.self, from: argsData)
            
            do {
                try await remindersService.deleteReminder(withID: args.reminder_id)
                return """
                {
                    "success": true,
                    "message": "Reminder deleted successfully from Apple Reminders"
                }
                """
            } catch {
                throw ToolError.custom("Failed to delete reminder: \(error.localizedDescription)")
            }
            
        case "commit_to_knowledge_base":
            let args = try decoder.decode(CommitToKnowledgeBaseArgs.self, from: argsData)
            
            // Determine which project to use
            let targetProjectID: UUID?
            if let projectIDStr = args.project_id, let uuid = UUID(uuidString: projectIDStr) {
                targetProjectID = uuid
            } else if let currentID = currentProjectID {
                targetProjectID = currentID
            } else {
                targetProjectID = nil  // Save globally if no project context
            }
            
            // Knowledge lives as files in the project's workspace (General without a project);
            // the search index follows the file.
            let path = await appViewModel.commitKnowledgeToWorkspace(
                title: args.title, category: args.category, content: args.content, projectID: targetProjectID)
            return """
            {
                "success": true,
                "file": "\(escapeJSON(path))",
                "message": "Knowledge saved to the workspace file \(escapeJSON(path)). Title: '\(escapeJSON(args.title))', Category: '\(escapeJSON(args.category))'"
            }
            """
            
        // MARK: - Web Search & Fetch Tools
            
        case "web_search":
            let args = try decoder.decode(WebSearchArgs.self, from: argsData)
            
            do {
                let response = try await WebSearchService.search(
                    query: args.query,
                    resultCount: args.result_count ?? 5
                )
                
                // Format results as JSON
                let resultsJSON = response.results.map { result in
                    """
                    {
                        "title": "\(escapeJSON(result.title))",
                        "url": "\(escapeJSON(result.url))",
                        "snippet": "\(escapeJSON(result.snippet))"
                    }
                    """
                }.joined(separator: ",\n                ")
                
                return """
                {
                    "success": true,
                    "query": "\(escapeJSON(response.query))",
                    "count": \(response.results.count),
                    "results": [
                \(resultsJSON)
                    ],
                    "message": "Found \(response.results.count) results for '\(escapeJSON(response.query))'. Use fetch_webpage to get full content from any URL."
                }
                """
            } catch {
                throw ToolError.custom("Web search failed: \(error.localizedDescription)")
            }
            
        case "fetch_webpage":
            let args = try decoder.decode(FetchWebpageArgs.self, from: argsData)
            
            // Ensure HTTPS for App Transport Security (ATS) compliance
            var urlString = args.url.trimmingCharacters(in: .whitespaces)
            if urlString.hasPrefix("http://") {
                urlString = urlString.replacingOccurrences(of: "http://", with: "https://")
            } else if !urlString.hasPrefix("https://") {
                urlString = "https://" + urlString
            }
            
            guard let url = URL(string: urlString) else {
                throw ToolError.invalidArguments("Invalid URL format: \(args.url)")
            }
            
            do {
                let content = try await WebSearchService.fetchWebpage(
                    url: url,
                    maxLength: args.max_length ?? 8000
                )
                
                return """
                {
                    "success": true,
                    "url": "\(escapeJSON(urlString))",
                    "content": "\(escapeJSON(content))",
                    "length": \(content.count),
                    "message": "Successfully fetched content from \(escapeJSON(url.host ?? "webpage")). Consider saving important information to knowledge base."
                }
                """
            } catch let error as URLError {
                let errorMsg: String
                switch error.code {
                case .cannotFindHost, .dnsLookupFailed:
                    errorMsg = "Cannot find host \(url.host ?? "unknown"). The domain may not exist or may not be publicly accessible."
                case .notConnectedToInternet:
                    errorMsg = "Not connected to the internet. Please check your network connection."
                case .timedOut:
                    errorMsg = "Request timed out. The server at \(url.host ?? "unknown") did not respond."
                case .secureConnectionFailed:
                    errorMsg = "Secure connection failed. The server may not support HTTPS properly."
                case .appTransportSecurityRequiresSecureConnection:
                    errorMsg = "App Transport Security requires HTTPS. The URL was upgraded to HTTPS but the server doesn't support it."
                default:
                    errorMsg = "Network error: \(error.localizedDescription)"
                }
                throw ToolError.custom("Failed to fetch \(url.host ?? "webpage"): \(errorMsg)")
            } catch {
                throw ToolError.custom("Failed to fetch webpage: \(error.localizedDescription)")
            }
            
        // MARK: - Notes Tools

        case "list_notes":
            let args = try? decoder.decode(ListNotesArgs.self, from: argsData)
            let projectID = args?.project_id.flatMap { UUID(uuidString: $0) } ?? currentProjectID
            let notes: [EventNote]
            if let pid = projectID {
                notes = appViewModel.notesForProject(pid)
            } else {
                notes = appViewModel.eventNotes
            }
            return formatNotesAsJSON(notes, context: projectID == nil ? "all projects" : nil)

        case "search_notes":
            let args = try decoder.decode(SearchNotesArgs.self, from: argsData)
            let projectID = args.project_id.flatMap { UUID(uuidString: $0) } ?? currentProjectID
            let pool: [EventNote]
            if let pid = projectID {
                pool = appViewModel.notesForProject(pid)
            } else {
                pool = appViewModel.eventNotes
            }
            let q = args.query.lowercased()
            let matched = pool.filter {
                $0.eventTitle.lowercased().contains(q) || $0.content.lowercased().contains(q)
            }
            return formatNotesAsJSON(matched, query: args.query)

        case "create_note":
            let args = try decoder.decode(CreateNoteArgs.self, from: argsData)
            let projectID = args.project_id.flatMap { UUID(uuidString: $0) } ?? currentProjectID
            var note = EventNote(title: args.title, projectId: projectID)
            note.content = args.content ?? ""
            note.tags = args.tags ?? []
            appViewModel.upsertNote(note)
            return """
            {
                "success": true,
                "note_id": "\(note.id.uuidString)",
                "title": "\(escapeJSON(note.eventTitle))",
                "message": "Note created successfully"
            }
            """

        case "update_note":
            let args = try decoder.decode(UpdateNoteArgs.self, from: argsData)
            guard let noteID = UUID(uuidString: args.note_id) else {
                throw ToolError.invalidArguments("note_id is not a valid UUID")
            }
            guard var note = appViewModel.eventNotes.first(where: { $0.id == noteID }) else {
                throw ToolError.custom("Note not found with id: \(args.note_id)")
            }
            if let title = args.title { note.eventTitle = title }
            if let content = args.content { note.content = content }
            if let tags = args.tags { note.tags = tags }
            appViewModel.upsertNote(note)
            return """
            {
                "success": true,
                "note_id": "\(note.id.uuidString)",
                "title": "\(escapeJSON(note.eventTitle))",
                "message": "Note updated successfully"
            }
            """

        case "delete_note":
            let args = try decoder.decode(DeleteNoteArgs.self, from: argsData)
            guard let noteID = UUID(uuidString: args.note_id) else {
                throw ToolError.invalidArguments("note_id is not a valid UUID")
            }
            guard let note = appViewModel.eventNotes.first(where: { $0.id == noteID }) else {
                throw ToolError.custom("Note not found with id: \(args.note_id)")
            }
            appViewModel.deleteNote(note)
            return """
            {
                "success": true,
                "message": "Note '\(escapeJSON(note.eventTitle))' deleted successfully"
            }
            """

        default:
            throw ToolError.unknownTool(toolName)
        }
    }
    
    // MARK: - Notes Formatting

    private func formatNotesAsJSON(_ notes: [EventNote], context: String? = nil, query: String? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        if notes.isEmpty {
            let msg = query != nil
                ? "No notes matched '\(escapeJSON(query!))'"
                : "No notes found"
            return """
            {
                "success": true,
                "count": 0,
                "notes": [],
                "message": "\(msg)"
            }
            """
        }
        let notesJSON = notes.map { note -> String in
            let tagsJSON = note.tags.map { "\"\(escapeJSON($0))\"" }.joined(separator: ", ")
            let preview = String(note.content.prefix(200)).replacingOccurrences(of: "\n", with: " ")
            return """
            {
                "note_id": "\(note.id.uuidString)",
                "title": "\(escapeJSON(note.eventTitle))",
                "content_preview": "\(escapeJSON(preview))",
                "tags": [\(tagsJSON)],
                "is_manual": \(note.isManual),
                "project_id": \(note.projectId.map { "\"\($0.uuidString)\"" } ?? "null"),
                "created_at": "\(formatter.string(from: note.createdAt))",
                "updated_at": "\(formatter.string(from: note.updatedAt))"
            }
            """
        }.joined(separator: ",\n            ")
        return """
        {
            "success": true,
            "count": \(notes.count),
            "notes": [
                \(notesJSON)
            ]
        }
        """
    }

    // MARK: - Formatting Helpers
    
    private func formatEventsAsJSON(_ events: [CalendarEvent]) -> String {
        if events.isEmpty {
            return """
            {
                "success": true,
                "count": 0,
                "events": [],
                "message": "No events found"
            }
            """
        }
        
        let formatter = ISO8601DateFormatter()
        let eventsJSON = events.map { event in
            var json = """
            {
                "id": "\(event.id)",
                "title": "\(escapeJSON(event.title))",
                "start": "\(formatter.string(from: event.startDate))",
                "end": "\(formatter.string(from: event.endDate))",
                "is_all_day": \(event.isAllDay)
            """
            
            if let calendar = event.calendarTitle {
                json += ",\n                \"calendar\": \"\(escapeJSON(calendar))\""
            }
            
            if let location = event.location {
                json += ",\n                \"location\": \"\(escapeJSON(location))\""
            }
            
            if let notes = event.notes {
                json += ",\n                \"notes\": \"\(escapeJSON(notes))\""
            }
            
            if let url = event.url {
                json += ",\n                \"url\": \"\(escapeJSON(url.absoluteString))\""
            }
            
            json += "\n            }"
            return json
        }.joined(separator: ",\n            ")
        
        return """
        {
            "success": true,
            "count": \(events.count),
            "events": [
            \(eventsJSON)
            ]
        }
        """
    }
    
    private func formatTasksAsJSON(_ tasks: [ProjectTask]) -> String {
        if tasks.isEmpty {
            return """
            {
                "success": true,
                "count": 0,
                "tasks": [],
                "message": "No tasks found"
            }
            """
        }
        
        let formatter = ISO8601DateFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        let tasksJSON = tasks.map { task in
            let priorityStr = task.priority?.displayName.lowercased() ?? "medium"
            var json = """
            {
                "id": "\(task.id.uuidString)",
                "title": "\(escapeJSON(task.title))",
                "is_completed": \(task.isCompleted),
                "priority": "\(priorityStr)"
            """
            
            if !task.notes.isEmpty {
                json += ",\n                \"notes\": \"\(escapeJSON(task.notes))\""
            }
            
            if let dueDate = task.dueDate {
                json += ",\n                \"due_date\": \"\(formatter.string(from: dueDate))\""
                json += ",\n                \"due_date_formatted\": \"\(dateFormatter.string(from: dueDate))\""
                json += ",\n                \"has_due_time\": \(task.hasDueTime)"
            }
            
            if let assignee = task.assignee {
                json += ",\n                \"assignee\": \"\(escapeJSON(assignee))\""
            }

            if let sessionID = task.sourceSessionID {
                json += ",\n                \"source_session_id\": \"\(sessionID.uuidString)\""
                // Include session title for context
                if let session = appViewModel.sessions.first(where: { $0.id == sessionID }) {
                    json += ",\n                \"source_session_title\": \"\(escapeJSON(session.title))\""
                }
            }

            if let kbDocIDs = task.knowledgeDocumentIDs, !kbDocIDs.isEmpty {
                let idsJSON = kbDocIDs.map { "\($0)" }.joined(separator: ", ")
                json += ",\n                \"knowledge_document_ids\": [\(idsJSON)]"
            }

            if let status = task.status {
                json += ",\n                \"status\": \"\(status.rawValue)\""
            }

            if task.needsReview == true {
                json += ",\n                \"needs_review\": true"
            }

            json += "\n            }"
            return json
        }.joined(separator: ",\n            ")
        
        return """
        {
            "success": true,
            "count": \(tasks.count),
            "tasks": [
            \(tasksJSON)
            ]
        }
        """
    }
    
    private func formatRemindersAsJSON(_ reminders: [ReminderInfo]) -> String {
        if reminders.isEmpty {
            return """
            {
                "success": true,
                "count": 0,
                "reminders": [],
                "message": "No reminders found"
            }
            """
        }
        
        let formatter = ISO8601DateFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        let remindersJSON = reminders.map { reminder in
            var json = """
            {
                "id": "\(reminder.id)",
                "title": "\(escapeJSON(reminder.title))",
                "is_completed": \(reminder.isCompleted),
                "list_name": "\(escapeJSON(reminder.listName))",
                "priority": \(reminder.priority)
            """
            
            if let notes = reminder.notes, !notes.isEmpty {
                json += ",\n                \"notes\": \"\(escapeJSON(notes))\""
            }
            
            if let dueDate = reminder.dueDate {
                json += ",\n                \"due_date\": \"\(formatter.string(from: dueDate))\""
                json += ",\n                \"due_date_formatted\": \"\(dateFormatter.string(from: dueDate))\""
            }
            
            if let creationDate = reminder.creationDate {
                json += ",\n                \"creation_date\": \"\(formatter.string(from: creationDate))\""
            }
            
            if let completionDate = reminder.completionDate {
                json += ",\n                \"completion_date\": \"\(formatter.string(from: completionDate))\""
            }
            
            json += "\n            }"
            return json
        }.joined(separator: ",\n            ")
        
        return """
        {
            "success": true,
            "count": \(reminders.count),
            "reminders": [
            \(remindersJSON)
            ]
        }
        """
    }
    
    private func escapeJSON(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
    
    
    private func errorResponse(error: Error) -> String {
        let message = escapeJSON(error.localizedDescription)
        return """
        {
            "success": false,
            "error": "\(message)"
        }
        """
    }
}

// MARK: - Errors

enum ToolError: Error, LocalizedError {
    case unknownTool(String)
    case invalidArguments(String)
    case noProjectContext
    case projectNotFound
    case authorizationDenied(String)
    case custom(String)
    
    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .invalidArguments(let detail):
            return "Invalid arguments: \(detail)"
        case .noProjectContext:
            return "No project context available. This tool requires an active project."
        case .projectNotFound:
            return "Project not found"
        case .authorizationDenied(let message):
            return message
        case .custom(let message):
            return message
        }
    }
}
