/// Compact task card for the kanban workboard with priority color, epic tag, and context menu.
/// Depends on: Project.swift (TaskPriority, TaskStatus, ProjectTask), Epic.swift, DesignSystem
/// Used by: WorkboardView

import SwiftUI

struct WorkboardCardView: View {
    let task: ProjectTask
    let epic: Epic?
    let onTap: () -> Void
    let onStatusChange: (TaskStatus) -> Void
    let onEpicChange: (UUID?) -> Void
    let onDelete: () -> Void
    let availableEpics: [Epic]

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // Left priority color strip
                RoundedRectangle(cornerRadius: 2)
                    .fill(priorityColor)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 6) {
                    // Title
                    Text(task.title)
                        .font(DesignSystem.Typography.callout)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Bottom row: assignee, epic tag, due date
                    HStack(spacing: 6) {
                        if let assignee = task.assignee, !assignee.isEmpty {
                            assigneeAvatar(assignee)
                        }

                        if let epic = epic {
                            epicTag(epic)
                        }

                        Spacer()

                        if let dueDate = task.dueDate {
                            dueDatePill(dueDate)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(DesignSystem.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                    .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
            )
            .shadow(
                color: isHovered ? DesignSystem.Shadows.soft.color : DesignSystem.Shadows.subtle.color,
                radius: isHovered ? DesignSystem.Shadows.soft.radius : DesignSystem.Shadows.subtle.radius,
                x: 0,
                y: isHovered ? 2 : 1
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.gentle) {
                isHovered = hovering
            }
        }
        .contextMenu {
            statusMenu
            epicMenu
            Divider()
            Button("Edit...") { onTap() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    // MARK: - Subviews

    private func assigneeAvatar(_ name: String) -> some View {
        let initials = name.split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()

        return Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Color.gray.opacity(0.6), in: Circle())
    }

    private func epicTag(_ epic: Epic) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Color(hex: epic.colorHex))
                .frame(width: 6, height: 6)
            Text(epic.title)
                .font(DesignSystem.Typography.caption2)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
        }
    }

    private func dueDatePill(_ date: Date) -> some View {
        let isOverdue = date < Date() && !task.isCompleted
        let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f
        }()

        return Text(formatter.string(from: date))
            .font(DesignSystem.Typography.caption2)
            .foregroundStyle(isOverdue ? .white : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                isOverdue ? AnyShapeStyle(Color.red.opacity(0.8)) : AnyShapeStyle(DesignSystem.Colors.border),
                in: Capsule()
            )
    }

    private var priorityColor: Color {
        guard let priority = task.priority else {
            return Color.gray.opacity(0.3)
        }
        return Color(hex: priority.color)
    }

    // MARK: - Context Menus

    private var statusMenu: some View {
        Menu("Move to") {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button {
                    onStatusChange(status)
                } label: {
                    Label(status.displayName, systemImage: status.icon)
                }
                .disabled(task.effectiveStatus == status)
            }
        }
    }

    private var epicMenu: some View {
        Menu("Epic") {
            Button("None") {
                onEpicChange(nil)
            }
            Divider()
            ForEach(availableEpics) { epic in
                Button {
                    onEpicChange(epic.id)
                } label: {
                    Label(epic.title, systemImage: task.epicID == epic.id ? "checkmark" : "")
                }
            }
        }
    }
}
