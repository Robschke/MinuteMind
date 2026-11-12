/// Kanban-style workboard for visual task flow with epic filtering and timeline.
/// Depends on: AppViewModel, WorkboardCardView, ProjectTimelineHeader, EpicManagementSheet
/// Used by: ProjectDetailView (Board tab)

import SwiftUI

struct WorkboardView: View {
    @Environment(AppViewModel.self) private var viewModel
    let project: Project

    @State private var selectedEpicID: UUID?
    @State private var showingEpicSheet = false
    @State private var taskToEdit: ProjectTask?
    @State private var draggingTask: ProjectTask?
    @State private var showingAISummary = false
    @State private var aiSummaryText: String?
    @State private var isGeneratingSummary = false
    @State private var doneColumnExpanded = false
    private let doneColumnPreviewCount = 5

    private var projectTasks: [ProjectTask] {
        var tasks = viewModel.tasksForProject(project.id).filter { $0.needsReview != true }
        if let epicID = selectedEpicID {
            tasks = tasks.filter { $0.epicID == epicID }
        }
        return tasks
    }

    private var projectEpics: [Epic] {
        viewModel.epicsForProject(project.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            ProjectTimelineHeader(project: project)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)

            epicFilterBar
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Divider()

            boardColumns
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
        .sheet(isPresented: $showingEpicSheet) {
            EpicManagementSheet(project: project)
                .environment(viewModel)
        }
        .popover(isPresented: $showingAISummary) {
            aiSummaryPopover
        }
    }

    // MARK: - Epic Filter Bar

    private var epicFilterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChipButton(
                        label: "All",
                        isSelected: selectedEpicID == nil,
                        color: .accentColor
                    ) {
                        selectedEpicID = nil
                    }

                    ForEach(projectEpics) { epic in
                        FilterChipButton(
                            label: epic.title,
                            isSelected: selectedEpicID == epic.id,
                            color: Color(hex: epic.colorHex)
                        ) {
                            selectedEpicID = selectedEpicID == epic.id ? nil : epic.id
                        }
                    }

