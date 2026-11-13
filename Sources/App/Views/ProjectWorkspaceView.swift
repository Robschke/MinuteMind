// Purpose: ProjectWorkspaceView, the project's "Workspace" section: the file editor (when a file is
//          open) and the Claude Code sessions (Opus or Sonnet, MinuteMind MCP). The repo's file
//          tree lives in the sidebar (ProjectContextSidebar) and opens files here through the
//          shared WorkspaceEditorState.
// Dependencies: Sources/App/Views/WorkspaceTerminalPane.swift (sessions, tabs, status strip),
//               Sources/App/Views/WorkspaceEditorPane.swift (editor),
//               Sources/App/Components/SplitResizeHandle.swift (dividers),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (live terminals, foreground
//               process, activity), Sources/App/Supporting/WorkspaceEditorStore.swift (open file),
//               Sources/App/Services/ProjectRepositoryService.swift (via AppViewModel.workspaceLaunch)
// Used by: Sources/App/Views/ProjectDetailView.swift (Workspace tab),
//          Sources/App/Views/GeneralWorkspaceView.swift, AppViewModel (MM_WORKSPACE_DEMO)
// Notes: Decisions (with design reviews 1 to 3): with a file open, Claude sits below it by default (user decision
//        2026-10-05; the file's height is remembered, 360 pt default, Claude keeps 260 pt) or
//        beside it, chosen with the placement buttons in Claude's tab strip and remembered for
//        all projects. Beside, the editor's width is remembered (560 pt default) and gives way
//        so the terminals keep at least one 480 pt pane. The third button moves all tabs into
//        one window (WorkspaceClaudeWindowView); single tabs can be dragged out too (2026-10-13).
//        While the workspace's own strip is empty the file takes the whole width and a bar
//        offers Show / Bring Back (with windows) and New Session. Hand-made draggable dividers
//        (HSplitView ignores preferred widths), drawn by SplitResizeHandle: a grabber pill
//        between file and Claude; double click restores the default size. Claude starts as soon
//        as the section opens; exiting Claude leaves a login shell. The open file's disk state
//        is checked every second.
//        Below the file, Claude can be minimized to its tab strip: dragging the divider down
//        until Claude would keep less than half its minimum height snaps it into the strip,
//        dragging back above that point brings it up at the dragged height. A click on a tab, a
//        double click on the strip's free space or on the divider, a placement button, a new
//        session and tabs coming back from windows bring it back too. There is no minimize
//        button. Remembered for every project (`mm.workspaceClaudeMinimized`); beside the file
//        or with no file open it has no effect.

import AppKit
import SwiftUI

struct ProjectWorkspaceView: View {
    let project: Project
    let terminals: WorkspaceTerminalStore
    @Environment(AppViewModel.self) private var viewModel

    /// Width of the editor, remembered across launches (320 pt up, default 560).
    @AppStorage("mm.workspaceEditorWidth") private var editorWidth: Double = ProjectWorkspaceView.defaultEditorWidth
    /// Claude below the open file (default) or beside it; the same for every project.
    @AppStorage("mm.workspaceClaudeBelow") private var claudeBelow = true
    /// Height of the file above Claude in the "below" layout, remembered (default 360 pt).
    @AppStorage("mm.workspaceEditorHeight") private var editorHeight: Double = ProjectWorkspaceView.defaultEditorHeight
    /// Claude below the file folded down to its tab strip, the same for every project.
    @AppStorage("mm.workspaceClaudeMinimized") private var claudeMinimized = false
    @State private var dragStartWidth: Double?
    /// The file's remembered height when a drag of the row divider began, restored when the
    /// drag minimizes Claude, so bringing it back returns to the height before the drag.
    @State private var dragStartEditorHeight: Double?
    @Environment(\.openWindow) private var openWindow

    private static let defaultEditorWidth: Double = 560
    private static let defaultEditorHeight: Double = 360
    /// Lowest height Claude keeps under the file: its prompt, a few lines of output, status strip.
    private static let minTerminalHeight: Double = 260

