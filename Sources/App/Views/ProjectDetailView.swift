import SwiftUI
import AVFoundation

// MARK: - Sort and Filter Options

enum TaskSortOption: String, CaseIterable {
    case createdAt = "Created"
    case dueDate = "Due Date"
    case priority = "Priority"
    case assignee = "Assignee"
    case title = "Title"
}

enum TaskFilterOption: String, CaseIterable {
    case all = "All"
    case hasAssignee = "Has Assignee"
    case hasDueDate = "Has Due Date"
    case overdue = "Overdue"
    case highPriority = "High Priority"
}

/// A project has three sections: Overview (its tasks and recordings), Workspace and Jobs (prompts
/// Claude runs on a schedule), chosen in the project's sidebar (ProjectContextSidebar) and
/// remembered per project (AppViewModel+Navigation.swift). General has only Workspace and Jobs.
enum ProjectTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case workspaces = "Workspace"
    case jobs = "Jobs"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "rectangle.grid.1x2"
        case .workspaces: return "terminal"
        case .jobs: return "clock.arrow.circlepath"
        }
    }
}

/// Detail view for a selected project showing tasks and recordings
struct ProjectDetailView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    let project: Project

    @State private var newTaskTitle = ""
    @State private var taskToEdit: ProjectTask?
    @State private var sortOption: TaskSortOption = .createdAt
    @State private var sortAscending = false
    @State private var filterOption: TaskFilterOption = .all
    @State private var filterPriority: TaskPriority?
    @State private var filterAssignee: String?
    @State private var recordingsSearchQuery = ""
    @State private var showingProjectSettings = false

    private var autoAcceptBinding: Binding<Bool> {
        Binding<Bool>(
            get: { project.autoAcceptExtractedTasks ?? viewModel.automationSettings.autoAcceptExtractedTasks },
            set: { newValue in
                let global = viewModel.automationSettings.autoAcceptExtractedTasks
                viewModel.updateProjectAutoAccept(project, value: newValue == global ? nil : newValue)
            }
        )
    }

    private var projectTasks: [ProjectTask] {
        viewModel.tasksForProject(project.id).filter { $0.needsReview != true }
    }

    private var filteredTasks: [ProjectTask] {
        var filtered = projectTasks

        switch filterOption {
        case .all:
            break
        case .hasAssignee:
            filtered = filtered.filter { $0.assignee != nil && !($0.assignee?.isEmpty ?? true) }
        case .hasDueDate:
            filtered = filtered.filter { $0.dueDate != nil }
        case .overdue:
            filtered = filtered.filter {
                guard let dueDate = $0.dueDate else { return false }
                return dueDate < Date() && !$0.isCompleted
            }
        case .highPriority:
            filtered = filtered.filter { $0.priority == .high || $0.priority == .critical }
        }

        if let priority = filterPriority {
            filtered = filtered.filter { $0.priority == priority }
        }

        if let assignee = filterAssignee, !assignee.isEmpty {
            filtered = filtered.filter {
                $0.assignee?.lowercased().contains(assignee.lowercased()) ?? false
            }
        }

        return filtered
    }

    private var sortedIncompleteTasks: [ProjectTask] {
        let incomplete = filteredTasks.filter { !$0.isCompleted }
        return sortTasks(incomplete)
    }

    private var sortedCompletedTasks: [ProjectTask] {
        let completed = filteredTasks.filter { $0.isCompleted }
        return sortTasks(completed)
    }

    private func sortTasks(_ tasks: [ProjectTask]) -> [ProjectTask] {
        let sorted = tasks.sorted { a, b in
            switch sortOption {
            case .createdAt:
                return a.createdAt > b.createdAt
            case .dueDate:
                guard let dateA = a.dueDate else { return false }
                guard let dateB = b.dueDate else { return true }
                return dateA < dateB
            case .priority:
                let priorityOrder: [TaskPriority?] = [.critical, .high, .medium, .low, nil]
                let indexA = priorityOrder.firstIndex(of: a.priority) ?? priorityOrder.count
                let indexB = priorityOrder.firstIndex(of: b.priority) ?? priorityOrder.count
                return indexA < indexB
            case .assignee:
                let assigneeA = a.assignee ?? ""
                let assigneeB = b.assignee ?? ""
                return assigneeA.localizedCompare(assigneeB) == .orderedAscending
            case .title:
                return a.title.localizedCompare(b.title) == .orderedAscending
            }
        }
        return sortAscending ? sorted.reversed() : sorted
    }

    private var uniqueAssignees: [String] {
        let assignees = projectTasks.compactMap { $0.assignee }.filter { !$0.isEmpty }
        return Array(Set(assignees)).sorted()
    }

    private var projectSessions: [RecordingSession] {
        viewModel.sessionsForProject(project.id)
    }

    private var filteredSessions: [RecordingSession] {
        if recordingsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return projectSessions
        }
        let query = recordingsSearchQuery.lowercased()
        return projectSessions.filter { session in
            session.title.lowercased().contains(query)
        }
    }

    /// The section the project's sidebar has chosen.
    private var selectedTab: ProjectTab { viewModel.projectTab(for: project.id) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Workspace drops the big header (the sidebar names the project) so the terminal gets
            // the height.
            let isWorkspace = selectedTab == .workspaces
            VStack(spacing: 0) {
                if !isWorkspace {
                    projectHeader
                        .padding([.horizontal, .top], 24)
                        .padding(.bottom, 12)
                    Divider()
                }

                Group {
                    switch selectedTab {
                    case .overview:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                tasksSection
                                recordingsSection
                            }
                            .padding(24)
                        }
                    case .workspaces:
                        // The terminal lives in AppViewModel.workspaceTerminals, so this view can be
                        // rebuilt freely without restarting Claude.
                        ProjectWorkspaceView(project: project, terminals: viewModel.workspaceTerminals)
                            .id(project.id)
                    case .jobs:
                        ScheduledJobsView(projectID: project.id)
                            .id(project.id)
                    }
                }
            }
            // No floating assistant button (removed 2026-10-13): the desktop companion is the one
            // way to Claude.
        }
        .sheet(isPresented: $showingProjectSettings) {
            // Pass the freshest copy so reopening the sheet shows saved values.
            ProjectSettingsSheet(
                project: viewModel.projects.first(where: { $0.id == project.id }) ?? project
            )
            .environment(viewModel)
        }
        .sheet(item: $taskToEdit) { task in
            TaskEditSheet(task: task) {
                updatedTitle, assignee, dueDate, hasDueTime, priority, notes, reminderEnabled,
                estimatedDuration in
                viewModel.updateTask(
                    task, title: updatedTitle, assignee: assignee, dueDate: dueDate,
                    hasDueTime: hasDueTime, priority: priority, notes: notes,
                    reminderEnabled: reminderEnabled, estimatedDuration: estimatedDuration)
            }
            .environment(viewModel)
        }
    }

    // MARK: - Header

    private var projectHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: project.colorHex))
                .frame(width: 16, height: 16)

            Text(project.name)
                .font(.title.bold())

            Spacer()

            Menu {
                Button("Rename Project") {
                    // TODO: Implement rename
                }

                Button("Project Settings…") {
                    showingProjectSettings = true
                }

                Divider()

                Toggle("Auto-accept extracted tasks", isOn: autoAcceptBinding)

                if project.autoAcceptExtractedTasks != nil {
                    Button("Reset to global default") {
                        viewModel.updateProjectAutoAccept(project, value: nil)
                    }
                }

                Divider()
                Button("Delete Project", role: .destructive) {
                    viewModel.deleteProject(project)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }
            .menuStyle(.borderlessButton)
        }
    }

    // MARK: - Tasks Section

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with sort and filter
            HStack {
                Text("Tasks")
                    .font(.title3.weight(.semibold))

                Spacer()

                // Filter menu
                Menu {
                    ForEach(TaskFilterOption.allCases, id: \.self) { option in
                        Button {
                            filterOption = option
                            if option != .all {
                                filterPriority = nil
                                filterAssignee = nil
                            }
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                if filterOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    Divider()

                    Menu("By Priority") {
                        Button("Any") {
                            filterPriority = nil
                        }
                        ForEach(TaskPriority.allCases, id: \.self) { priority in
                            Button {
                                filterPriority = priority
                                filterOption = .all
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(Color(hex: priority.color))
                                        .frame(width: 8, height: 8)
                                    Text(priority.displayName)
                                    if filterPriority == priority {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }

                    if !uniqueAssignees.isEmpty {
                        Menu("By Assignee") {
                            Button("Any") {
                                filterAssignee = nil
                            }
                            ForEach(uniqueAssignees, id: \.self) { assignee in
                                Button {
                                    filterAssignee = assignee
                                    filterOption = .all
                                } label: {
                                    HStack {
                                        Text(assignee)
                                        if filterAssignee == assignee {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if filterOption != .all || filterPriority != nil || filterAssignee != nil {
                        Divider()
                        Button("Clear Filters") {
                            filterOption = .all
                            filterPriority = nil
                            filterAssignee = nil
                        }
                    }
                } label: {
                    Label(
                        "Filter",
                        systemImage: filterOption != .all || filterPriority != nil
                            || filterAssignee != nil
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)

                // Sort menu
                Menu {
                    ForEach(TaskSortOption.allCases, id: \.self) { option in
                        Button {
                            if sortOption == option {
                                sortAscending.toggle()
                            } else {
                                sortOption = option
                                sortAscending = false
                            }
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                if sortOption == option {
                                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)

                Text("\(sortedIncompleteTasks.count) open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Active filters indicator
            if filterOption != .all || filterPriority != nil || filterAssignee != nil {
                HStack(spacing: 8) {
                    if filterOption != .all {
                        FilterChip(label: filterOption.rawValue) {
                            filterOption = .all
                        }
                    }
                    if let priority = filterPriority {
                        FilterChip(label: priority.displayName, color: Color(hex: priority.color)) {
                            filterPriority = nil
                        }
                    }
                    if let assignee = filterAssignee {
                        FilterChip(label: assignee) {
                            filterAssignee = nil
                        }
                    }
                }
            }

            // Add new task
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField("Add a new task...", text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if !newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            viewModel.createTask(title: newTaskTitle, projectID: project.id)
                            newTaskTitle = ""
                        }
                    }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            // Incomplete tasks
            if sortedIncompleteTasks.isEmpty && sortedCompletedTasks.isEmpty {
                if filterOption != .all || filterPriority != nil || filterAssignee != nil {
                    Text("No tasks match the current filters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    Text("No tasks yet. Add your first task above!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(sortedIncompleteTasks) { task in
                        TaskRowView(
                            task: task,
                            onToggle: {
                                viewModel.toggleTask(task)
                            },
                            onEdit: {
                                taskToEdit = task
                            },
                            onDelete: {
                                viewModel.deleteTask(task)
                            },
                            onAcceptReview: {
                                viewModel.acceptTaskReview(task)
                            })
                    }
                }

                // Completed tasks (collapsible)
                if !sortedCompletedTasks.isEmpty {
                    DisclosureGroup {
                        VStack(spacing: 4) {
                            ForEach(sortedCompletedTasks) { task in
                                TaskRowView(
                                    task: task,
                                    onToggle: {
                                        viewModel.toggleTask(task)
                                    },
                                    onEdit: {
                                        taskToEdit = task
                                    },
                                    onDelete: {
                                        viewModel.deleteTask(task)
                                    },
                                    onAcceptReview: {
                                        viewModel.acceptTaskReview(task)
                                    })
                            }
                        }
                    } label: {
                        Text("\(sortedCompletedTasks.count) completed")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 1, y: 1)
        )
    }

    // MARK: - Recordings Section

    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recordings")
                    .font(.title3.weight(.semibold))
                Spacer()
                
                // Search box
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))

                    TextField("Search recordings...", text: $recordingsSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .frame(maxWidth: 220)

                    if !recordingsSearchQuery.isEmpty {
                        Button {
                            recordingsSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                
                Text("\(filteredSessions.count) of \(projectSessions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if projectSessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No recordings in this project")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Assign recordings to this project from the All Transcripts view")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else if filteredSessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No results found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("No recordings match \"\(recordingsSearchQuery)\"")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(filteredSessions) { session in
                        recordingCard(for: session)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 1, y: 1)
        )
    }
    
    @ViewBuilder
    private func recordingCard(for session: RecordingSession) -> some View {
        ProjectRecordingCard(
            session: session,
            renameAction: { updatedTitle in
                viewModel.renameSession(session, newTitle: updatedTitle)
            },
            openTranscriptAction: {
                viewModel.openTranscript(session)
            },
            micURL: viewModel.audioURL(for: session, channel: .microphone),
            speakerURL: viewModel.audioURL(for: session, channel: .system),
            minutesURL: viewModel.minutesURL(for: session),
            canGenerateMinutes: viewModel.canGenerateMeetingMinutes,
            isGeneratingMinutes: viewModel.isGeneratingMinutes(for: session),
            generateMinutesAction: {
                                    // "Process": Claude cleanup, summary and knowledge, same as the pill and the inbox.
                                    viewModel.processMeeting(session.id)
                                },
            openMinutesAction: {
                viewModel.openMinutes(session)
            },
            deleteMinutesAction: {
                viewModel.deleteMinutes(for: session)
            },
            isExtractingTodos: viewModel.isExtractingTodos(for: session),
            canExtractTodos: viewModel.canExtractTodos && session.meetingMinutesFileName != nil,
            extractTodosAction: {
                Task {
                    await viewModel.extractTodosFromMinutes(for: session)
                }
            },
            isExtractingKnowledge: viewModel.isExtractingKnowledge(for: session),
            canExtractKnowledge: session.meetingMinutesFileName != nil,
            extractKnowledgeAction: {
                Task {
                    await viewModel.extractKnowledgeFromMinutes(for: session)
                }
            },
            deleteMic: {
                viewModel.deleteAudio(for: session, channel: .microphone)
            },
            deleteSpeaker: {
                viewModel.deleteAudio(for: session, channel: .system)
            },
            deleteTranscript: {
                viewModel.deleteTranscript(for: session)
            },
            deleteSession: {
                viewModel.deleteSession(session)
            },
            onRemoveFromProject: {
                viewModel.assignSessionToProject(session, projectID: nil)
            },
            onError: { message in
                viewModel.errorMessage = message
            },
            onGenerateWaveform: { channel in
                await viewModel.generateWaveform(for: session, channel: channel)
            },
            onCropAudio: { startTime, endTime in
                await viewModel.cropAudio(sessionID: session.id, startTime: startTime, endTime: endTime)
            },
            onRestoreAudio: {
                await viewModel.restoreOriginalAudio(sessionID: session.id)
            }
        )
    }
}

// MARK: - Task Edit Sheet

struct TaskEditSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    let task: ProjectTask
    let onSave: (String, String?, Date?, Bool, TaskPriority?, String, Bool, Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var assignee: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var hasDueTime: Bool
    @State private var priority: TaskPriority?
    @State private var notes: String
    @State private var reminderEnabled: Bool
    @State private var isRequestingRemindersAccess = false
    @State private var selectedEpicID: UUID?
    @State private var hasEstimatedDuration: Bool
    @State private var estimatedDurationHours: Int
    @State private var estimatedDurationMinutes: Int
    @State private var showingTimeBlockerSheet = false

    init(
        task: ProjectTask,
        onSave: @escaping (String, String?, Date?, Bool, TaskPriority?, String, Bool, Int?) -> Void
    ) {
        self.task = task
        self.onSave = onSave
        _title = State(initialValue: task.title)
        _assignee = State(initialValue: task.assignee ?? "")
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _dueDate = State(initialValue: task.dueDate ?? Date())
        _hasDueTime = State(initialValue: task.hasDueTime)
        _priority = State(initialValue: task.priority)
        _notes = State(initialValue: task.notes)
        _reminderEnabled = State(initialValue: task.reminderEnabled)
        _selectedEpicID = State(initialValue: task.epicID)
        _hasEstimatedDuration = State(initialValue: task.estimatedDurationMinutes != nil)
        let totalMinutes = task.estimatedDurationMinutes ?? 60
        _estimatedDurationHours = State(initialValue: totalMinutes / 60)
        _estimatedDurationMinutes = State(initialValue: totalMinutes % 60)
    }

    private var totalEstimatedMinutes: Int? {
        guard hasEstimatedDuration else { return nil }
        let total = estimatedDurationHours * 60 + estimatedDurationMinutes
        return total > 0 ? total : nil
    }

    private var canScheduleTime: Bool {
        hasDueDate && totalEstimatedMinutes != nil && viewModel.isAIAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("Edit Task")
                    .font(.headline)

                Spacer()

                Button("Save") {
                    onSave(
                        title, assignee.isEmpty ? nil : assignee, hasDueDate ? dueDate : nil,
                        hasDueTime, priority, notes, reminderEnabled, totalEstimatedMinutes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()

            Divider()

            // Form
            Form {
                Section("Task Details") {
                    TextField("Title", text: $title)
                    TextField("Assignee", text: $assignee)
                        .textContentType(.name)
                }

                Section("Due Date & Time") {
                    Toggle("Has Due Date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Date", selection: $dueDate, displayedComponents: .date)

                        Toggle("Include Time", isOn: $hasDueTime)
                        if hasDueTime {
                            DatePicker(
                                "Time", selection: $dueDate, displayedComponents: .hourAndMinute)
                        }
                    }
                }

                Section {
                    Toggle("Set Duration Estimate", isOn: $hasEstimatedDuration)
                    if hasEstimatedDuration {
                        HStack {
                            Picker("Hours", selection: $estimatedDurationHours) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text("\(h)h").tag(h)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 80)

                            Picker("Minutes", selection: $estimatedDurationMinutes) {
                                ForEach([0, 15, 30, 45], id: \.self) { m in
                                    Text("\(m)m").tag(m)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 80)

                            Spacer()

                            if let total = totalEstimatedMinutes {
                                Text(formatDuration(total))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Estimated Duration")
                } footer: {
                    Text("Used for scheduling time blockers in your calendar.")
                }

                Section {
                    Button {
                        showingTimeBlockerSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading) {
                                Text("Schedule Time in Calendar")
                                Text("AI will suggest optimal time blocks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canScheduleTime)

                    if !task.calendarBlockerIDs.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("\(task.calendarBlockerIDs.count) time block(s) scheduled")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !canScheduleTime {
                        if !hasDueDate {
                            Text("Set a due date to schedule time blocks")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if totalEstimatedMinutes == nil {
                            Text("Set an estimated duration to schedule time blocks")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if !viewModel.isAIAvailable {
                            Text("Install Claude Code to use AI scheduling")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Calendar Scheduling")
                }

                Section("Priority") {
                    Picker("Priority", selection: $priority) {
                        Text("None").tag(nil as TaskPriority?)
                        ForEach(TaskPriority.allCases, id: \.self) { p in
                            HStack {
                                Circle()
                                    .fill(Color(hex: p.color))
                                    .frame(width: 8, height: 8)
                                Text(p.displayName)
                            }
                            .tag(p as TaskPriority?)
                        }
                    }
                    .pickerStyle(.inline)
                }

                if let projectID = task.projectID {
                    let epics = viewModel.epicsForProject(projectID)
                    if !epics.isEmpty {
                        Section("Epic") {
                            Picker("Epic", selection: $selectedEpicID) {
                                Text("None").tag(nil as UUID?)
                                ForEach(epics) { epic in
                                    HStack {
                                        Circle()
                                            .fill(Color(hex: epic.colorHex))
                                            .frame(width: 8, height: 8)
                                        Text(epic.title)
                                    }
                                    .tag(epic.id as UUID?)
                                }
                            }
                            .pickerStyle(.inline)
                            .onChange(of: selectedEpicID) { _, newValue in
                                viewModel.updateTaskEpic(task, epicID: newValue)
                            }
                        }
                    }
                }

                Section {
                    Toggle(isOn: $reminderEnabled) {
                        HStack {
                            Image(systemName: "bell.badge")
                                .foregroundStyle(reminderEnabled ? .orange : .secondary)
                            VStack(alignment: .leading) {
                                Text("Sync to Apple Reminders")
                                Text("Get notifications on all your devices")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(
                        !viewModel.remindersService.isAuthorized && !isRequestingRemindersAccess
                    )
                    .onChange(of: reminderEnabled) { _, newValue in
                        if newValue && !viewModel.remindersService.isAuthorized {
                            isRequestingRemindersAccess = true
                            Task {
                                let granted = await viewModel.remindersService.requestAccess()
                                isRequestingRemindersAccess = false
                                if !granted {
                                    reminderEnabled = false
                                }
                            }
                        }
                    }

                    if !viewModel.remindersService.isAuthorized && !isRequestingRemindersAccess {
                        Button("Grant Reminders Access") {
                            isRequestingRemindersAccess = true
                            Task {
                                _ = await viewModel.remindersService.requestAccess()
                                isRequestingRemindersAccess = false
                            }
                        }
                    }

                    if task.reminderID != nil {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Synced to Reminders")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    if hasDueTime {
                        Text("You'll be reminded at the specified time.")
                    } else if hasDueDate {
                        Text("You'll be reminded on the due date.")
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 60)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 700)
        .sheet(isPresented: $showingTimeBlockerSheet) {
            TimeBlockerSheet(
                task: task,
                dueDate: dueDate,
                estimatedMinutes: totalEstimatedMinutes ?? 60
            )
            .environment(viewModel)
        }
    }

    private func formatDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 {
            return "\(hours)h \(mins)m total"
        } else if hours > 0 {
            return "\(hours)h total"
        } else {
            return "\(mins)m total"
        }
    }
}

// MARK: - Time Blocker Sheet

private struct TimeBlockerSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    let task: ProjectTask
    let dueDate: Date
    let estimatedMinutes: Int

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var explanation: String?
    @State private var proposedBlocks: [ProposedTimeBlock] = []
    @State private var editingBlockID: UUID?
    @State private var isSaving = false
    @State private var timingPreferences: String = ""
    @State private var showPreferences = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("Schedule Time Blocks")
                    .font(.headline)

                Spacer()

                Button("Add to Calendar") {
                    saveBlocks()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(proposedBlocks.isEmpty || isSaving)
            }
            .padding()

            Divider()

            // Timing preferences section
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation {
                        showPreferences.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                        Text("Timing Preferences")
                        Spacer()
                        Image(systemName: showPreferences ? "chevron.up" : "chevron.down")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if showPreferences {
                    TextEditor(text: $timingPreferences)
                        .frame(height: 60)
                        .font(.callout)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if timingPreferences.isEmpty {
                                Text(
                                    "e.g., 'Prefer mornings', 'No meetings on Fridays', 'Deep work after lunch'"
                                )
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                            }
                        }

                    Button("Regenerate with preferences") {
                        loadSuggestions()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("AI is analyzing your calendar...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    Button("Try Again") {
                        loadSuggestions()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if proposedBlocks.isEmpty && !isLoading {
                VStack(spacing: 16) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Click below to get AI suggestions")
                        .foregroundStyle(.secondary)
                    Button("Get AI Suggestions") {
                        loadSuggestions()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Explanation
                        if let explanation = explanation {
                            GroupBox {
                                HStack(alignment: .top) {
                                    Image(systemName: "lightbulb.fill")
                                        .foregroundStyle(.yellow)
                                    Text(explanation)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // Total time summary
                        let totalMinutes = proposedBlocks.reduce(0) { $0 + $1.durationMinutes }
                        HStack {
                            Text("Total scheduled:")
                            Spacer()
                            Text(formatDuration(totalMinutes))
                                .fontWeight(.medium)
                            if totalMinutes < estimatedMinutes {
                                Text("(\(estimatedMinutes - totalMinutes)m short)")
                                    .foregroundStyle(.orange)
                            } else if totalMinutes > estimatedMinutes {
                                Text("(+\(totalMinutes - estimatedMinutes)m buffer)")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 4)

                        // Time blocks
                        ForEach($proposedBlocks) { $block in
                            TimeBlockCard(
                                block: $block,
                                isEditing: editingBlockID == block.id,
                                onEdit: { editingBlockID = block.id },
                                onDoneEditing: { editingBlockID = nil },
                                onDelete: { proposedBlocks.removeAll { $0.id == block.id } }
                            )
                        }

                        // Add manual block button
                        Button {
                            let now = Date()
                            let newBlock = ProposedTimeBlock(
                                startDate: now,
                                endDate: now.addingTimeInterval(3600),
                                title: "📋 \(task.title)"
                            )
                            proposedBlocks.append(newBlock)
                            editingBlockID = newBlock.id
                        } label: {
                            Label("Add Time Block", systemImage: "plus.circle")
                        }
                        .padding(.top, 8)
                    }
                    .padding()
                }
            }
        }
        .frame(width: 500, height: 550)
        .onAppear {
            loadSuggestions()
        }
    }

    private func loadSuggestions() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Create a temporary task with updated values for suggestion
                var tempTask = task
                tempTask.dueDate = dueDate
                tempTask.estimatedDurationMinutes = estimatedMinutes

                let prefs = timingPreferences.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = try await viewModel.suggestTimeBlocks(
                    for: tempTask,
                    timingPreferences: prefs.isEmpty ? nil : prefs
                )
                proposedBlocks = result.blocks
                explanation = result.explanation
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func saveBlocks() {
        guard !proposedBlocks.isEmpty else { return }
        isSaving = true

        Task {
            do {
                try await viewModel.addTimeBlockers(proposedBlocks, for: task)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func formatDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 {
            return "\(hours)h \(mins)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            return "\(mins)m"
        }
    }
}

// MARK: - Time Block Card

private struct TimeBlockCard: View {
    @Binding var block: ProposedTimeBlock
    let isEditing: Bool
    let onEdit: () -> Void
    let onDoneEditing: () -> Void
    let onDelete: () -> Void

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.blue)

                    if isEditing {
                        TextField("Title", text: $block.title)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Text(block.title)
                            .fontWeight(.medium)
                    }

                    Spacer()

                    if isEditing {
                        Button("Done") {
                            onDoneEditing()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button {
                            onEdit()
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }

                if isEditing {
                    HStack {
                        DatePicker("Start", selection: $block.startDate)
                            .labelsHidden()
                        Text("to")
                        DatePicker("End", selection: $block.endDate)
                            .labelsHidden()
                    }
                } else {
                    HStack {
                        Text(dateFormatter.string(from: block.startDate))
                        Text("→")
                            .foregroundStyle(.secondary)
                        Text(dateFormatter.string(from: block.endDate))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Image(systemName: "clock")
                        .font(.caption)
                    Text("\(block.durationMinutes) minutes")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Task Row

private struct TaskRowView: View {
    @Environment(AppViewModel.self) private var viewModel

    let task: ProjectTask
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onAcceptReview: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isRequestingAccess = false
    @State private var showingAccessAlert = false
    @State private var showingQuickScheduleSheet = false

    private var dueDateText: String? {
        guard let dueDate = task.dueDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        if task.hasDueTime {
            formatter.timeStyle = .short
        }
        return formatter.string(from: dueDate)
    }

    private var isDueSoon: Bool {
        guard let dueDate = task.dueDate else { return false }
        return dueDate < Date().addingTimeInterval(86400 * 2)  // Within 2 days
    }

    private var isOverdue: Bool {
        guard let dueDate = task.dueDate, !task.isCompleted else { return false }
        return dueDate < Date()
    }

    private var showsReviewBanner: Bool {
        task.needsReview == true
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsReviewBanner {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                    Text("Auto-extracted — review this task")
                        .font(.caption)

                    Spacer()

                    Button { onAcceptReview?() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("Accept task")

                    Button { onEdit() } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("Edit task")

                    Button { onDelete() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss task")
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.blue.opacity(0.06))
            }

        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)

                // Metadata row
                HStack(spacing: 8) {
                    if let assignee = task.assignee, !assignee.isEmpty {
                        Label(assignee, systemImage: "person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let dueText = dueDateText {
                        Label(dueText, systemImage: task.hasDueTime ? "clock" : "calendar")
                            .font(.caption)
                            .foregroundStyle(isOverdue ? .red : (isDueSoon ? .orange : .secondary))
                    }

                    Menu {
                        ForEach(TaskPriority.allCases, id: \.self) { p in
                            Button {
                                viewModel.updateTaskPriority(task, priority: p)
                            } label: {
                                Label(p.displayName, systemImage:
                                    task.priority == p ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        Divider()
                        Button("No Priority") {
                            viewModel.updateTaskPriority(task, priority: nil)
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Circle()
                                .fill(task.priority.map { Color(hex: $0.color) } ?? Color.secondary.opacity(0.4))
                                .frame(width: 6, height: 6)
                            Text(task.priority?.displayName ?? "No Priority")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    if task.reminderEnabled {
                        Image(systemName: "bell.badge.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if !task.calendarBlockerIDs.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.caption)
                            Text("\(task.calendarBlockerIDs.count)")
                                .font(.caption2)
                        }
                        .foregroundStyle(.blue)
                    }

                    if let duration = task.estimatedDurationMinutes {
                        HStack(spacing: 2) {
                            Image(systemName: "hourglass")
                                .font(.caption)
                            Text(formatDurationShort(duration))
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isHovering {
                // Calendar scheduling button
                Button {
                    showingQuickScheduleSheet = true
                } label: {
                    Image(
                        systemName: task.calendarBlockerIDs.isEmpty
                            ? "calendar.badge.plus" : "calendar.badge.clock"
                    )
                    .foregroundStyle(task.calendarBlockerIDs.isEmpty ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .help(
                    task.calendarBlockerIDs.isEmpty
                        ? "Schedule time in calendar" : "Manage calendar blocks")

                // Reminder toggle button
                Button(action: toggleReminder) {
                    if isRequestingAccess {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: task.reminderEnabled ? "bell.slash" : "bell")
                            .foregroundStyle(task.reminderEnabled ? .orange : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help(task.reminderEnabled ? "Remove from Reminders" : "Add to Reminders")
                .disabled(isRequestingAccess)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        } // end outer VStack
        .background(isHovering ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .cornerRadius(6)
        .overlay(
            showsReviewBanner
                ? RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                : nil
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onEdit()
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .sheet(isPresented: $showingQuickScheduleSheet) {
            QuickScheduleSheet(task: task)
                .environment(viewModel)
        }
        .alert("Reminders Access Required", isPresented: $showingAccessAlert) {
            Button("Open System Settings") {
                if let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
                {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please grant Reminders access in System Settings to sync tasks.")
        }
    }

    private func toggleReminder() {
        Task {
            // If enabling and not authorized, request access
            if !task.reminderEnabled && !viewModel.remindersService.isAuthorized {
                isRequestingAccess = true
                let granted = await viewModel.remindersService.requestAccess()
                isRequestingAccess = false

                if !granted {
                    showingAccessAlert = true
                    return
                }
            }

            // Toggle the reminder
            isRequestingAccess = true
            await viewModel.toggleTaskReminder(task)
            isRequestingAccess = false
        }
    }

    private func formatDurationShort(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 {
            return "\(hours)h\(mins)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            return "\(mins)m"
        }
    }
}

// MARK: - Quick Schedule Sheet

private struct QuickScheduleSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    let task: ProjectTask

    @State private var durationHours: Int
    @State private var durationMinutes: Int
    @State private var dueDate: Date
    @State private var hasDueDate: Bool
    @State private var timingPreferences: String = ""
    @State private var showingTimeBlockerSheet = false
    @State private var isRequestingAccess = false
    @State private var errorMessage: String?

    init(task: ProjectTask) {
        self.task = task
        let totalMinutes = task.estimatedDurationMinutes ?? 60
        _durationHours = State(initialValue: totalMinutes / 60)
        _durationMinutes = State(initialValue: totalMinutes % 60)
        _dueDate = State(initialValue: task.dueDate ?? Date().addingTimeInterval(86400 * 7))  // Default 1 week
        _hasDueDate = State(initialValue: task.dueDate != nil)
    }

    private var totalMinutes: Int {
        durationHours * 60 + durationMinutes
    }

    private var canProceed: Bool {
        hasDueDate && totalMinutes > 0 && viewModel.isAIAvailable
    }

    private var taskWithUpdatedValues: ProjectTask {
        var tempTask = task
        tempTask.dueDate = dueDate
        tempTask.estimatedDurationMinutes = totalMinutes
        return tempTask
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("Schedule Time")
                    .font(.headline)

                Spacer()

                Button("Find Time Slots") {
                    proceedToScheduling()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canProceed || isRequestingAccess)
            }
            .padding()

            Divider()

            Form {
                Section {
                    Text(task.title)
                        .fontWeight(.medium)
                } header: {
                    Text("Task")
                }

                Section {
                    HStack {
                        Text("Estimated Duration")
                        Spacer()
                        Picker("Hours", selection: $durationHours) {
                            ForEach(0..<24, id: \.self) { h in
                                Text("\(h)h").tag(h)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 70)

                        Picker("Minutes", selection: $durationMinutes) {
                            ForEach([0, 15, 30, 45], id: \.self) { m in
                                Text("\(m)m").tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 70)
                    }
                } header: {
                    Text("Duration")
                } footer: {
                    Text("How long do you need to complete this task?")
                }

                Section {
                    Toggle("Set Due Date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker(
                            "Complete By", selection: $dueDate, in: Date()...,
                            displayedComponents: [.date, .hourAndMinute])
                    }
                } header: {
                    Text("Deadline")
                } footer: {
                    Text("AI will schedule time blocks before this deadline.")
                }

                Section {
                    TextEditor(text: $timingPreferences)
                        .frame(height: 60)
                        .overlay(alignment: .topLeading) {
                            if timingPreferences.isEmpty {
                                Text(
                                    "e.g., 'Morning person', 'No meetings on Fridays', 'Prefer 2-hour blocks'"
                                )
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("Timing Preferences (Optional)")
                } footer: {
                    Text("Tell the AI about your scheduling preferences.")
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                if !canProceed {
                    Section {
                        if !hasDueDate {
                            Label("Set a due date", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if totalMinutes <= 0 {
                            Label("Set a duration", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if !viewModel.isAIAvailable {
                            Label(
                                "Install Claude Code to use AI scheduling",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                }

                // Existing blockers
                if !task.calendarBlockerIDs.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundStyle(.blue)
                            Text("\(task.calendarBlockerIDs.count) time block(s) already scheduled")
                            Spacer()
                            Button("Remove All", role: .destructive) {
                                removeExistingBlockers()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } header: {
                        Text("Existing Blocks")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 520)
        .sheet(isPresented: $showingTimeBlockerSheet) {
            TimeBlockerSheetWithPreferences(
                task: taskWithUpdatedValues,
                dueDate: dueDate,
                estimatedMinutes: totalMinutes,
                timingPreferences: timingPreferences
            )
            .environment(viewModel)
        }
    }

    private func proceedToScheduling() {
        // First, update the task with new values
        viewModel.updateTaskEstimatedDuration(task, minutes: totalMinutes)
        if task.dueDate != dueDate {
            viewModel.updateTaskDueDate(task, dueDate: dueDate)
        }

        // Request calendar access if needed
        if !viewModel.calendarService.isAuthorized {
            isRequestingAccess = true
            Task {
                let granted = await viewModel.calendarService.requestAccess()
                isRequestingAccess = false
                if granted {
                    showingTimeBlockerSheet = true
                } else {
                    errorMessage =
                        "Calendar access is required. Please grant access in System Settings."
                }
            }
        } else {
            showingTimeBlockerSheet = true
        }
    }

    private func removeExistingBlockers() {
        Task {
            do {
                try viewModel.removeTimeBlockers(for: task)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Time Blocker Sheet With Preferences

private struct TimeBlockerSheetWithPreferences: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    let task: ProjectTask
    let dueDate: Date
    let estimatedMinutes: Int
    let timingPreferences: String

    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var explanation: String?
    @State private var proposedBlocks: [ProposedTimeBlock] = []
    @State private var editingBlockID: UUID?
    @State private var isSaving = false
    @State private var localTimingPreferences: String

    init(task: ProjectTask, dueDate: Date, estimatedMinutes: Int, timingPreferences: String) {
        self.task = task
        self.dueDate = dueDate
        self.estimatedMinutes = estimatedMinutes
        self.timingPreferences = timingPreferences
        _localTimingPreferences = State(initialValue: timingPreferences)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("AI Suggestions")
                    .font(.headline)

                Spacer()

                Button("Add to Calendar") {
                    saveBlocks()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(proposedBlocks.isEmpty || isSaving)
            }
            .padding()

            Divider()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("AI is analyzing your calendar...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        Text("Error")
                            .font(.headline)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        Divider()
                            .padding(.vertical)

                        Text("Adjust preferences and try again:")
                            .font(.subheadline)

                        TextEditor(text: $localTimingPreferences)
                            .frame(height: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                            .padding(.horizontal)

                        Button("Retry") {
                            loadSuggestions()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Explanation
                        if let explanation = explanation {
                            GroupBox {
                                HStack(alignment: .top) {
                                    Image(systemName: "lightbulb.fill")
                                        .foregroundStyle(.yellow)
                                    Text(explanation)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // Total time summary
                        let totalMinutes = proposedBlocks.reduce(0) { $0 + $1.durationMinutes }
                        HStack {
                            Text("Total scheduled:")
                            Spacer()
                            Text(formatDuration(totalMinutes))
                                .fontWeight(.medium)
                            if totalMinutes < estimatedMinutes {
                                Text("(\(estimatedMinutes - totalMinutes)m short)")
                                    .foregroundStyle(.orange)
                            } else if totalMinutes > estimatedMinutes {
                                Text("(+\(totalMinutes - estimatedMinutes)m buffer)")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 4)

                        // Time blocks
                        ForEach($proposedBlocks) { $block in
                            TimeBlockCard(
                                block: $block,
                                isEditing: editingBlockID == block.id,
                                onEdit: { editingBlockID = block.id },
                                onDoneEditing: { editingBlockID = nil },
                                onDelete: { proposedBlocks.removeAll { $0.id == block.id } }
                            )
                        }

                        // Add manual block button
                        Button {
                            let now = Date()
                            let newBlock = ProposedTimeBlock(
                                startDate: now,
                                endDate: now.addingTimeInterval(3600),
                                title: "📋 \(task.title)"
                            )
                            proposedBlocks.append(newBlock)
                            editingBlockID = newBlock.id
                        } label: {
                            Label("Add Time Block", systemImage: "plus.circle")
                        }
                        .padding(.top, 8)
                    }
                    .padding()
                }
            }
        }
        .frame(width: 500, height: 550)
        .onAppear {
            loadSuggestions()
        }
    }

    private func loadSuggestions() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                var tempTask = task
                tempTask.dueDate = dueDate
                tempTask.estimatedDurationMinutes = estimatedMinutes

                let prefs = localTimingPreferences.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = try await viewModel.suggestTimeBlocks(
                    for: tempTask,
                    timingPreferences: prefs.isEmpty ? nil : prefs
                )
                proposedBlocks = result.blocks
                explanation = result.explanation
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func saveBlocks() {
        guard !proposedBlocks.isEmpty else { return }
        isSaving = true

        Task {
            do {
                try await viewModel.addTimeBlockers(proposedBlocks, for: task)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func formatDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 {
            return "\(hours)h \(mins)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            return "\(mins)m"
        }
    }
}

// MARK: - Project Recording Card

private struct ProjectRecordingCard: View {
    @Environment(AppViewModel.self) private var viewModel
    let session: RecordingSession
    let renameAction: (String) -> Void
    let openTranscriptAction: () -> Void
    let micURL: URL?
    let speakerURL: URL?
    let minutesURL: URL?
    let canGenerateMinutes: Bool
    let isGeneratingMinutes: Bool
    let generateMinutesAction: () -> Void
    let openMinutesAction: () -> Void
    let deleteMinutesAction: () -> Void
    let isExtractingTodos: Bool
    let canExtractTodos: Bool
    let extractTodosAction: () -> Void
    let isExtractingKnowledge: Bool
    let canExtractKnowledge: Bool
    let extractKnowledgeAction: () -> Void
    let deleteMic: () -> Void
    let deleteSpeaker: () -> Void
    let deleteTranscript: () -> Void
    let deleteSession: () -> Void
    let onRemoveFromProject: () -> Void
    let onError: (String) -> Void
    let onGenerateWaveform: ((RecordingSession.Channel) async -> AudioProcessor.WaveformData?)?
    let onCropAudio: ((TimeInterval, TimeInterval) async -> Void)?
    let onRestoreAudio: (() async -> Void)?
    
    /// Owns audio playback for this card: the strip, the waveform and the preview's time chips.
    @State private var playback = SessionAudioPlayback()
    @State private var isRenaming = false
    @State private var isCropping = false
    
    init(
        session: RecordingSession,
        renameAction: @escaping (String) -> Void,
        openTranscriptAction: @escaping () -> Void,
        micURL: URL?,
        speakerURL: URL?,
        minutesURL: URL?,
        canGenerateMinutes: Bool,
        isGeneratingMinutes: Bool,
        generateMinutesAction: @escaping () -> Void,
        openMinutesAction: @escaping () -> Void,
        deleteMinutesAction: @escaping () -> Void,
        isExtractingTodos: Bool,
        canExtractTodos: Bool,
        extractTodosAction: @escaping () -> Void,
        isExtractingKnowledge: Bool,
        canExtractKnowledge: Bool,
        extractKnowledgeAction: @escaping () -> Void,
        deleteMic: @escaping () -> Void,
        deleteSpeaker: @escaping () -> Void,
        deleteTranscript: @escaping () -> Void,
        deleteSession: @escaping () -> Void,
        onRemoveFromProject: @escaping () -> Void,
        onError: @escaping (String) -> Void,
        onGenerateWaveform: ((RecordingSession.Channel) async -> AudioProcessor.WaveformData?)? = nil,
        onCropAudio: ((TimeInterval, TimeInterval) async -> Void)? = nil,
        onRestoreAudio: (() async -> Void)? = nil
    ) {
        self.session = session
        self.renameAction = renameAction
        self.openTranscriptAction = openTranscriptAction
        self.micURL = micURL
        self.speakerURL = speakerURL
        self.minutesURL = minutesURL
        self.canGenerateMinutes = canGenerateMinutes
        self.isGeneratingMinutes = isGeneratingMinutes
        self.generateMinutesAction = generateMinutesAction
        self.openMinutesAction = openMinutesAction
        self.deleteMinutesAction = deleteMinutesAction
        self.isExtractingTodos = isExtractingTodos
        self.canExtractTodos = canExtractTodos
        self.extractTodosAction = extractTodosAction
        self.isExtractingKnowledge = isExtractingKnowledge
        self.canExtractKnowledge = canExtractKnowledge
        self.extractKnowledgeAction = extractKnowledgeAction
        self.deleteMic = deleteMic
        self.deleteSpeaker = deleteSpeaker
        self.deleteTranscript = deleteTranscript
        self.deleteSession = deleteSession
        self.onRemoveFromProject = onRemoveFromProject
        self.onError = onError
        self.onGenerateWaveform = onGenerateWaveform
        self.onCropAudio = onCropAudio
        self.onRestoreAudio = onRestoreAudio
    }

    private var hasTranscript: Bool {
        session.transcript?.text.isEmpty == false
    }

    
    private var statusPlaceholder: String {
        switch session.status {
        case .recording:
            return "Recording…"
        case .recorded:
            return "Ready to transcribe."
        case .transcribing:
            return "Transcription pending…"
        case .liveTranscribing:
            return "Live transcribing…"
        case .completed:
            return "Transcript will appear here."
        case .failed:
            return "Transcription failed."
        case .idle:
            return "Ready."
        }
    }
    
    // Card redesign 2026-10-05 ("Speaker Rail"): header, meta line, talk bar and speaker
    // preview, then the playback strip and the actions. Shared parts live in
    // RecordingCardParts.swift and SessionPlaybackStrip.swift.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecordingCardHeader(session: session, isRenaming: $isRenaming, rename: renameAction) {
                EmptyView()
            }

            RecordingCardSummary(session: session, playback: playback, ownName: viewModel.ownSpeakerName)

            if !hasTranscript {
                if let error = session.lastErrorMessage {
                    Text("Transcription failed: \(error)")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else {
                    Text(statusPlaceholder)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if playback.hasAudio {
                SessionPlaybackStrip(
                    session: session, hasMicrophone: micURL != nil, playback: playback,
                    onGenerateWaveform: onGenerateWaveform, onCropAudio: onCropAudio,
                    isCropping: $isCropping)
            }

            // The bar renders in every state: it carries the overflow menu, and a session with no
            // transcript still needs to be deletable.
            transcriptActions
            extractedItemsSection
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystem.Colors.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        // Configured on the card, not on the strip: the strip only exists once the player has
        // audio, and SwiftUI never fires onAppear for a view that is not there.
        .onAppear { playback.configure(micURL: micURL, systemURL: speakerURL) }
        .onChange(of: micURL) { _, new in playback.configure(micURL: new, systemURL: speakerURL) }
        .onChange(of: speakerURL) { _, new in playback.configure(micURL: micURL, systemURL: new) }
        .onDisappear { playback.stop() }
    }

    private var transcriptActions: some View {
        SessionActionBar(
            session: session,
            hasMinutes: minutesURL != nil,
            canGenerateMinutes: canGenerateMinutes,
            isGeneratingMinutes: isGeneratingMinutes,
            canExtractTodos: canExtractTodos,
            isExtractingTodos: isExtractingTodos,
            canExtractKnowledge: canExtractKnowledge,
            isExtractingKnowledge: isExtractingKnowledge,
            hasMic: micURL != nil,
            hasSystemAudio: speakerURL != nil,
            handlers: SessionActionHandlers(
                openTranscript: openTranscriptAction,
                generateMinutes: generateMinutesAction,
                openMinutes: openMinutesAction,
                deleteMinutes: deleteMinutesAction,
                extractTodos: extractTodosAction,
                extractKnowledge: extractKnowledgeAction,
                deleteMic: deleteMic,
                deleteSpeaker: deleteSpeaker,
                deleteTranscript: deleteTranscript,
                deleteSession: deleteSession,
                removeFromProject: onRemoveFromProject,
                rename: { isRenaming = true },
                cropAudio: playback.hasAudio && onCropAudio != nil ? { isCropping = true } : nil,
                restoreAudio: isCropped ? { Task { await onRestoreAudio?() } } : nil))
    }

    private var isCropped: Bool {
        onRestoreAudio != nil && (session.cropStartTime != nil || session.cropEndTime != nil)
    }

    private var extractedItemsSection: some View {
        let sessionTasks = viewModel.tasksForSession(session.id)
        let pendingTasks = sessionTasks.filter { $0.needsReview == true }
        let acceptedTasks = sessionTasks.filter { $0.needsReview != true }

        return Group {
            if !sessionTasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Extracted Items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !pendingTasks.isEmpty {
                            Button {
                                viewModel.acceptAllExtractedTasks(for: session.id, projectID: session.projectID)
                            } label: {
                                Label("Accept All", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    // Pending tasks (need review)
                    ForEach(pendingTasks) { task in
                        ExtractedTaskRow(
                            task: task,
                            isPending: true,
                            onAccept: { viewModel.acceptExtractedTask(task, projectID: session.projectID) },
                            onReject: { viewModel.rejectExtractedTask(task) }
                        )
                    }

                    // Accepted tasks (reference)
                    if !acceptedTasks.isEmpty {
                        DisclosureGroup("Accepted tasks (\(acceptedTasks.count))") {
                            ForEach(acceptedTasks) { task in
                                ExtractedTaskRow(
                                    task: task,
                                    isPending: false,
                                    onAccept: {},
                                    onReject: {}
                                )
                            }
                        }
                        .font(.caption)
                    }

                    // Knowledge base entries
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct ExtractedTaskRow: View {
    let task: ProjectTask
    let isPending: Bool
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isPending ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(isPending ? .orange : .green)
                .font(.caption)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.caption)
                    .lineLimit(2)
                if let assignee = task.assignee, !assignee.isEmpty {
                    Text(assignee)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let priority = task.priority {
                Text(priority.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(hex: priority.color).opacity(0.2))
                    .cornerRadius(3)
            }

            if isPending {
                Button {
                    onAccept()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Accept task")

                Button {
                    onReject()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Reject task")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isPending ? Color.orange.opacity(0.08) : Color.clear)
        )
    }
}
