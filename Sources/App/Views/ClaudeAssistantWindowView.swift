// Purpose: ClaudeAssistantWindowView, the "Claude (General)" window opened from the main page's
//          assistant button: Claude Code sessions running in the General workspace folder.
// Dependencies: Sources/App/Views/WorkspaceTerminalPane.swift (tabs, terminals, status strip),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (assistantKey),
//               Sources/App/Services/ProjectRepositoryService.swift (generalProject)
// Used by: Sources/App/MinuteMindApp.swift (Window scene "claude-assistant"),
//          Sources/App/Views/AllTranscriptsView.swift (GlobalAssistantButton)
// Notes: User request 2026-10-05: the main page's AI chat opens Claude in a separate terminal in
//        the General workspace. Decisions (design review 4): a single-instance window instead of
//        jumping to the sidebar, so the transcript list stays in place; its sessions are its own
//        (WorkspaceTerminalStore.assistantKey), not the General view's tabs, because one terminal
//        view cannot be in two windows. Closing the window only hides it: the sessions keep
//        running and reopening returns to the last one. Nothing above the terminals but the tab
//        strip; "Show Files" selects the sidebar's General workspace in the main window.
//        Its tabs can be dragged out into windows of their own (2026-10-13); those return here
//        when closed, even while this window is hidden.

import AppKit
import SwiftUI

struct ClaudeAssistantWindowView: View {
    @Environment(AppViewModel.self) private var viewModel

    private let project = ProjectRepositoryService.generalProject
    private let key = WorkspaceTerminalStore.assistantKey
    private var terminals: WorkspaceTerminalStore { viewModel.workspaceTerminals }

    var body: some View {
        Group {
            if terminals.hasStarted(key) {
                WorkspaceTerminalPane(project: project, key: key, terminals: terminals, showFiles: showFiles)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .task {
            viewModel.projectRepositories.ensureRepository(for: project)
            // Outside `body`: starting a terminal during a render froze SwiftUI updates.
            terminals.ensureSession(in: key, projectID: project.id) { viewModel.workspaceLaunch(for: project, kind: $0) }
        }
    }

    /// Brings the main window forward on the sidebar's General workspace (file tree, editor).
    private func showFiles() {
        viewModel.selectedProjectID = ProjectRepositoryService.generalProjectID
        viewModel.isShowingAllTasks = false
        viewModel.isShowingCalendar = false
        // SwiftUI names scene windows "<scene id>-AppWindow-<n>"; the main window is the one left over.
        let sceneIDs = ["claude-assistant", "workspace-claude", "settings", "meeting-minutes"]
        let main = NSApp.windows.first { window in
            guard !(window is NSPanel), window.canBecomeMain else { return false }
            let identifier = window.identifier?.rawValue ?? ""
            return !sceneIDs.contains { identifier.hasPrefix($0) }
        }
        main?.makeKeyAndOrderFront(nil)
    }
}
