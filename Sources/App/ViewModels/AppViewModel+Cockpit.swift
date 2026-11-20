// Purpose: The agent cockpit's state and actions: which spaces (projects and General) it lists,
//          which one it shows, starting a Claude session in a space and showing a session.
// Dependencies: Sources/App/Supporting/AgentCockpitSpaces.swift (listing rules),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (sessions, strips, focus),
//               Sources/App/ViewModels/AppViewModel.swift (isShowingCockpit, cockpitProjectID,
//               cockpitCollapsedIDs, workspaceLaunch(for:kind:)),
//               Sources/App/Services/ProjectRepositoryService.swift (General)
// Used by: Sources/App/Views/AgentCockpitSidebar.swift, Sources/App/Views/AgentCockpitView.swift,
//          Sources/App/ViewModels/AppViewModel+Companion.swift (revealTerminalSession)
// Notes: A space is a project's own strip (root key = project ID), the one its Workspace section
//        shows; the cockpit shows that same strip, so a session started here is in the project's
//        workspace too, and the reverse. Torn-off windows stay windows: their sessions are listed
//        and a click brings the window forward. The Claude (General) window's sessions
//        (`WorkspaceTerminalStore.assistantKey`) are a strip of their own and not listed, as in
//        the project sidebar's Agents section.

import AppKit
import Foundation

extension AppViewModel {
    /// Every space in the Home sidebar's order: General first, then the projects.
    var cockpitOrder: [UUID] {
        [ProjectRepositoryService.generalProjectID] + projects.map(\.id)
    }

    /// Spaces with at least one open Claude session (plain terminals do not count).
    var cockpitRunningIDs: Set<UUID> {
        Set(cockpitOrder.filter { !cockpitSessions(in: $0).isEmpty })
    }

    /// The spaces the cockpit lists.
    var cockpitSpaceIDs: [UUID] {
        AgentCockpitSpaces.listed(order: cockpitOrder, running: cockpitRunningIDs)
    }

    /// The spaces the "+" menu offers.
    var cockpitAddableIDs: [UUID] {
        AgentCockpitSpaces.addable(order: cockpitOrder, running: cockpitRunningIDs)
    }

    /// The space whose strip the cockpit shows.
    var cockpitShownSpaceID: UUID? {
        AgentCockpitSpaces.shown(chosen: cockpitProjectID, listed: cockpitSpaceIDs)
    }

    /// The Claude sessions of a space, its windows' included, in strip order.
    func cockpitSessions(in spaceID: UUID) -> [WorkspaceTerminalSession] {
        workspaceTerminals.sessions(rootedAt: spaceID).filter { !$0.isTerminal }
    }

    /// The project behind a space; General for its ID.
    func cockpitProject(_ spaceID: UUID) -> Project? {
        if spaceID == ProjectRepositoryService.generalProjectID { return ProjectRepositoryService.generalProject }
        return projects.first { $0.id == spaceID }
    }

    func setCockpitSpaceCollapsed(_ spaceID: UUID, _ collapsed: Bool) {
        if collapsed { cockpitCollapsedIDs.insert(spaceID) } else { cockpitCollapsedIDs.remove(spaceID) }
    }

    /// Shows a space's strip in the cockpit without changing its focused tab.
    func showCockpitSpace(_ spaceID: UUID) {
        cockpitProjectID = spaceID
    }

    /// Starts a Claude session in the space's own strip (the first one of a strip not opened
    /// yet this launch, else another tab), shows the space and focuses the new session. Says so
    /// when the project already runs its six sessions.
    func startCockpitSession(in spaceID: UUID, model: String = "opus") {
        guard let project = cockpitProject(spaceID) else { return }
        let terminals = workspaceTerminals
        let launch: WorkspaceTerminalStore.Launcher = { self.workspaceLaunch(for: project, kind: $0) }
        let before = Set(terminals.sessions(rootedAt: spaceID).map(\.id))
        terminals.ensureSession(in: spaceID, projectID: spaceID, launch: launch)
        var started = terminals.sessions(rootedAt: spaceID).first { !before.contains($0.id) }
        if started == nil {
            started = terminals.addSession(in: spaceID, kind: .claude(model: model), launch: launch)
        }
        guard let started else {
            errorMessage = "\(project.name) already runs \(WorkspaceTerminalStore.maxSessions) Claude sessions."
            return
        }
        setCockpitSpaceCollapsed(spaceID, false)
        showCockpitSession(started)
    }

    /// Shows a session: in its torn-off window when it sits in one, else in the cockpit with its
    /// space's strip, its tab focused and the cursor in its terminal.
    func showCockpitSession(_ session: WorkspaceTerminalSession) {
        let terminals = workspaceTerminals
        terminals.setFocused(session.id)
        if let groupID = terminals.groupID(of: session), terminals.group(groupID)?.isWindow == true {
            terminals.dropZoneView(for: groupID)?.window?.makeKeyAndOrderFront(nil)
        } else {
            cockpitProjectID = session.projectID
        }
        // The pane attaches the terminal view on its next update; focus it once it is there.
        DispatchQueue.main.async {
            guard let window = session.view.window else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(session.view)
        }
    }
}
