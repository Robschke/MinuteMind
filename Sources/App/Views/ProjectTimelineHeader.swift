/// Timeline progress bar for projects with start/target dates and completion percentage.
/// Depends on: AppViewModel, Project.swift, DesignSystem
/// Used by: WorkboardView

import SwiftUI

struct ProjectTimelineHeader: View {
    @Environment(AppViewModel.self) private var viewModel
    let project: Project

    @State private var isEditingDates = false
    @State private var editStartDate: Date = Date()
    @State private var editTargetDate: Date = Date()

    private var projectTasks: [ProjectTask] {
        viewModel.tasksForProject(project.id)
    }

    private var completionPercentage: Double {
        let total = projectTasks.count
        guard total > 0 else { return 0 }
        let done = projectTasks.filter { $0.effectiveStatus == .done }.count
        return Double(done) / Double(total)
    }

    var body: some View {
        if project.startDate != nil || project.targetDate != nil {
            timelineBar
        } else {
            setTimelineLink
        }
    }

    // MARK: - Set Timeline Link

    private var setTimelineLink: some View {
        Button {
            editStartDate = Date()
            editTargetDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
            isEditingDates = true
        } label: {
            Label("Set timeline...", systemImage: "calendar.badge.clock")
                .font(DesignSystem.Typography.caption1)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditingDates) {
            dateEditPopover
        }
    }

    // MARK: - Timeline Bar

    private var timelineBar: some View {
        VStack(spacing: 6) {
            HStack {
                if let start = project.startDate {
                    Text(dateLabel(start))
                        .font(DesignSystem.Typography.caption2)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track
                        Capsule()
                            .fill(DesignSystem.Colors.border)
                            .frame(height: 6)

                        // Completion fill
                        Capsule()
                            .fill(completionPercentage >= 1.0 ? DesignSystem.Colors.success : Color.accentColor)
                            .frame(width: max(6, geo.size.width * completionPercentage), height: 6)

                        // Current position marker (time-based)
                        if let start = project.startDate, let target = project.targetDate {
                            let elapsed = Date().timeIntervalSince(start)
                            let total = target.timeIntervalSince(start)
                            let timeProgress = total > 0 ? min(max(elapsed / total, 0), 1) : 0
                            Circle()
                                .fill(Color.primary)
                                .frame(width: 10, height: 10)
                                .offset(x: geo.size.width * timeProgress - 5)
                        }
                    }
                }
                .frame(height: 10)

                if let target = project.targetDate {
                    Text(dateLabel(target))
                        .font(DesignSystem.Typography.caption2)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }

            HStack {
                Text("\(Int(completionPercentage * 100))% complete")
                    .font(DesignSystem.Typography.caption2)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)

                Spacer()

                if let timeLabel = timeRemainingLabel {
                    Text(timeLabel)
                        .font(DesignSystem.Typography.caption2)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }

                Button {
                    editStartDate = project.startDate ?? Date()
                    editTargetDate = project.targetDate ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
                    isEditingDates = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isEditingDates) {
                    dateEditPopover
                }
            }
        }
    }

    // MARK: - Date Edit Popover

    private var dateEditPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project Timeline")
                .font(DesignSystem.Typography.headline)

            DatePicker("Start", selection: $editStartDate, displayedComponents: .date)
                .font(DesignSystem.Typography.callout)
            DatePicker("Target", selection: $editTargetDate, displayedComponents: .date)
                .font(DesignSystem.Typography.callout)

            HStack {
                Button("Remove") {
                    viewModel.updateProjectTimeline(project, startDate: nil, targetDate: nil)
                    isEditingDates = false
                }
                .foregroundStyle(.red)

                Spacer()

                Button("Cancel") {
                    isEditingDates = false
                }
                Button("Save") {
                    viewModel.updateProjectTimeline(project, startDate: editStartDate, targetDate: editTargetDate)
                    isEditingDates = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - Helpers

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private var timeRemainingLabel: String? {
        guard let start = project.startDate, let target = project.targetDate else { return nil }
        let now = Date()
        let calendar = Calendar.current

        let totalWeeks = calendar.dateComponents([.weekOfYear], from: start, to: target).weekOfYear ?? 0
        let elapsedWeeks = calendar.dateComponents([.weekOfYear], from: start, to: now).weekOfYear ?? 0

        if now > target {
            let daysOver = calendar.dateComponents([.day], from: target, to: now).day ?? 0
            return "\(daysOver)d overdue"
        } else if totalWeeks > 0 {
            return "Week \(min(elapsedWeeks + 1, totalWeeks)) of \(totalWeeks)"
        } else {
            let daysLeft = calendar.dateComponents([.day], from: now, to: target).day ?? 0
            return "\(daysLeft)d remaining"
        }
    }
}