                    Button {
                        showingEpicSheet = true
                    } label: {
                        Label("Epics", systemImage: "plus.circle")
                            .font(DesignSystem.Typography.caption1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }

            Spacer()

            Button {
                generateAISummary()
            } label: {
                Label("AI", systemImage: "sparkles")
                    .font(DesignSystem.Typography.caption1)
            }
            .buttonStyle(.bordered)
            .disabled(isGeneratingSummary || !viewModel.canGenerateMeetingMinutes)
            .popover(isPresented: $showingAISummary) {
                aiSummaryPopover
            }
        }
    }

    // MARK: - Board Columns

    private var boardColumns: some View {
        HStack(spacing: 0) {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                boardColumn(for: status)
                if status != .done {
                    Divider()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func boardColumn(for status: TaskStatus) -> some View {
        let columnTasks = projectTasks.filter { $0.effectiveStatus == status }

        return VStack(spacing: 0) {
            // Column header
            HStack {
                Image(systemName: status.icon)
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text(status.displayName)
                    .font(DesignSystem.Typography.caption2)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .textCase(.uppercase)

                Spacer()

                Text("\(columnTasks.count)")
                    .font(DesignSystem.Typography.caption2)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DesignSystem.Colors.border, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Cards
            ScrollView {
                LazyVStack(spacing: 8) {
                    if columnTasks.isEmpty {
                        columnEmptyState(for: status)
                    } else {
                        let visibleTasks = (status == .done && !doneColumnExpanded)
                            ? Array(columnTasks.prefix(doneColumnPreviewCount))
                            : columnTasks

                        ForEach(visibleTasks) { task in
                            WorkboardCardView(
                                task: task,
                                epic: task.epicID.flatMap { epicID in projectEpics.first { $0.id == epicID } },
                                onTap: { taskToEdit = task },
                                onStatusChange: { newStatus in
                                    withAnimation(DesignSystem.Animation.smooth) {
                                        viewModel.updateTaskStatus(task, status: newStatus)
                                    }
                                },
                                onEpicChange: { newEpicID in
                                    viewModel.updateTaskEpic(task, epicID: newEpicID)
                                },
                                onDelete: {
                                    withAnimation(DesignSystem.Animation.quick) {
                                        viewModel.deleteTask(task)
                                    }
                                },
                                availableEpics: projectEpics
                            )
                            .transition(.asymmetric(
                                insertion: .scale.combined(with: .opacity),
                                removal: .opacity
                            ))
                            .draggable(task.id.uuidString) {
                                WorkboardCardView(
                                    task: task,
                                    epic: nil,
                                    onTap: {},
                                    onStatusChange: { _ in },
                                    onEpicChange: { _ in },
                                    onDelete: {},
                                    availableEpics: []
                                )
                                .frame(width: 200)
                                .opacity(0.8)
                            }
                        }

                        // "Show all" for collapsed done column
                        if status == .done && !doneColumnExpanded && columnTasks.count > doneColumnPreviewCount {
                            Button {
                                withAnimation(DesignSystem.Animation.smooth) {
                                    doneColumnExpanded = true
                                }
                            } label: {
                                Text("Show all \(columnTasks.count) tasks")
                                    .font(DesignSystem.Typography.caption1)
                                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(8)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let taskIDString = items.first,
                      let taskID = UUID(uuidString: taskIDString),
                      let task = viewModel.tasks.first(where: { $0.id == taskID })
                else { return false }
                withAnimation(DesignSystem.Animation.smooth) {
                    viewModel.updateTaskStatus(task, status: status)
                }
                return true
            }

            Divider()

            // Quick add button
            Button {
                quickAddTask(status: status)
            } label: {
                Label("Add", systemImage: "plus")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .background(
            status == .done
                ? DesignSystem.Colors.surface.opacity(0.5)
                : Color.clear
        )
    }

    // MARK: - Empty States

    private func columnEmptyState(for status: TaskStatus) -> some View {
        VStack(spacing: 6) {
            Image(systemName: emptyStateIcon(for: status))
                .font(.title3)
                .foregroundStyle(DesignSystem.Colors.textTertiary.opacity(0.5))
            Text(emptyStateMessage(for: status))
                .font(DesignSystem.Typography.caption2)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func emptyStateIcon(for status: TaskStatus) -> String {
        switch status {
        case .backlog: return "tray"
        case .todo: return "circle.dashed"
        case .inProgress: return "bolt.circle"
        case .review: return "eye"
        case .done: return "checkmark.seal"
        }
    }

    private func emptyStateMessage(for status: TaskStatus) -> String {
        switch status {
        case .backlog: return "No items\nin backlog"
        case .todo: return "Nothing\nqueued up"
        case .inProgress: return "Nothing\nin progress"
        case .review: return "Nothing\nin review"
        case .done: return "No completed\ntasks yet"
        }
    }

    // MARK: - Quick Add

    private func quickAddTask(status: TaskStatus) {
        viewModel.createTaskWithStatus(
            title: "New Task",
            projectID: project.id,
            status: status
        )
        // Open the just-created task for editing
        if let created = viewModel.tasksForProject(project.id).last(where: { $0.title == "New Task" && $0.status == status }) {
            taskToEdit = created
        }
    }

    // MARK: - AI Summary

    private var aiSummaryPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Board Summary", systemImage: "sparkles")
                    .font(DesignSystem.Typography.headline)
                Spacer()
                if isGeneratingSummary {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let text = aiSummaryText {
                Text(text)
                    .font(DesignSystem.Typography.body)
                    .textSelection(.enabled)
            } else if isGeneratingSummary {
                Text("Analyzing board...")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            } else {
                Text("Click the AI button to generate a summary.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func generateAISummary() {
        guard viewModel.isAIAvailable else { return }
        let ai = viewModel.aiClient
        isGeneratingSummary = true
        showingAISummary = true

        let allTasks = viewModel.tasksForProject(project.id)
        let statusCounts = Dictionary(grouping: allTasks, by: { $0.effectiveStatus })
            .mapValues(\.count)
        let overdue = allTasks.filter { task in
            guard let due = task.dueDate else { return false }
            return due < Date() && !task.isCompleted
        }
        let epics = projectEpics

        var prompt = "Summarize this project's board status in 2-3 sentences. Highlight risks and blockers.\n\n"
        prompt += "Project: \(project.name)\n"
        prompt += "Task counts by column:\n"
        for status in TaskStatus.allCases {
            prompt += "  \(status.displayName): \(statusCounts[status] ?? 0)\n"
        }
        if !overdue.isEmpty {
            prompt += "\nOverdue tasks (\(overdue.count)):\n"
            for task in overdue.prefix(5) {
                prompt += "  - \(task.title)\n"
            }
        }
        if !epics.isEmpty {
            prompt += "\nEpics:\n"
            for epic in epics {
                let epicTasks = allTasks.filter { $0.epicID == epic.id }
                let done = epicTasks.filter { $0.effectiveStatus == .done }.count
                prompt += "  - \(epic.title): \(done)/\(epicTasks.count) done\n"
            }
        }

        Task {
            do {
                let service = MeetingMinutesService()
                let result = try await service.generateBoardSummary(prompt: prompt, ai: ai)
                await MainActor.run {
                    aiSummaryText = result
                    isGeneratingSummary = false
                }
            } catch {
                await MainActor.run {
                    aiSummaryText = "Failed to generate summary: \(error.localizedDescription)"
                    isGeneratingSummary = false
                }
            }
        }
    }
}

// MARK: - Filter Chip

private struct FilterChipButton: View {
    let label: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(DesignSystem.Typography.caption1)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected
                    ? color.opacity(0.15)
                    : DesignSystem.Colors.surface,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? color.opacity(0.4) : DesignSystem.Colors.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Default due date helper

private extension ProjectTask {
    static var defaultDueDate: Date {
        let calendar = Calendar.current
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let daysUntilFriday = (6 - weekday + 7) % 7
        return calendar.date(byAdding: .day, value: daysUntilFriday == 0 ? 7 : daysUntilFriday, to: now) ?? now
    }
}
