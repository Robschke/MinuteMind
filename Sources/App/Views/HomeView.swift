// Purpose: HomeView, the page the main window opens on: a greeting and every project as a tile
//          with its creature (General first, then the sidebar's order) plus a New Project tile. A
//          click on a tile enters the project in its remembered section.
// Dependencies: Sources/App/ViewModels/AppViewModel+Navigation.swift (enterProject),
//               Sources/App/Components/ProjectAvatarView.swift (creature),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (Claude sessions per project),
//               Sources/App/Supporting/CompanionCast.swift (worst: one status for several sessions)
// Used by: Sources/App/Views/ContentView.swift
// Notes: A tile names a running Claude only when it needs a look (working, waiting, error); done
//        and idle say nothing, so the line stays rare enough to notice. New Project asks the Home
//        sidebar to open its sheet (`requestsNewProject`), so there is one New Project sheet.

import SwiftUI

struct HomeView: View {
    @Environment(AppViewModel.self) private var viewModel

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: DesignSystem.Dimensions.spacingL)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingXS) {
                Text(greeting)
                    .font(.system(size: 24, weight: .bold))
                Text(subtitle)
                    .font(DesignSystem.Typography.callout)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.bottom, DesignSystem.Dimensions.spacingXL)

                LazyVGrid(columns: columns, alignment: .leading, spacing: DesignSystem.Dimensions.spacingL) {
                    tile(ProjectRepositoryService.generalProjectID, name: "General",
                         meta: "Meetings without a project")
                    ForEach(viewModel.projects) { project in
                        tile(project.id, name: project.name, meta: meta(for: project))
                    }
                    newProjectTile
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Text

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var subtitle: String {
        let projects = viewModel.projects.count
        let waiting = viewModel.inboxSessions.count
        let projectText = projects == 1 ? "1 project" : "\(projects) projects"
        guard waiting > 0 else { return projectText }
        return projectText + " · " + (waiting == 1 ? "1 meeting waiting in the Inbox" : "\(waiting) meetings waiting in the Inbox")
    }

    private func meta(for project: Project) -> String {
        let meetings = viewModel.sessionsForProject(project.id).count
        let open = viewModel.tasksForProject(project.id).filter { !$0.isCompleted }.count
        let meetingText = meetings == 1 ? "1 meeting" : "\(meetings) meetings"
        let taskText = open == 1 ? "1 open task" : "\(open) open tasks"
        return "\(meetingText) · \(taskText)"
    }

    /// The Claude line of a tile, when one of the project's sessions needs a look.
    private func claudeStatus(of projectID: UUID) -> (text: String, color: Color)? {
        let statuses = viewModel.workspaceTerminals.sessions(rootedAt: projectID)
            .filter { !$0.isTerminal }
            .map(\.status)
        switch CompanionCast.worst(statuses) {
        case .working: return ("Claude working", DesignSystem.Colors.accent)
        case .waiting: return ("Claude waiting for you", DesignSystem.Colors.warning)
        case .error: return ("Claude stopped with an error", DesignSystem.Colors.error)
        default: return nil
        }
    }

    // MARK: - Tiles

    private func tile(_ projectID: UUID, name: String, meta: String) -> some View {
        Button {
            viewModel.enterProject(projectID)
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingS) {
                ProjectAvatarView(projectID: projectID, pixelSize: 4)
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                if let status = claudeStatus(of: projectID) {
                    HStack(spacing: 5) {
                        Circle().fill(status.color).frame(width: 6, height: 6)
                        Text(status.text)
                    }
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                Text(meta)
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(DesignSystem.Dimensions.spacingL)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeTileStyle())
        .accessibilityLabel("Open \(name)")
    }

    private var newProjectTile: some View {
        Button {
            viewModel.requestsNewProject = true
        } label: {
            VStack(spacing: DesignSystem.Dimensions.spacingS) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                Text("New Project")
                    .font(DesignSystem.Typography.callout)
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 170)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeTileStyle(dashed: true))
    }
}

/// A tile: a card that lifts a little on hover and sinks while pressed.
private struct HomeTileStyle: ButtonStyle {
    var dashed = false

    func makeBody(configuration: Configuration) -> some View {
        Tile(label: configuration.label, isPressed: configuration.isPressed, dashed: dashed)
    }

    private struct Tile<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let dashed: Bool
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            label
                .background {
                    if dashed {
                        shape.strokeBorder(DesignSystem.Colors.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    } else {
                        shape.fill(DesignSystem.Colors.card)
                            .overlay(shape.strokeBorder(DesignSystem.Colors.border, lineWidth: 1))
                            .shadow(color: .black.opacity(isHovered ? 0.10 : 0.0), radius: 10, y: 4)
                    }
                }
                .scaleEffect(isPressed ? 0.98 : 1)
                .offset(y: isHovered && !reduceMotion && !dashed ? -2 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isPressed)
                .onHover { isHovered = $0 }
        }
    }
}
