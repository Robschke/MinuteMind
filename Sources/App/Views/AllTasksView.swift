import SwiftUI

/// Sort options for the all-tasks view
enum AllTasksSortOption: String, CaseIterable {
    case project = "Project"
    case priority = "Priority"
    case dueDate = "Due Date"
    case createdAt = "Created"
    
    var canBeSecondary: Bool {
        self != .project
    }
}

/// Overview of all tasks across all projects
struct AllTasksView: View {
    @Environment(AppViewModel.self) private var viewModel
    
    @State private var sortOption: AllTasksSortOption = .dueDate
    @State private var secondarySortOption: AllTasksSortOption = .priority
    @State private var sortAscending = false
    @State private var showCompletedTasks = false
    @State private var taskToEdit: ProjectTask?
    @State private var searchQuery = ""
    @State private var selectedProjectIDs: Set<UUID> = []
    
    private var allTasks: [ProjectTask] {
        // Exclude tasks pending review — they are only visible on the recording card
        var filtered = viewModel.tasks.filter { $0.needsReview != true }

        // Filter by completion status
        if !showCompletedTasks {
            filtered = filtered.filter { !$0.isCompleted }
        }
        
        // Filter by selected projects
        if !selectedProjectIDs.isEmpty {
            filtered = filtered.filter { $0.projectID.map { selectedProjectIDs.contains($0) } ?? false }
        }
        
        // Filter by search query
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmedQuery.isEmpty {
            filtered = filtered.filter { task in
                task.title.lowercased().contains(trimmedQuery) ||
                task.notes.lowercased().contains(trimmedQuery) ||
                (task.assignee?.lowercased().contains(trimmedQuery) ?? false)
            }
        }
        
        return filtered
    }
    
    private var sortedTasks: [ProjectTask] {
        let sorted = allTasks.sorted { a, b in
            switch sortOption {
            case .project:
                let projectA = viewModel.projects.first(where: { $0.id == a.projectID })?.name ?? ""
                let projectB = viewModel.projects.first(where: { $0.id == b.projectID })?.name ?? ""
                return projectA.localizedCompare(projectB) == .orderedAscending
            case .priority:
                let priorityOrder: [TaskPriority?] = [.critical, .high, .medium, .low, nil]
                let indexA = priorityOrder.firstIndex(of: a.priority) ?? priorityOrder.count
                let indexB = priorityOrder.firstIndex(of: b.priority) ?? priorityOrder.count
                return indexA < indexB
            case .dueDate:
                guard let dateA = a.dueDate else { return false }
                guard let dateB = b.dueDate else { return true }
                return dateA < dateB
            case .createdAt:
                return a.createdAt > b.createdAt
            }
        }
        return sortAscending ? sorted.reversed() : sorted
    }
    
    private func sortTasksWithinGroup(_ tasks: [ProjectTask]) -> [ProjectTask] {
        // When grouped by project, apply secondary sort
        guard sortOption == .project else { return tasks }
        
        return tasks.sorted { a, b in
            switch secondarySortOption {
            case .priority:
                let priorityOrder: [TaskPriority?] = [.critical, .high, .medium, .low, nil]
                let indexA = priorityOrder.firstIndex(of: a.priority) ?? priorityOrder.count
                let indexB = priorityOrder.firstIndex(of: b.priority) ?? priorityOrder.count
                return indexA < indexB
            case .dueDate:
                guard let dateA = a.dueDate else { return false }
                guard let dateB = b.dueDate else { return true }
                return dateA < dateB
            case .createdAt:
                return a.createdAt > b.createdAt
            case .project:
                // Project sorting doesn't make sense as secondary
                return false
            }
        }
    }
    
