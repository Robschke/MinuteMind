// Purpose: What the desktop companion asks of the app: open the Claude (General) window, bring a
//          Claude session forward, find every window with a running Claude session, tell whether
//          the user is looking at a session right now, and the projects its scroll wheel offers
//          for the running recording. Also how a project's creature looks (projectAvatar,
//          companionMark), the one place every view takes it from.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (openWindowAction, navigation flags,
//               requestedProjectTab), Sources/App/Supporting/WorkspaceTerminalStore.swift (sessions,
//               strips and the views showing them)
// Used by: Sources/App/Supporting/CompanionController.swift (click, double click, menu, notices),
//          Sources/App/Supporting/MeetingPillController.swift via AppViewModel (Show, Claude)
// Notes: User decision 2026-10-13: a double click brings every window with a running Claude
//        session to the creature, fanned out beside it (CompanionController places them and can
//        put them back). Windows are found through the strips' registered views
//        (`dropZoneView(for:)`), so a project workspace in the main window counts too; the Claude
//        (General) window is opened first when it has sessions but is closed.

import AppKit
import SwiftUI

extension AppViewModel {
    /// What closes the project wheel's list after General.
    enum WheelTail { case noProject, later, none }

    /// The project wheel's entries: starred projects, the other projects (both in the sidebar's
    /// order), General, and last "No Project" during a recording, "Later" while the saved card asks
    /// for a project, nothing when it changes a filed one. The list wraps, so that last entry sits
    /// right above the starred ones.
    /// A project's creature for its starred mark: its own (in its avatar colour) or nil without
    /// one (the mark is a star then).
    func companionMark(for project: Project) -> (avatar: MascotAvatar?, color: Color?) {
        guard let avatar = project.companionCreature else { return (nil, nil) }
        return (avatar, CompanionAppearance.projectBodyColor(avatar, hex: project.avatarColorHex))
    }