    private var repo: URL { viewModel.projectRepositories.repoURL(for: project.id) }
    private var editor: WorkspaceEditorState { viewModel.workspaceEditors.state(for: project.id) }
    private var sessions: [WorkspaceTerminalSession] { terminals.sessions(for: project.id) }
    /// No tab left in the workspace's own strip (all in windows, or all closed): the file takes
    /// the whole width and a bar offers the way back.
    private var isPoppedOut: Bool { sessions.isEmpty && terminals.hasStarted(project.id) }
    /// Claude is shown minimized: only below an open file, while its strip has tabs.
    private var showsMinimized: Bool { claudeMinimized && claudeBelow && editor.document != nil && !isPoppedOut }

    var body: some View {
        // A hand-made split: HSplitView ignores the preferred width.
        GeometryReader { proxy in
            let document = editor.document
            // The terminals keep at least one full pane next to the editor.
            let room = proxy.size.width - 1 - WorkspaceTerminalPane.minPaneWidth
            let shownEditorWidth = max(320, min(editorWidth, room))
            // Below: the file keeps 160 pt, Claude keeps its minimum height.
            let heightRoom = proxy.size.height - 1 - Self.minTerminalHeight
            let shownEditorHeight = max(160, min(editorHeight, heightRoom))
            // Minimized, Claude keeps only its tab strip and the file takes the rest.
            let minimizedEditorHeight = max(160, proxy.size.height - 1 - WorkspaceTerminalPane.tabStripHeight)
            let restoredTerminalHeight = proxy.size.height - 1 - shownEditorHeight
            HStack(spacing: 0) {
                if isPoppedOut {
                    VStack(spacing: 0) {
                        if let document {
                            editorPane(document)
                        } else {
                            Text("Click a file to open it here.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        Divider()
                        poppedOutBar
                    }
                } else if let document, claudeBelow {
                    VStack(spacing: 0) {
                        editorPane(document)
                            .frame(height: showsMinimized ? minimizedEditorHeight : shownEditorHeight)
                        rowDivider(
                            shown: showsMinimized ? minimizedEditorHeight : shownEditorHeight,
                            room: max(160, heightRoom))
                        terminalPane(restoredHeight: restoredTerminalHeight)
                    }
                } else {
                    if let document {
                        editorPane(document)
                            .frame(width: shownEditorWidth)
                        divider(
                            width: $editorWidth, shown: shownEditorWidth, range: 320...max(320, room),
                            defaultWidth: Self.defaultEditorWidth, label: "File width")
                    }
                    terminalPane(restoredHeight: restoredTerminalHeight)
                }
            }
        }
        .onDisappear { editor.save() }
        // Tabs coming back from windows bring a minimized Claude up with them.
        .onChange(of: isPoppedOut) { was, now in
            if was, !now { claudeMinimized = false }
        }
        .task(id: project.id) {
            viewModel.projectRepositories.ensureRepository(for: project)
            // Outside `body`: creating a terminal (and launching Claude) during a render caused
            // AttributeGraph cycles that froze the view's updates.
            terminals.ensureSession(in: project.id, projectID: project.id) { viewModel.workspaceLaunch(for: project, kind: $0) }
            while !Task.isCancelled {
                editor.refreshFromDisk()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func editorPane(_ document: WorkspaceDocument) -> some View {
        WorkspaceEditorPane(document: document, repo: repo) {
            editor.close()
        }
        .id(document.url)
    }

    /// The workspace's strip of sessions. `restoredHeight` is how tall it is when not minimized,
    /// so moving a minimized Claude into a window opens the window at that height.
    @ViewBuilder
    private func terminalPane(restoredHeight: Double) -> some View {
        if sessions.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WorkspaceTerminalPane(
                project: project, terminals: terminals,
                placement: .init(mode: claudeBelow ? .below : .beside) { mode in
                    switch mode {
                    case .beside: claudeBelow = false
                    case .below: claudeBelow = true
                    case .window: popOut(restoredHeight: restoredHeight)
                    }
                    claudeMinimized = false
                },
                restoreFromMinimized: showsMinimized ? { claudeMinimized = false } : nil)
            .frame(minWidth: 360, maxWidth: .infinity)
        }
    }

    /// Shown where Claude was while its sessions are in windows, or after all were closed.
    private var poppedOutBar: some View {
        let windows = terminals.windows(rootedAt: project.id)
        return HStack(spacing: 10) {
            Image(systemName: windows.isEmpty ? "sparkle" : "macwindow.on.rectangle")
                .foregroundStyle(.secondary)
            Text(windows.isEmpty ? "No Claude session" : windows.count == 1 ? "Claude is in its own window" : "Claude is in \(windows.count) windows")
                .foregroundStyle(.secondary)
            Spacer()
            if !windows.isEmpty {
                Button("Show") {
                    for window in windows { terminals.dropZoneView(for: window.id)?.window?.makeKeyAndOrderFront(nil) }
                }
                Button("Bring Back") { terminals.bringBack(rootID: project.id) }
            }
            Button {
                terminals.addSession(in: project.id, kind: .claude(model: "opus")) { viewModel.workspaceLaunch(for: project, kind: $0) }
            } label: { Label("New Claude Session", systemImage: "sparkle") }
            .disabled(!terminals.canAddSession(in: project.id))
            Button {
                terminals.addSession(in: project.id, kind: .terminal) { viewModel.workspaceLaunch(for: project, kind: $0) }
            } label: { Label("New Terminal", systemImage: "apple.terminal") }
            .disabled(!terminals.canAddSession(in: project.id, kind: .terminal))
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.background.secondary)
    }

    /// Moves every tab of the workspace into one new window, opened over the strip it leaves
    /// so the panes keep their arrangement and room. A minimized strip is only its tab bar, so
    /// the window grows upward to the height Claude has when brought back.
    private func popOut(restoredHeight: Double) {
        var frame = terminals.windowFrame(over: project.id)
        if showsMinimized, let shown = frame {
            frame = NSRect(
                x: shown.minX, y: shown.minY, width: shown.width,
                height: shown.height + max(0, restoredHeight - WorkspaceTerminalPane.tabStripHeight))
        }
        if let windowID = terminals.tearOff(sessions.map(\.id), from: project.id, frame: frame) {
            openWindow(id: "workspace-claude", value: windowID)
        }
    }

    /// Horizontal divider between the file and Claude below it; drags change the file's height
    /// (160 pt up to `room`, where Claude keeps its minimum height). Dragged on until Claude
    /// would keep less than half its minimum, Claude minimizes to its tab strip; dragged back
    /// above that point, it comes back at the dragged height. Double click goes back to the
    /// default height and brings a minimized Claude back.
    private func rowDivider(shown: Double, room: Double) -> some View {
        SplitResizeHandle(
            axis: .vertical,
            // The editor's scroller above and Claude's tab strip below keep their clicks.
            grabLeading: 2,
            grabTrailing: 3,
            accessibilityLabel: "File height",
            accessibilityValue: showsMinimized ? "Claude minimized" : "\(Int(shown)) points",
            onBegan: {
                dragStartWidth = shown
                dragStartEditorHeight = editorHeight
            },
            onChanged: { translation in
                let proposed = (dragStartWidth ?? shown) + translation
                if proposed > room + Self.minTerminalHeight / 2 {
                    guard !claudeMinimized else { return }
                    claudeMinimized = true
                    editorHeight = dragStartEditorHeight ?? editorHeight
                } else {
                    claudeMinimized = false
                    editorHeight = min(room, max(160, proposed))
                }
            },
            onEnded: {
                dragStartWidth = nil
                dragStartEditorHeight = nil
            },
            onDoubleClick: {
                claudeMinimized = false
                editorHeight = Self.defaultEditorHeight
            })
            .frame(height: 1)
            .zIndex(1)
    }

    /// Vertical divider; drags change the width of the area on its left, double click goes back
    /// to the default.
    private func divider(
        width: Binding<Double>, shown: Double, range: ClosedRange<Double>, defaultWidth: Double, label: String
    ) -> some View {
        SplitResizeHandle(
            axis: .horizontal,
            // The editor's scroller on the left keeps its clicks.
            grabLeading: 2,
            accessibilityLabel: label,
            accessibilityValue: "\(Int(shown)) points",
            onBegan: { dragStartWidth = shown },
            onChanged: { translation in
                let start = dragStartWidth ?? shown
                width.wrappedValue = min(range.upperBound, max(range.lowerBound, start + translation))
            },
            onEnded: { dragStartWidth = nil },
            onDoubleClick: { width.wrappedValue = defaultWidth })
            .frame(width: 1)
            .zIndex(1)
    }
}
