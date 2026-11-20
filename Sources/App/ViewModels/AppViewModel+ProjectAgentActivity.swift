// Purpose: Records when each project's Claude sessions open and close, and gives the Home
//          sidebar its project list in the order chosen in Settings (Manual order or Recently used).
// Dependencies: Sources/App/Models/ProjectSidebarOrder.swift (setting, times, ordering),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (onClaudeSessionOpened/Closed,
//               claudeSessions)
// Used by: Sources/App/Views/ProjectsSidebarView.swift (sidebarProjects),
//          Sources/App/MinuteMindApp.swift (recordClaudeSessionsEndedAtQuit)
// Notes: Sessions are not restored across launches, so quitting with sessions open counts as
//        closing them then; otherwise those projects would keep only the time their session opened.

import Foundation

extension AppViewModel {
    func setupProjectAgentActivity() {
        workspaceTerminals.onClaudeSessionOpened = { [weak self] projectID in
            self?.updateAgentActivity(projectID) { $0.openedAt = Date() }
        }
        workspaceTerminals.onClaudeSessionClosed = { [weak self] projectID in
            guard let self, !openClaudeProjectIDs.contains(projectID) else { return }
            updateAgentActivity(projectID) { $0.closedAt = Date() }
        }
    }

    /// Projects with at least one open Claude session (plain terminals left out).
    var openClaudeProjectIDs: Set<UUID> {
        Set(workspaceTerminals.claudeSessions.map(\.projectID))
    }

    /// The projects in the Home sidebar's order.
    var sidebarProjects: [Project] {
        switch projectSidebarSort {
        case .manual:
            return projects
        case .recentlyUsed:
            return ProjectSidebarOrder.recentlyUsed(
                projects, activity: projectAgentActivity, open: openClaudeProjectIDs)
        }
    }

    /// Called when the app quits: open sessions end with it.
    func recordClaudeSessionsEndedAtQuit() {
        let open = openClaudeProjectIDs
        guard !open.isEmpty else { return }
        let now = Date()
        for id in open { projectAgentActivity[id, default: ProjectAgentActivity()].closedAt = now }
        ProjectAgentActivity.saveAll(projectAgentActivity)
    }

    private func updateAgentActivity(_ projectID: UUID, _ change: (inout ProjectAgentActivity) -> Void) {
        // General and the Claude window are not sidebar projects.
        guard projects.contains(where: { $0.id == projectID }) else { return }
        change(&projectAgentActivity[projectID, default: ProjectAgentActivity()])
        ProjectAgentActivity.saveAll(projectAgentActivity)
    }
}