    private var tasksByProject: [(project: Project?, tasks: [ProjectTask])] {
        var grouped: [UUID?: [ProjectTask]] = [:]
        
        for task in sortedTasks {
            grouped[task.projectID, default: []].append(task)
        }
        
        return grouped.map { projectID, tasks in
            let project = projectID.flatMap { id in viewModel.projects.first(where: { $0.id == id }) }
            // Apply secondary sort to tasks within each project group
            let sortedTasks = sortTasksWithinGroup(tasks)
            return (project, sortedTasks)
        }.sorted { a, b in
            (a.project?.name ?? "zzz_Unassigned") < (b.project?.name ?? "zzz_Unassigned")
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Content
            if allTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if sortOption == .project {
                            // Group by project
                            ForEach(tasksByProject, id: \.project?.id) { projectGroup in
                                projectSection(project: projectGroup.project, tasks: projectGroup.tasks)
                            }
                        } else {
                            // Flat list
                            VStack(spacing: 4) {
                                ForEach(sortedTasks) { task in
                                    AllTasksRowView(
                                        task: task,
                                        project: viewModel.projects.first(where: { $0.id == task.projectID }),
                                        onToggle: {
                                            viewModel.toggleTask(task)
                                        },
                                        onEdit: {
                                            taskToEdit = task
                                        },
                                        onDelete: {
                                            viewModel.deleteTask(task)
                                        },
                                        onProjectTap: {
                                            if let project = viewModel.projects.first(where: { $0.id == task.projectID }) {
                                                viewModel.selectedProjectID = project.id
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
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
    
    private var headerView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("All Tasks")
                    .font(.title.bold())
                
                Spacer()
                
                Text("\(allTasks.count) task\(allTasks.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search tasks...", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            
            HStack {
                // Sort controls
                Menu {
                    ForEach(AllTasksSortOption.allCases, id: \.self) { option in
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
                    Label(sortOption == .project ? "Group by: \(sortOption.rawValue)" : "Sort: \(sortOption.rawValue)", 
                          systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                
                // Secondary sort (only when grouping by project)
                if sortOption == .project {
                    Menu {
                        ForEach(AllTasksSortOption.allCases.filter { $0.canBeSecondary }, id: \.self) { option in
                            Button {
                                secondarySortOption = option
                            } label: {
                                HStack {
                                    Text(option.rawValue)
                                    if secondarySortOption == option {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Then by: \(secondarySortOption.rawValue)", systemImage: "arrow.down.right")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                }
                
                // Project filter
                Menu {
                    Button(selectedProjectIDs.isEmpty ? "All Projects ✓" : "All Projects") {
                        selectedProjectIDs.removeAll()
                    }
                    
                    if !viewModel.projects.isEmpty {
                        Divider()
                        
                        ForEach(viewModel.projects) { project in
                            Button {
                                if selectedProjectIDs.contains(project.id) {
                                    selectedProjectIDs.remove(project.id)
                                } else {
                                    selectedProjectIDs.insert(project.id)
                                }
                            } label: {
                                HStack {
                                    Text(project.name)
                                    if selectedProjectIDs.contains(project.id) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(selectedProjectIDs.isEmpty ? "All Projects" : "\(selectedProjectIDs.count) Project\(selectedProjectIDs.count == 1 ? "" : "s")", 
                          systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                
                Spacer()
                
                // Show completed toggle
                Toggle(isOn: $showCompletedTasks) {
                    Text("Show completed")
                        .font(.caption)
                }
                .toggleStyle(.switch)
            }
        }
        .padding([.horizontal, .top], 24)
        .padding(.bottom, 12)
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: searchQuery.isEmpty ? "checklist" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            
            Text(searchQuery.isEmpty ? (showCompletedTasks ? "No tasks" : "No open tasks") : "No matching tasks")
                .font(.title3)
                .foregroundStyle(.secondary)
            
            if searchQuery.isEmpty {
                Text("Tasks will appear here once you create them in your projects")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Try adjusting your search or filters")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private func projectSection(project: Project?, tasks: [ProjectTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let project = project {
                    ProjectAvatarView(projectID: project.id, pixelSize: 1)
                    
                    Text(project.name)
                        .font(.headline)
                } else {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                    Text("Unassigned")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                
                Text("(\(tasks.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 4) {
                ForEach(tasks) { task in
                    AllTasksRowView(
                        task: task,
                        project: project,
                        onToggle: {
                            viewModel.toggleTask(task)
                        },
                        onEdit: {
                            taskToEdit = task
                        },
                        onDelete: {
                            viewModel.deleteTask(task)
                        },
                        onProjectTap: {
                            if let project = project {
                                viewModel.selectedProjectID = project.id
                            }
                        },
                        onAcceptReview: {
                            viewModel.acceptTaskReview(task)
                        }
                    )
                }
            }
            .padding(.leading, 8)
        }
    }
}

// MARK: - Task Row for All Tasks View

private struct AllTasksRowView: View {
    @Environment(AppViewModel.self) private var viewModel
    
    let task: ProjectTask
    let project: Project?
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onProjectTap: () -> Void
    var onAcceptReview: (() -> Void)? = nil

    @State private var isHovering = false
    
    private var dueDateText: String? {
        guard let dueDate = task.dueDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        if task.hasDueTime {
            formatter.timeStyle = .short
        }
        return formatter.string(from: dueDate)
    }
    
    private var isOverdue: Bool {
        guard let dueDate = task.dueDate, !task.isCompleted else { return false }
        return dueDate < Date()
    }
    
    private var isDueSoon: Bool {
        guard let dueDate = task.dueDate else { return false }
        return dueDate < Date().addingTimeInterval(86400 * 2)  // Within 2 days
    }
    
    private var priorityColor: Color {
        guard let p = task.priority else { return DesignSystem.Colors.textTertiary }
        return Color(hex: p.color)
    }

    private var showsReviewBanner: Bool {
        task.needsReview == true
    }

    var body: some View {
        VStack(spacing: 0) {
            // Review banner for auto-extracted tasks
            if showsReviewBanner {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                    Text("Auto-extracted — review this task")
                        .font(DesignSystem.Typography.caption1)

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
                .foregroundStyle(DesignSystem.Colors.info)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DesignSystem.Colors.info.opacity(0.08))
            }

        HStack(spacing: 12) {
            // Left accent bar — priority color
            RoundedRectangle(cornerRadius: 2)
                .fill(priorityColor)
                .frame(width: 3)
                .padding(.vertical, 2)

            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(task.isCompleted ? DesignSystem.Colors.success : DesignSystem.Colors.textTertiary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(task.title)
                        .font(DesignSystem.Typography.body)
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? DesignSystem.Colors.textTertiary : DesignSystem.Colors.textPrimary)

                    Spacer()

                    // Project tag
                    if let project = project {
                        Button(action: onProjectTap) {
                            HStack(spacing: 4) {
                                ProjectAvatarView(projectID: project.id, pixelSize: 1)
                                Text(project.name)
                                    .font(DesignSystem.Typography.caption1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Go to \(project.name)")
                    }
                }

                // Metadata row
                HStack(spacing: 10) {
                    // Priority picker badge
                    priorityBadge

                    if let assignee = task.assignee, !assignee.isEmpty {
                        Label(assignee, systemImage: "person")
                            .font(DesignSystem.Typography.caption1)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }

                    if let dueText = dueDateText {
                        Label(dueText, systemImage: task.hasDueTime ? "clock" : "calendar")
                            .font(DesignSystem.Typography.caption1)
                            .foregroundStyle(isOverdue ? DesignSystem.Colors.error : (isDueSoon ? DesignSystem.Colors.warning : DesignSystem.Colors.textSecondary))
                    }

                    if task.reminderEnabled {
                        Image(systemName: "bell.badge.fill")
                            .font(DesignSystem.Typography.caption1)
                            .foregroundStyle(DesignSystem.Colors.warning)
                    }

                    if !task.calendarBlockerIDs.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "calendar.badge.clock")
                                .font(DesignSystem.Typography.caption1)
                            Text("\(task.calendarBlockerIDs.count)")
                                .font(DesignSystem.Typography.caption2)
                        }
                        .foregroundStyle(DesignSystem.Colors.info)
                    }
                }
            }

            Spacer()

            if isHovering {
                HStack(spacing: 8) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit task")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(DesignSystem.Colors.error)
                    }
                    .buttonStyle(.plain)
                    .help("Delete task")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        } // end outer VStack
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                .fill(isHovering ? DesignSystem.Colors.card : Color.clear)
        )
        .overlay(
            showsReviewBanner
                ? RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                    .stroke(DesignSystem.Colors.info.opacity(0.3), lineWidth: 1)
                : nil
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Priority Badge (inline picker)

    private var priorityBadge: some View {
        Menu {
            ForEach(TaskPriority.allCases, id: \.self) { p in
                Button {
                    viewModel.updateTaskPriority(task, priority: p)
                } label: {
                    HStack {
                        Circle()
                            .fill(Color(hex: p.color))
                            .frame(width: 8, height: 8)
                        Text(p.displayName)
                        if task.priority == p {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(priorityColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: priorityColor.opacity(0.4), radius: 2)
                Text((task.priority ?? .medium).displayName.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    Capsule()
                        .fill(priorityColor.opacity(0.15))
                    Capsule()
                        .stroke(priorityColor.opacity(0.3), lineWidth: 0.5)
                }
            )
            .foregroundStyle(priorityColor)
            .shadow(color: priorityColor.opacity(0.1), radius: 2, x: 0, y: 1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
