// Purpose: WorkspaceClaudeWindowView, a window holding Claude tabs dragged out of a workspace,
//          out of the Claude (General) window, or out of another such window
//          ("Claude · <project> · <focused session>").
// Dependencies: Sources/App/Views/WorkspaceTerminalPane.swift (tabs, terminals, status frames),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (window strips,
//               pendingWindowFrames, windowClosed), Sources/App/Services/ProjectRepositoryService.swift
//               (generalProject)
// Used by: Sources/App/MinuteMindApp.swift (WindowGroup "workspace-claude", value: the window's
//          strip ID), Sources/App/Views/WorkspaceTerminalPane.swift and
//          Sources/App/Views/ProjectWorkspaceView.swift (open it after a tear-off)
// Notes: User request 2026-10-13 (replaces the one-window-per-project pop-out of 2026-10-05).
//        Each window shows one strip of WorkspaceTerminalStore's layout. Closing the window sends
//        its tabs back to the strip they came from; when its last tab is closed or moved away the
//        strip disappears and the window closes itself. It never starts a session on its own:
//        a window restored by macOS after a relaunch finds no strip (sessions are not restored)
//        and closes. A new window takes the frame the drag left in `pendingWindowFrames`, except
//        while the app is in full screen (the window then opens in full screen and keeps it).
//        Plain terminal tabs (2026-10-13) live here too; with one in focus the title drops the
//        "Claude" prefix ("<project> · Terminal 1").

import AppKit
import SwiftUI

struct WorkspaceClaudeWindowView: View {
    /// The window's strip in WorkspaceTerminalStore's layout.
    let groupID: UUID
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    private var terminals: WorkspaceTerminalStore { viewModel.workspaceTerminals }
    private var group: WorkspaceTerminalLayout.Group? { terminals.group(groupID) }

    private var project: Project? {
        guard let projectID = group?.projectID else { return nil }
        return projectID == ProjectRepositoryService.generalProjectID
            ? ProjectRepositoryService.generalProject
            : viewModel.projects.first { $0.id == projectID }
    }

    /// "Claude · <project> · <session>"; with a plain terminal in focus "<project> · Terminal 1".
    private var title: String {
        let session = terminals.targetSession(for: groupID)
        var parts = session?.isTerminal == true ? [] : ["Claude"]
        if let project { parts.append(project.name) }
        if let session { parts.append(session.displayName) }
        return parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        Group {
            if let project, group != nil {
                WorkspaceTerminalPane(project: project, key: groupID, terminals: terminals)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle(title)
        .background(WindowFramer { window in
            // While the app is in full screen macOS opens the window in full screen too; a frame
            // set on it then squeezes the content into that rect until full screen is left.
            if let frame = terminals.pendingWindowFrames.removeValue(forKey: groupID),
               !NSApp.windows.contains(where: { $0.styleMask.contains(.fullScreen) }) {
                window.setFrame(frame, display: true)
            }
        })
        .onAppear { if group == nil { dismiss() } }
        .onChange(of: group == nil) { _, gone in if gone { dismiss() } }
        .onDisappear { terminals.windowClosed(groupID) }
    }
}

/// Hands the hosting window over once the view is in it (to place a torn-off tab's window).
private struct WindowFramer: NSViewRepresentable {
    let apply: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { apply(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
