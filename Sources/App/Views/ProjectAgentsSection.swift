// Purpose: ProjectAgentsSection, the "Agents" section of the project sidebar: one row per open
//          Claude Code session of the project (its workspace strip and the windows torn off it),
//          with the project's creature showing the session's status and the session's name. A
//          click goes to the Workspace section and focuses that session's tab.
// Dependencies: Sources/App/Supporting/WorkspaceTerminalStore.swift (sessions, focus, status),
//               Sources/App/Supporting/TerminalSessionStatus.swift (the five statuses folded
//               into four here), Sources/App/Components/AgentStatusCreatureView.swift (creature),
//               Sources/App/ViewModels/AppViewModel+Navigation.swift (setProjectTab)
// Used by: Sources/App/Views/ProjectContextSidebar.swift
// Notes: Agents are Claude sessions only; plain terminals are left out, as for the desktop
//        companion (`WorkspaceTerminalStore.claudeSessions`).
//        The creature is the only status sign in a row (typing, waving, thumb up with a check,
//        error face; AgentStatusCreatureView); tooltip and VoiceOver name the state.
//        `AgentSessionState` folds `TerminalSessionStatus`'s five into four for that label:
//        error counts as waiting (it needs the user, as `CompanionCastMember.needsUser` has it),
//        done is finished while unseen (`finishedUnseen`) and idle once the user looked at it.
//        The list shows up to `maxVisibleRows` rows and scrolls beyond that, so the file tree
//        below keeps its room.
//        A click on a session of the workspace's own strip also brings a minimized Claude back
//        (`mm.workspaceClaudeMinimized`, ProjectWorkspaceView), as a click on its tab does; a
//        session in a torn-off window brings that window forward.

import AppKit
import SwiftUI

/// The states the sidebar names for an agent session (tooltip and VoiceOver).
enum AgentSessionState: Equatable {
    case working
    case waiting
    /// The turn finished and the user has not looked at the session since.
    case finished
    case idle

    init(_ status: TerminalSessionStatus, finishedUnseen: Bool = false) {
        switch status {
        case .working: self = .working
        case .waiting, .error: self = .waiting
        case .done: self = finishedUnseen ? .finished : .idle
        case .idle: self = .idle
        }
    }

    var label: String {
        switch self {
        case .working: "working"
        case .waiting: "waiting for input"
        case .finished: "finished"
        case .idle: "idle"
        }
    }
}

struct ProjectAgentsSection: View {
    let projectID: UUID
    @Environment(AppViewModel.self) private var viewModel
    /// ProjectWorkspaceView's minimized state, shared so a click can bring Claude back.
    @AppStorage("mm.workspaceClaudeMinimized") private var claudeMinimized = false

    /// Rows shown before the list scrolls.
    static let maxVisibleRows = 4
    private static let rowHeight: CGFloat = 26
    private static let rowSpacing: CGFloat = 2

    private var terminals: WorkspaceTerminalStore { viewModel.workspaceTerminals }

    private var sessions: [WorkspaceTerminalSession] {
        terminals.sessions(rootedAt: projectID).filter { !$0.isTerminal }
    }

    var body: some View {
        let sessions = sessions
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingXS) {
            Text("Agents")
                .font(DesignSystem.Typography.headline)
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
            if sessions.isEmpty {
                Text("No agents running")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .padding(.horizontal, DesignSystem.Dimensions.spacingS)
            } else {
                ScrollView {
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(sessions) { session in
                            row(session)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: listHeight(rows: sessions.count))
            }
        }
    }

    private func listHeight(rows: Int) -> CGFloat {
        let shown = CGFloat(min(rows, Self.maxVisibleRows))
        return shown * Self.rowHeight + max(0, shown - 1) * Self.rowSpacing
    }

    private func row(_ session: WorkspaceTerminalSession) -> some View {
        let state = AgentSessionState(session.status, finishedUnseen: session.finishedUnseen)
        return Button {
            open(session)
        } label: {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                AgentStatusCreatureView(projectID: projectID, sessions: [session], pixelSize: 1)
                    .frame(width: 18)
                Text(session.displayName)
                    .font(DesignSystem.Typography.callout)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: DesignSystem.Dimensions.spacingXS)
            }
            // Lined up with the section rows above (icon column 18 pt wide).
            .padding(.horizontal, DesignSystem.Dimensions.spacingM)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarHoverButtonStyle())
        .help("\(session.displayName), \(state.label)")
        .accessibilityLabel("\(session.displayName), \(state.label)")
        .accessibilityHint("Shows this session in the workspace")
    }

    /// Workspace, with the session's tab focused and the cursor in its terminal.
    private func open(_ session: WorkspaceTerminalSession) {
        viewModel.setProjectTab(.workspaces, for: projectID)
        if terminals.groupID(of: session) == projectID { claudeMinimized = false }
        terminals.setFocused(session.id)
        // The pane attaches the terminal view on its next update (and focuses it then); a view
        // already on screen, here or in a window, is focused right away.
        DispatchQueue.main.async {
            guard let window = session.view.window else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(session.view)
        }
    }
}
