// Purpose: SwiftUI content for the Task Commander floating panel — quick task entry with keyboard-first
//          navigation over open tasks.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift, Sources/App/Models/Project.swift,
//               Sources/App/Components/DesignSystem.swift
// Used by: Sources/App/Views/TaskCommanderPanel.swift (hosted inside NSPanel)
// Notes: The text field is auto-focused on appear so the user can immediately type a new task.
//        Arrow keys navigate the task list, Enter on a selected task opens inline editing,
//        Escape dismisses the panel. All styling follows the app's DesignSystem.

import SwiftUI

struct TaskCommanderView: View {
    var viewModel: AppViewModel
    let onDismiss: () -> Void

    @State private var newTaskTitle = ""
    @State private var selectedProjectID: UUID?
    @State private var selectedIndex: Int? = nil
    @State private var showingDetails = false
    @FocusState private var isTextFieldFocused: Bool

    // Detail fields for expanded creation
    @State private var priority: TaskPriority = .medium
    @State private var dueDate: Date = AppViewModel.endOfCurrentWeek
    @State private var assignee: String = ""
    @State private var notes: String = ""
    @State private var estimatedMinutes: String = ""

    private var openTasks: [ProjectTask] {
        viewModel.tasks
            .filter { !$0.isCompleted }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var defaultProjectID: UUID? {
        selectedProjectID ?? viewModel.projects.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search/create field
            inputSection

            Divider().overlay(DesignSystem.Colors.divider)

            // Expandable detail fields
            if showingDetails {
                detailFields
                Divider().overlay(DesignSystem.Colors.divider)
            }

            // Task list
            taskList
        }
        .onAppear {
            isTextFieldFocused = true
            selectedProjectID = viewModel.projects.first?.id
        }
    }

    // MARK: - Input Section

    private var inputSection: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingS) {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(DesignSystem.Colors.accent)

                TextField("New task...", text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .focused($isTextFieldFocused)
                    .onSubmit { createTask() }

                // Toggle detail fields
                Button {
                    withAnimation(DesignSystem.Animation.quick) {
                        showingDetails.toggle()
                    }
                } label: {
                    Image(systemName: showingDetails ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(DesignSystem.Colors.hoverOverlay)
                        )
                }
                .buttonStyle(.plain)
                .help("Show task details")
            }

            // Project picker row
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .frame(width: 18)

                Picker("", selection: $selectedProjectID) {
                    ForEach(viewModel.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)

                Spacer()

                Text("\(openTasks.count) open")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingL)
        .padding(.vertical, DesignSystem.Dimensions.spacingM)
    }

    // MARK: - Detail Fields

    private var detailFields: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingS) {
            // Priority
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Label("Priority", systemImage: "flag")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 100, alignment: .leading)

                HStack(spacing: 4) {
                    ForEach(TaskPriority.allCases, id: \.self) { p in
                        Button {
                            priority = p
                        } label: {
                            Text(p.displayName)
                                .font(DesignSystem.Typography.caption1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(priority == p
                                              ? Color(hex: p.color).opacity(0.2)
                                              : DesignSystem.Colors.hoverOverlay)
                                )
                                .foregroundStyle(priority == p
                                                 ? Color(hex: p.color)
                                                 : DesignSystem.Colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }

            // Due date
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Label("Due", systemImage: "calendar")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 100, alignment: .leading)

                DatePicker("", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .controlSize(.small)
                Spacer()
            }

            // Assignee
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Label("Assignee", systemImage: "person")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 100, alignment: .leading)

                TextField("Optional", text: $assignee)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.caption1)
                Spacer()
            }

            // Estimated duration
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Label("Duration", systemImage: "clock")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 100, alignment: .leading)

                TextField("Minutes", text: $estimatedMinutes)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.caption1)
                    .frame(width: 60)
                Text("min")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                Spacer()
            }

            // Notes
            HStack(alignment: .top, spacing: DesignSystem.Dimensions.spacingS) {
                Label("Notes", systemImage: "note.text")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 100, alignment: .leading)

                TextField("Optional", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.caption1)
                    .lineLimit(2...4)
                Spacer()
            }
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingL)
        .padding(.vertical, DesignSystem.Dimensions.spacingS)
    }

    // MARK: - Task List

    private var taskList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(openTasks.enumerated()), id: \.element.id) { index, task in
                        TaskCommanderRow(
                            task: task,
                            project: viewModel.projects.first(where: { $0.id == task.projectID }),
                            isSelected: selectedIndex == index,
                            onToggle: { viewModel.toggleTask(task) }
                        )
                        .id(task.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = index
                        }
                    }
                }
                .padding(.vertical, DesignSystem.Dimensions.spacingXS)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                if let idx = newIndex, idx < openTasks.count {
                    withAnimation(DesignSystem.Animation.quick) {
                        proxy.scrollTo(openTasks[idx].id, anchor: .center)
                    }
                }
            }
            .onKeyPress(.upArrow) {
                moveSelection(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(.escape) {
                onDismiss()
                return .handled
            }
            .onKeyPress(.return) {
                if !newTaskTitle.isEmpty {
                    createTask()
                    return .handled
                }
                if let idx = selectedIndex, idx < openTasks.count {
                    viewModel.toggleTask(openTasks[idx])
                    return .handled
                }
                return .ignored
            }
        }
    }

    // MARK: - Actions

    private func createTask() {
        guard let projectID = defaultProjectID else { return }
        let trimmed = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if showingDetails {
            // Create with full details
            viewModel.createDetailedTask(
                title: trimmed,
                projectID: projectID,
                notes: notes,
                assignee: assignee.isEmpty ? nil : assignee,
                dueDate: dueDate,
                priority: priority,
                estimatedDurationMinutes: Int(estimatedMinutes)
            )
        } else {
            // Quick create with defaults
            viewModel.createTask(title: trimmed, projectID: projectID)
        }

        // Reset fields
        newTaskTitle = ""
        notes = ""
        assignee = ""
        estimatedMinutes = ""
        priority = .medium
        dueDate = AppViewModel.endOfCurrentWeek
        showingDetails = false
        isTextFieldFocused = true
    }

    private func moveSelection(by offset: Int) {
        let count = openTasks.count
        guard count > 0 else { return }

        if let current = selectedIndex {
            let next = current + offset
            if next >= 0 && next < count {
                selectedIndex = next
            }
        } else {
            selectedIndex = offset > 0 ? 0 : count - 1
        }
    }
}