    /// A project's creature as every view draws it (Home, the sidebars, the switcher, lists, the
    /// calendar, the pill): its own creature, a Blob without one; the body in the avatar colour,
    /// else the creature's natural colour. General shows the home companion in its own colour
    /// (nil: MascotCanvas then takes the colour from Settings).
    func projectAvatar(for projectID: UUID) -> (avatar: MascotAvatar, color: Color?) {
        if projectID == ProjectRepositoryService.generalProjectID { return (CompanionAppearance.shared.avatar, nil) }
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return (.blob, CompanionAppearance.projectBodyColor(.blob, hex: nil))
        }
        return Self.projectAvatar(of: project)
    }

    /// `projectAvatar(for:)` for a project value, also one not saved yet (the settings sheet's preview).
    static func projectAvatar(of project: Project) -> (avatar: MascotAvatar, color: Color) {
        let avatar = project.companionCreature ?? .blob
        return (avatar, CompanionAppearance.projectBodyColor(avatar, hex: project.avatarColorHex))
    }

    func projectWheelItems(tail: WheelTail = .noProject) -> [ProjectWheel.Item] {
        let ordered = projects.filter { $0.isStarred == true } + projects.filter { $0.isStarred != true }
        return ordered.map {
            let mark = companionMark(for: $0)
            let look = Self.projectAvatar(of: $0)
            return ProjectWheel.Item(
                projectID: $0.id, name: $0.name, avatar: look.avatar, avatarColor: look.color,
                isStarred: $0.isStarred == true, markAvatar: mark.avatar, markColor: mark.color)
        }
            + [.init(projectID: ProjectRepositoryService.generalProjectID, name: "General",
                     avatar: CompanionAppearance.shared.avatar)]
            + {
                switch tail {
                case .noProject: return [.init(projectID: nil, name: "No Project")]
                case .later: return [.init(projectID: nil, name: "Later", isLater: true)]
                case .none: return []
                }
            }()
    }

    /// The wheel's starting entry for a session: its project, General, or No Project.
    func projectWheelSelection(for session: RecordingSession) -> UUID? {
        session.projectID ?? (session.assignedToGeneral == true ? ProjectRepositoryService.generalProjectID : nil)
    }

    /// The wheel stopped on an entry: the recording files there, as if picked by hand, so the
    /// project classifier leaves it alone after transcription.
    func assignProjectFromWheel(_ projectID: UUID?, to sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              projectWheelSelection(for: session) != projectID else { return }
        assignSessionToProject(session, projectID: projectID)
    }

    /// Claude Code in the General workspace.
    func openClaudeAssistant() {
        NSApp.activate(ignoringOtherApps: true)
        openWindowAction?(id: "claude-assistant")
    }

    /// A double click on a project's creature: its session that needs the user, else the one
    /// focused last (`CompanionCast.sessionToOpen`), brought forward like Show does.
    func revealProjectSession(_ projectID: UUID) {
        let store = workspaceTerminals
        let choices = store.claudeSessions.filter { $0.projectID == projectID }.map {
            CompanionCast.SessionChoice(id: $0.id, status: $0.status, lastFocused: store.lastFocused($0.id), number: $0.number)
        }
        guard let id = CompanionCast.sessionToOpen(choices) else { return }
        revealTerminalSession(id)
    }

    /// Brings the window showing a Claude session forward and focuses its tab; a session in a
    /// project workspace selects the project and its Workspace tab first.
    func revealTerminalSession(_ id: UUID) {
        let store = workspaceTerminals
        guard let session = store.session(id), let groupID = store.groupID(of: session),
              let group = store.group(groupID) else { return }
        store.setFocused(id)
        NSApp.activate(ignoringOtherApps: true)
        if let window = store.dropZoneView(for: groupID)?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if group.rootID == WorkspaceTerminalStore.assistantKey {
            openWindowAction?(id: "claude-assistant")
            return
        }
        // A project workspace that is not on screen: show it in the main window.
        isShowingAllTasks = false
        isShowingCalendar = false
        isShowingInbox = false
        isShowingClipboard = false
        selectedProjectID = group.projectID
        if group.projectID != ProjectRepositoryService.generalProjectID {
            requestedProjectTab = .workspaces
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Every window showing a running Claude session, front to back by session number. A closed
    /// Claude (General) window with sessions is opened first; this waits (up to 2 s) until its
    /// terminals are on screen.
    func claudeWindows() async -> [NSWindow] {
        let store = workspaceTerminals
        let assistantKey = WorkspaceTerminalStore.assistantKey
        let assistantHasSessions = !store.sessions(rootedAt: assistantKey).filter { !$0.isTerminal }.isEmpty
        if assistantHasSessions, store.dropZoneView(for: assistantKey) == nil {
            openWindowAction?(id: "claude-assistant")
            for _ in 0..<20 where store.dropZoneView(for: assistantKey) == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        var windows: [NSWindow] = []
        for session in store.claudeSessions {
            guard let groupID = store.groupID(of: session),
                  let window = store.dropZoneView(for: groupID)?.window,
                  !windows.contains(window) else { continue }
            windows.append(window)
        }
        return windows
    }

    /// The MCP config the voice assistant hands to Claude Code, nil while the MCP server is off.
    func assistantMCPConfig() -> URL? {
        guard mcpServer.isEnabled else { return nil }
        return projectRepositories.writeClaudeMCPConfig(endpoint: mcpServer.endpointURL, token: mcpServer.token)
    }

    /// The app is in front and the session shows in a pane of the key window: no notice needed.
    func isLookingAtTerminalSession(_ id: UUID) -> Bool {
        let store = workspaceTerminals
        guard NSApp.isActive, let session = store.session(id), let groupID = store.groupID(of: session),
              let group = store.group(groupID), let window = store.dropZoneView(for: groupID)?.window
        else { return false }
        return window.isKeyWindow && group.split.visibleSessionIDs.contains(id)
    }

    /// The main window (scene "main", the one not matching another scene ID); the docked companion rides in it.
    var mainWindow: NSWindow? {
        // NSApp is nil until the application object exists (AppViewModel is built in App.init).
        guard let app = NSApp else { return nil }
        let sceneIDs = ["claude-assistant", "workspace-claude", "settings", "meeting-minutes"]
        return app.windows.first { window in
            guard !(window is NSPanel), window.canBecomeMain else { return false }
            let identifier = window.identifier?.rawValue ?? ""
            return !sceneIDs.contains { identifier.hasPrefix($0) }
        }
    }
}