// MARK: - Task Row

private struct TaskCommanderRow: View {
    let task: ProjectTask
    let project: Project?
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingS) {
            // Completion toggle
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.isCompleted ? DesignSystem.Colors.success : DesignSystem.Colors.textTertiary)
            }
            .buttonStyle(.plain)

            // Priority dot
            if let priority = task.priority {
                Circle()
                    .fill(Color(hex: priority.color))
                    .frame(width: 8, height: 8)
            }

            // Title
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(DesignSystem.Typography.callout)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                HStack(spacing: DesignSystem.Dimensions.spacingXS) {
                    if let project {
                        Text(project.name)
                            .font(DesignSystem.Typography.caption2)
                            .foregroundStyle(Color(hex: project.colorHex))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color(hex: project.colorHex).opacity(0.12))
                            )
                    }

                    if let due = task.dueDate {
                        Text(relativeDateLabel(due))
                            .font(DesignSystem.Typography.caption2)
                            .foregroundStyle(due < Date() ? DesignSystem.Colors.error : DesignSystem.Colors.textTertiary)
                    }

                    if let assignee = task.assignee, !assignee.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "person")
                                .font(.system(size: 9))
                            Text(assignee)
                                .lineLimit(1)
                        }
                        .font(DesignSystem.Typography.caption2)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingL)
        .padding(.vertical, DesignSystem.Dimensions.spacingS)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                .fill(isSelected
                      ? DesignSystem.Colors.accent.opacity(0.12)
                      : isHovering
                      ? DesignSystem.Colors.hoverOverlay
                      : Color.clear)
        )
        .padding(.horizontal, DesignSystem.Dimensions.spacingXS)
        .onHover { isHovering = $0 }
    }

    private func relativeDateLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        if days < 0 { return "\(abs(days))d overdue" }
        if days <= 7 { return "In \(days)d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

