// Purpose: WorkspaceTerminalPane, one strip of Claude sessions and plain terminals: a tab strip,
//          the focused session in one pane (or several in splits the user made), each framed in
//          its status colour, and the status strip. Shown in a project's workspace, in the
//          Claude (General) window and in windows tabs were dragged out into.
// Dependencies: Sources/App/Supporting/WorkspaceTerminalStore.swift (sessions, focus, status,
//               windows, panes), Sources/App/Supporting/WorkspaceTerminalSplit.swift (pane
//               frames, dividers, drop zones), Sources/App/Supporting/TerminalTabDragController.swift
//               (tab drags), Sources/App/Components/SplitResizeHandle.swift (dividers),
//               Sources/App/ViewModels/AppViewModel.swift (workspaceLaunch(for:kind:),
//               mcpServer), SwiftTerm
// Used by: Sources/App/Views/ProjectWorkspaceView.swift, Sources/App/Views/ClaudeAssistantWindowView.swift,
//          Sources/App/Views/WorkspaceClaudeWindowView.swift
// Notes: Split panes (user request 2026-10-13, replaces design review 3's "as many 480 pt panes
//        side by side as fit", which split the view as soon as a second tab opened): one pane
//        by default, showing the focused tab; clicking a tab shows it in the focused pane, or
//        focuses its pane when it is already shown. Splits come from two places: dragging a
//        tab onto a pane (VS Code drop zones: outer 30 percent of a side splits there, the middle
//        shows it in that pane; a translucent accent fill with a thin outline marks the half or
//        the pane it will take, animated unless Reduce Motion), and Split Right / Split Down in a
//        tab's menu (that tab in a new pane beside its own pane, or beside the focused one when
//        hidden). The strip has no split buttons: dragging covers it and they crowded the strip.
//        Panes are at least 280 x 160 pt; menu items disable when a split would go below.
//        Dividers are SplitResizeHandle (hairline, grabber pill, wide grab area, resize
//        cursor), like ProjectWorkspaceView's; double click splits evenly again. Terminals keep
//        a 10 pt margin along the strip's outer edges and 6 pt where panes meet. With more
//        than one pane the focused one gets a neutral 2 pt line along its top (no colour: the frames carry status), and a
//        pane shows a small "minus" button at its top right on hover that closes the pane while
//        its session keeps running as a tab (minus, not a cross, since nothing is ended); the
//        tab menu has the same as "Close Pane". Tabs shown in a pane have a faint fill, the
//        focused one a stronger fill. No split shortcuts: Cmd+backslash is awkward on a
//        German layout. The Claude button starts an Opus
//        session, its right click offers Sonnet (at most six per project, windows included). Closing a
//        session where Claude still runs asks first; the workspace's own last tab cannot be
//        closed, a window's last tab closes the window. The status strip speaks for the focused
//        session. Shortcuts: Shift+Opt+Cmd+N new terminal, Opt+Cmd+Left/Right move between sessions
//        (no backtick or bracket chords: dead keys on a German layout). A one-time banner
//        explains Claude's folder trust question.
//        Status (user request 2026-10-13, design review 5): each pane gets a frame in the
//        status colour, drawn as an inset overlay so the terminal never shifts: working blue,
//        thin and half strength (it is the normal state); waiting orange, done green, error red
//        at full strength; idle none; thicker with Increase Contrast. System colours, not theme
//        colours. Tabs repeat it with a shape (spinner, dot, check, triangle) for colour
//        blindness. Focus is a neutral tab fill and medium weight only (the accent can be any
//        colour, even orange or blue).
//        Windows (same request): drag a tab out of the strip to give it its own window, or onto
//        another pane of the same project to move it there (that pane highlights). The tab
//        menu offers the same as "Move to New Window" and "Move to". The workspace strip shows
//        "N in other windows" with a menu to bring each forward or all back.
//        `placement` (user decision 2026-10-05) adds three buttons to the workspace's strip:
//        Claude beside the open file, below it, or all tabs in their own window.
//        Plain terminals (user decision 2026-10-13): the strip has two icon buttons instead of a
//        "+" menu, a Claude one (sparkle, Opus; right click offers Opus or Sonnet) and a terminal
//        one (Shift+Opt+Cmd+N; Opt+Cmd+T is the system's Show Toolbar). The empty state offers
//        New Claude Session beside New Terminal, with the same icons. A
//        terminal tab shows the terminal icon, "Terminal N" and the program in front as a second
//        label ("vim", or "Claude" when typed by hand); no status frame unless Claude runs in it.
//        Closing one asks only while a program besides the shell runs. Its menu says "Restart
//        Terminal"; the status strip shows "Terminal" (with the program) and offers Restart
//        Terminal only after the shell has exited, never "Start Claude" (it would end the shell).
//        Each button disables at its own limit (terminals have a limit of their own).
//        A double click on a tab (or Rename in its menu) edits its name in place: Return or
//        clicking elsewhere keeps it, Esc cancels, an empty name restores the automatic one. The
//        tab cannot be dragged while its name is being edited.
//        Minimized (`restoreFromMinimized`, the workspace's strip below an open file only): the
//        strip shows just its tab strip, which keeps the status icons. A click on a tab brings
//        it back with that tab focused, as do a double click on the strip's free space and a
//        new session started from its buttons.

import AppKit
import SwiftTerm
import SwiftUI

struct WorkspaceTerminalPane: View {
    /// The project whose repo the sessions run in.
    let project: Project
    /// Which strip to show: the project's workspace (default), the Claude window or a window.
    var key: UUID? = nil
    let terminals: WorkspaceTerminalStore
    /// When set, the status strip offers "Show Files" (the Claude window has no file tree).
    var showFiles: (() -> Void)? = nil
    /// Where Claude sits relative to the open file; when set, the tab strip shows the three
    /// placement buttons (the project workspace only).
    var placement: Placement? = nil
    /// When set, the strip is minimized below the open file: only the tab strip shows, and the
    /// closure brings the strip back up (the project workspace only).
    var restoreFromMinimized: (() -> Void)? = nil
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pane area's size, for refusing splits that would not fit.
    @State private var contentSize: CGSize = .zero
    @State private var hoveredPane: UUID?
    /// Where the dragged divider sat in its split when the drag began.
    @State private var dividerDragStart: CGFloat?
    @State private var pendingClose: WorkspaceTerminalSession?
    @State private var showTrustHint = false
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    /// Width that gives Claude Code about 80 columns in SF Mono 12; the workspace keeps at least
    /// this much for the strip beside an open file.
    static let minPaneWidth: CGFloat = 480
    static let tabStripHeight: CGFloat = 32

    /// Claude beside the open file, below it, or in its own window, and how to switch.
    struct Placement {
        enum Mode { case beside, below, window }
        let mode: Mode
        let choose: (Mode) -> Void
    }

    private var groupKey: UUID { key ?? project.id }
    private var group: WorkspaceTerminalLayout.Group? { terminals.group(groupKey) }
    private var rootID: UUID { group?.rootID ?? groupKey }
    private var isWindow: Bool { group?.isWindow ?? false }
    private var sessions: [WorkspaceTerminalSession] { terminals.sessions(for: groupKey) }
    private var focusedID: UUID? { terminals.focusedID(in: groupKey) }
    private var focusedSession: WorkspaceTerminalSession? { terminals.targetSession(for: groupKey) }
    private var split: WorkspaceTerminalSplit { group?.split ?? WorkspaceTerminalSplit() }
    private var trustHintKey: String { "mm.workspaceTrustHintShown.\(project.id.uuidString)" }
    private var isMinimized: Bool { restoreFromMinimized != nil }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            if !isMinimized {
                Divider()
                if showTrustHint { trustBanner }
                if sessions.isEmpty {
                    emptyState
                } else {
                    paneArea
                }
                Divider()
                statusStrip
            }
        }
        .background(DropZoneReporter { terminals.registerDropZone($0, for: groupKey) })
        .overlay {
            if case .strip(let target) = terminals.dropTarget, target == groupKey {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentColor.opacity(0.06))
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .background(shortcuts)
        .onAppear { showTrustHint = !UserDefaults.standard.bool(forKey: trustHintKey) }
        .confirmationDialog(
            "Close \(pendingClose?.displayName ?? "this session")?",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingClose?.isTerminal == true ? "Close Terminal" : "Close Session", role: .destructive) {
                if let session = pendingClose { terminals.close(session.id) }
                pendingClose = nil
            }
        } message: {
            if let session = pendingClose, session.isTerminal, session.foreground != .claude {
                Text("\(session.program ?? "A program") is still running in it and will be ended.")
            } else {
                Text("Claude is still running in it. Its conversation ends.")
            }
        }
    }

    // MARK: - Panes

    /// The split tree, laid out by hand: every pane and divider is placed at the frame the
    /// split computes, so the drag controller can find the same frames without SwiftUI.
    private var paneArea: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let split = split
            let frames = split.paneFrames(in: size)
            ZStack(alignment: .topLeading) {
                ForEach(split.panes) { pane in
                    if let session = terminals.session(pane.sessionID), let frame = frames[pane.id] {
                        paneView(session, pane: pane.id, isSplit: split.isSplit, insets: Self.insets(of: frame, in: size))
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                ForEach(split.dividers(in: size)) { divider in
                    splitDivider(divider)
                }
                dropHighlight(frames: frames)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .onAppear { contentSize = size }
            .onChange(of: size) { _, newSize in contentSize = newSize }
        }
        .background(DropZoneReporter { terminals.registerContentZone($0, for: groupKey) })
    }

    /// The terminal's margin in a pane: 10 pt along the strip's outer edges, 6 pt where it
    /// meets another pane, so neighbouring terminals do not sit a wide gap apart.
    private static func insets(of frame: CGRect, in size: CGSize) -> EdgeInsets {
        let outer: CGFloat = 10, inner: CGFloat = 6
        return EdgeInsets(
            top: frame.minY > 0.5 ? inner : outer,
            leading: frame.minX > 0.5 ? inner : outer,
            bottom: frame.maxY < size.height - 0.5 ? inner : outer,
            trailing: frame.maxX < size.width - 0.5 ? inner : outer)
    }

    private func paneView(
        _ session: WorkspaceTerminalSession, pane: UUID, isSplit: Bool, insets: EdgeInsets
    ) -> some View {
        let isFocused = session.id == focusedID
        return TerminalHost(view: session.view, takesFocus: isFocused) {
            terminals.setFocused(session.id)
        }
        .padding(insets)
        // Not into the safe area: under a window's toolbar the strip above sits in it, and the
        // pane, drawn after the strip, would paint over the tabs there.
        .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
        // Selecting text in the top rows must not move the window when they sit under the title bar.
        .excludedFromWindowDrag()
        .overlay { statusFrame(session) }
        .overlay(alignment: .top) {
            if isSplit, isFocused {
                Rectangle()
                    .fill(Color.primary.opacity(contrast == .increased ? 0.6 : 0.3))
                    .frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSplit, hoveredPane == pane {
                Button {
                    terminals.closePane(pane, in: groupKey)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close Pane (\(session.displayName) keeps running as a tab)")
                // Clear of the dividers' grab areas, in line with the terminal's padding.
                .padding(10)
            }
        }
        .onHover { inside in
            if inside { hoveredPane = pane } else if hoveredPane == pane { hoveredPane = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.accessibilityDescription)
    }

    /// The line between two panes with its grabber pill; dragging moves it from where it was when
    /// the drag began (the shown position, already kept clear of the minimum sizes), double
    /// click splits evenly again.
    private func splitDivider(_ divider: WorkspaceTerminalSplit.Divider) -> some View {
        let horizontal = divider.axis == .horizontal
        let bounds = divider.bounds
        let extent = max(1, (horizontal ? bounds.width : bounds.height) - WorkspaceTerminalSplit.dividerThickness)
        let shownOffset = horizontal ? divider.frame.minX - bounds.minX : divider.frame.minY - bounds.minY
        return SplitResizeHandle(
            axis: horizontal ? .horizontal : .vertical,
            accessibilityLabel: horizontal ? "Pane width" : "Pane height",
            accessibilityValue: "\(Int((shownOffset / extent * 100).rounded())) percent",
            onBegan: { dividerDragStart = shownOffset },
            onChanged: { translation in
                let start = dividerDragStart ?? shownOffset
                terminals.setSplitFraction(divider.id, to: Double((start + translation) / extent), in: groupKey)
            },
            onEnded: { dividerDragStart = nil },
            onDoubleClick: { terminals.setSplitFraction(divider.id, to: 0.5, in: groupKey) })
            .frame(width: divider.frame.width, height: divider.frame.height)
            .position(x: divider.frame.midX, y: divider.frame.midY)
    }

    /// Where the dragged tab would land on a pane of this strip: the half it splits off, or the
    /// whole pane it would show in.
    @ViewBuilder
    private func dropHighlight(frames: [UUID: CGRect]) -> some View {
        if case .pane(let target, let paneID, let zone) = terminals.dropTarget, target == groupKey,
           let frame = frames[paneID]
        {
            let rect = WorkspaceTerminalSplit.highlight(for: zone, in: frame).insetBy(dx: 4, dy: 4)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5))
                .frame(width: max(0, rect.width), height: max(0, rect.height))
                .position(x: rect.midX, y: rect.midY)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: rect)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func statusFrame(_ session: WorkspaceTerminalSession) -> some View {
        if let color = session.status.frameColor {
            let working = session.status == .working
            let width: CGFloat = contrast == .increased ? 3 : (working ? 1.5 : 2)
            RoundedRectangle(cornerRadius: 6)
                .inset(by: 3)
                .strokeBorder(color.opacity(working && contrast != .increased ? 0.5 : 1), lineWidth: width)
                .allowsHitTesting(false)
        }
    }

    private var emptyState: some View {
        let windows = terminals.windows(rootedAt: rootID)
        return VStack(spacing: 10) {
            Image(systemName: windows.isEmpty ? "sparkle" : "macwindow.on.rectangle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(windows.isEmpty ? "No Claude session" : "Claude is in \(windows.count == 1 ? "its own window" : "\(windows.count) windows")")
                .foregroundStyle(.secondary)
            HStack {
                if !windows.isEmpty {
                    Button("Show") { bringForward(windows) }
                    Button("Bring Back") { terminals.bringBack(rootID: rootID) }
                }
                Button { addSession(.claude(model: "opus")) } label: { Label("New Claude Session", systemImage: "sparkle") }
                    .disabled(!terminals.canAddSession(in: groupKey))
                Button { addSession(.terminal) } label: { Label("New Terminal", systemImage: "apple.terminal") }
                    .disabled(!terminals.canAddSession(in: groupKey, kind: .terminal))
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tabs

    private var tabStrip: some View {
        let shown = Set(split.visibleSessionIDs)
        return HStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(sessions) { session in
                            tab(session, isShown: shown.contains(session.id))
                        }
                    }
                    .padding(.horizontal, 6)
                    // Under the title bar a drag on a tab moves the tab, not the window; the
                    // free space after the tabs still moves the window there.
                    .excludedFromWindowDrag()
                    // The free space after the tabs takes a double click that brings a
                    // minimized strip back up; not minimized, only the tabs' own gestures run.
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(
                        TapGesture(count: 2).onEnded { restoreFromMinimized?() },
                        including: isMinimized ? .all : .subviews)
                }
                // Under the title bar the scroll edge effect would cover the whole strip.
                .hidesTitlebarScrollEdge()
            }
            if !isWindow, !sessions.isEmpty, !terminals.windows(rootedAt: rootID).isEmpty {
                otherWindowsMenu
                    .padding(.horizontal, 6)
            }
            if let placement, !sessions.isEmpty {
                Divider().frame(height: 18)
                placementButtons(placement)
                    .padding(.horizontal, 6)
            }
            if isWindow {
                Divider().frame(height: 18)
                Button {
                    terminals.moveToRoot(groupKey)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(rootID == WorkspaceTerminalStore.assistantKey ? "Move All to the Claude Window" : "Move All to the Workspace")
                .padding(.horizontal, 6)
            }
            Divider().frame(height: 18)
            newSessionButtons
                .padding(.horizontal, 6)
        }
        .frame(height: Self.tabStripHeight)
        .background(.background.secondary)
    }

    private func tab(_ session: WorkspaceTerminalSession, isShown: Bool) -> some View {
        let isFocused = session.id == focusedID
        return HStack(spacing: 6) {
            statusIcon(session)
                .frame(width: 14, height: 14)
            if renamingID == session.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .frame(width: 140)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(session) }
                    .onExitCommand { renamingID = nil }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused, renamingID == session.id { commitRename(session) }
                    }
            } else {
                Text(session.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 170, alignment: .leading)
                    .fontWeight(isFocused ? .medium : .regular)
            }
            if let running = session.runningLabel {
                Text(running)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 80, alignment: .leading)
            } else if let model = session.model, model != "opus" {
                Text(session.modelName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if canClose {
                Button {
                    requestClose(session)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(session.isTerminal ? "Close Terminal" : "Close Session")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isShown ? Color.primary.opacity(isFocused ? 0.14 : 0.05) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            restoreFromMinimized?()
            focus(session)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(session) })
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { _ in TerminalTabDragController.shared.update(session: session, from: groupKey, store: terminals) }
            .onEnded { _ in handle(TerminalTabDragController.shared.end(), for: session) },
            including: renamingID == session.id ? .subviews : .all)
        .help(session.accessibilityDescription)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.accessibilityDescription)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .accessibilityAction(named: "Move to New Window") { moveToNewWindow(session) }
        .contextMenu { tabMenu(session) }
    }

    @ViewBuilder
    private func statusIcon(_ session: WorkspaceTerminalSession) -> some View {
        if session.foreground != .claude, session.status != .error {
            Image(systemName: "terminal").foregroundStyle(.secondary)
        } else {
            switch session.status {
            case .idle:
                Image(systemName: "sparkle").foregroundStyle(.secondary)
            case .working:
                ProgressView().controlSize(.mini)
            case .waiting:
                Circle().fill(Color.orange).frame(width: 7, height: 7)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.red)
            }
        }
    }

    @ViewBuilder
    private func tabMenu(_ session: WorkspaceTerminalSession) -> some View {
        Button("Rename\u{2026}") { startRename(session) }
        Button(session.isTerminal ? "Restart Terminal" : "Restart Claude") { restart(session) }
        Divider()
        Button("Split Right") { splitTab(session, .right) }
            .disabled(!canSplitTab(session, .right))
        Button("Split Down") { splitTab(session, .bottom) }
            .disabled(!canSplitTab(session, .bottom))
        if split.isSplit, let pane = split.paneID(showing: session.id) {
            Button("Close Pane") { terminals.closePane(pane, in: groupKey) }
        }
        Divider()
        if !(isWindow && sessions.count == 1) {
            Button("Move to New Window") { moveToNewWindow(session) }
        }
        let targets = moveTargets
        if !targets.isEmpty {
            Menu("Move to") {
                ForEach(targets, id: \.id) { target in
                    Button(target.name) { move(session, to: target.id) }
                }
            }
        }
        if canClose {
            Divider()
            Button(session.isTerminal ? "Close Terminal" : "Close Session", role: .destructive) { requestClose(session) }
        }
    }

    /// The other strips of this workspace (or Claude window) a tab can move to.
    private var moveTargets: [(id: UUID, name: String)] {
        var targets: [(id: UUID, name: String)] = []
        if rootID != groupKey {
            targets.append((rootID, rootID == WorkspaceTerminalStore.assistantKey ? "Claude Window" : "Workspace"))
        }
        for window in terminals.windows(rootedAt: rootID) where window.id != groupKey {
            let names = terminals.sessions(for: window.id).map(\.displayName)
            targets.append((window.id, "Window: " + names.joined(separator: ", ")))
        }
        return targets
    }

    private var otherWindowsMenu: some View {
        let windows = terminals.windows(rootedAt: rootID)
        let elsewhere = windows.flatMap { terminals.sessions(for: $0.id) }
        return Menu {
            ForEach(elsewhere) { session in
                Button(session.accessibilityDescription) { bringForward(session) }
            }
            Divider()
            Button("Bring All Back") { terminals.bringBack(rootID: rootID) }
        } label: {
            HStack(spacing: 4) {
                if elsewhere.contains(where: { $0.status == .waiting }) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
                Text("\(elsewhere.count) in other window\(windows.count == 1 ? "" : "s")")
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Sessions of this workspace in their own windows")
    }

    private func placementButtons(_ placement: Placement) -> some View {
        HStack(spacing: 2) {
            placementButton(placement, .beside, icon: "rectangle.split.2x1", help: "Claude beside the file")
            placementButton(placement, .below, icon: "rectangle.split.1x2", help: "Claude below the file")
            placementButton(placement, .window, icon: "macwindow.on.rectangle", help: "Claude in its own window")
        }
    }

    private func placementButton(
        _ placement: Placement, _ mode: Placement.Mode, icon: String, help: String
    ) -> some View {
        let isCurrent = placement.mode == mode
        return Button {
            placement.choose(mode)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isCurrent ? Color.primary.opacity(0.10) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        .help(help)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// Two plain icon buttons: one starts Claude, one a terminal. Right click on the Claude
    /// button picks the model.
    private var newSessionButtons: some View {
        let canAddClaude = terminals.canAddSession(in: groupKey)
        let canAddTerminal = terminals.canAddSession(in: groupKey, kind: .terminal)
        return HStack(spacing: 2) {
            Button { addSession(.claude(model: "opus")) } label: {
                Image(systemName: "sparkle").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled(!canAddClaude)
            .contextMenu {
                Button("New Opus Session") { addSession(.claude(model: "opus")) }
                Button("New Sonnet Session") { addSession(.claude(model: "sonnet")) }
            }
            .help(canAddClaude
                ? "New Claude Session. Right click for Sonnet. Sessions share the folder: give them different files to work on."
                : "Up to \(WorkspaceTerminalStore.maxSessions) Claude sessions per workspace, windows included.")
            Button { addSession(.terminal) } label: {
                Image(systemName: "apple.terminal").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled(!canAddTerminal)
            .help(canAddTerminal
                ? "New Terminal (\u{21E7}\u{2325}\u{2318}N)"
                : "Up to \(WorkspaceTerminalStore.maxSessions) terminals per workspace, windows included.")
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    /// Hidden buttons carrying the strip's keyboard shortcuts.
    private var shortcuts: some View {
        ZStack {
            Button("New Terminal") { addSession(.terminal) }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            Button("Previous Session") { moveFocus(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Session") { moveFocus(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    /// A window's last tab can be closed (the window goes); the workspace keeps one.
    private var canClose: Bool { isWindow || sessions.count > 1 }

    private func launch(_ kind: WorkspaceTerminalSession.Kind) -> AppViewModel.ClaudeLaunch {
        viewModel.workspaceLaunch(for: project, kind: kind)
    }

    private func startRename(_ session: WorkspaceTerminalSession) {
        renameText = session.displayName
        renamingID = session.id
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    private func commitRename(_ session: WorkspaceTerminalSession) {
        renamingID = nil
        terminals.rename(session, to: renameText)
    }

    private func addSession(_ kind: WorkspaceTerminalSession.Kind) {
        restoreFromMinimized?()
        terminals.addSession(in: groupKey, kind: kind, launch: launch)
    }

    private func restart(_ session: WorkspaceTerminalSession) {
        terminals.restart(session, launch: launch)
    }

    /// Asks first while Claude, or in a plain terminal any program besides the shell, runs.
    private func requestClose(_ session: WorkspaceTerminalSession) {
        if session.foreground == .claude || (session.isTerminal && session.program != nil) {
            pendingClose = session
        } else {
            terminals.close(session.id)
        }
    }

    private func focus(_ session: WorkspaceTerminalSession) {
        terminals.setFocused(session.id)
        session.view.window?.makeFirstResponder(session.view)
    }

    private func moveFocus(by step: Int) {
        guard let index = sessions.firstIndex(where: { $0.id == focusedID }) else { return }
        let next = index + step
        guard sessions.indices.contains(next) else { return }
        focus(sessions[next])
    }

    // MARK: - Splits

    /// The pane area's size once laid out; nil before (no size check then).
    private var paneAreaSize: CGSize? { contentSize == .zero ? nil : contentSize }

    /// The pane a tab's Split Right / Split Down splits: its own when shown, else the focused one.
    private func splitTarget(for session: WorkspaceTerminalSession) -> UUID? {
        split.paneID(showing: session.id) ?? group?.focusedPaneID
    }

    private func canSplitTab(_ session: WorkspaceTerminalSession, _ zone: WorkspaceTerminalSplit.DropZone) -> Bool {
        guard let pane = splitTarget(for: session) else { return false }
        return terminals.canPlace(session.id, in: groupKey, pane: pane, zone: zone, size: paneAreaSize)
    }

    private func splitTab(_ session: WorkspaceTerminalSession, _ zone: WorkspaceTerminalSplit.DropZone) {
        guard let pane = splitTarget(for: session) else { return }
        if terminals.place(session.id, in: groupKey, pane: pane, zone: zone, size: paneAreaSize) { focusSoon(session) }
    }

    /// The pane re-attaches the terminal view on its next update; put the cursor there afterwards.
    private func focusSoon(_ session: WorkspaceTerminalSession) {
        DispatchQueue.main.async { bringForward(session) }
    }

    private func handle(_ outcome: TerminalTabDragController.Outcome, for session: WorkspaceTerminalSession) {
        switch outcome {
        case .none:
            break
        case .move(let target):
            move(session, to: target)
        case .place(let groupID, let paneID, let zone):
            if terminals.place(session.id, in: groupID, pane: paneID, zone: zone) { focusSoon(session) }
        case .newWindow(let frame):
            if let windowID = terminals.tearOff([session.id], from: groupKey, frame: frame) {
                openWindow(id: "workspace-claude", value: windowID)
            }
        case .moveWindow(let topLeft):
            // A full-screen window keeps its place; moving it would break its layout.
            if let window = terminals.dropZoneView(for: groupKey)?.window, !window.styleMask.contains(.fullScreen) {
                window.setFrameTopLeftPoint(topLeft)
            }
        }
    }

    /// A new window next to this one (keyboard and VoiceOver path; dragging places it at the pointer).
    private func moveToNewWindow(_ session: WorkspaceTerminalSession) {
        var frame: NSRect?
        if let window = terminals.dropZoneView(for: groupKey)?.window {
            let size = NSSize(width: max(520, window.frame.width * 0.6), height: max(360, window.frame.height * 0.8))
            frame = NSRect(x: window.frame.minX + 40, y: window.frame.maxY - 40 - size.height, width: size.width, height: size.height)
        }
        if let windowID = terminals.tearOff([session.id], from: groupKey, frame: frame) {
            openWindow(id: "workspace-claude", value: windowID)
        }
    }

    private func move(_ session: WorkspaceTerminalSession, to target: UUID) {
        terminals.move(session.id, to: target)
        // The pane re-attaches the terminal view on its next update; focus it there afterwards.
        DispatchQueue.main.async { bringForward(session) }
    }

    private func bringForward(_ session: WorkspaceTerminalSession) {
        terminals.setFocused(session.id)
        session.view.window?.makeKeyAndOrderFront(nil)
        session.view.window?.makeFirstResponder(session.view)
    }

    private func bringForward(_ windows: [WorkspaceTerminalLayout.Group]) {
        for window in windows {
            terminals.dropZoneView(for: window.id)?.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Banner and status

    private var trustBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("Claude asks once whether to trust this folder. Choose \u{201C}Yes, I trust this folder\u{201D} to continue.")
                .lineLimit(2)
            Spacer()
            Button("Got It") {
                UserDefaults.standard.set(true, forKey: trustHintKey)
                showTrustHint = false
            }
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.08))
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
            if let session = focusedSession {
                switch (session.isTerminal, session.foreground) {
                case (true, .claude):
                    Label("Claude Code", systemImage: "sparkle")
                case (true, .shell):
                    Label(session.program.map { "Terminal \u{00B7} \($0)" } ?? "Terminal", systemImage: "terminal")
                        .foregroundStyle(.secondary)
                case (true, .none):
                    Label("Shell exited", systemImage: "terminal")
                        .foregroundStyle(.secondary)
                case (false, .claude):
                    Label("Claude Code \u{00B7} \(session.modelName)", systemImage: "sparkle")
                case (false, _):
                    Label("Shell", systemImage: "terminal")
                        .foregroundStyle(.secondary)
                }
            }
            mcpStatus
            Spacer()
            if let showFiles {
                Button("Show Files", action: showFiles)
                    .buttonStyle(.borderless)
                    .help("Show the General workspace's files in the main window")
            }
            if let session = focusedSession {
                if session.isTerminal {
                    // A plain terminal offers a restart only once its shell is gone (a Claude
                    // typed there by hand is the user's, not ours to restart).
                    if session.foreground == .none {
                        Button("Restart Terminal") { restart(session) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                } else if session.foreground == .claude {
                    Button("Restart Claude") { restart(session) }
                        .buttonStyle(.borderless)
                } else {
                    Button("Start Claude") { restart(session) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }

    @ViewBuilder
    private var mcpStatus: some View {
        switch viewModel.mcpServer.status {
        case .running:
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("MinuteMind tools available")
            }
            .help("Claude can read meetings, knowledge, tasks and notes through the local MCP server.")
        case .failed(let message):
            Label("MCP server failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        default:
            HStack(spacing: 4) {
                Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 6, height: 6)
                Text("MinuteMind tools off (Settings \u{203A} Integrations)")
            }
            .foregroundStyle(.secondary)
        }
    }
}

extension TerminalSessionStatus {
    /// The pane frame's colour; idle has none.
    var frameColor: SwiftUI.Color? {
        switch self {
        case .idle: nil
        case .working: .blue
        case .waiting: .orange
        case .done: .green
        case .error: .red
        }
    }
}

/// Hands the pane's backing view to the store, so tab drags can find it on screen. Flipped, so
/// points in it are y down like the split's pane frames.
private struct DropZoneReporter: NSViewRepresentable {
    let register: (NSView) -> Void

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        DispatchQueue.main.async { register(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { register(view) }
    }
}

/// Re-parents a store-owned terminal view into the SwiftUI hierarchy and reports when the user
/// clicks or tabs into it (the window's first responder becomes the terminal).
private struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView
    let takesFocus: Bool
    let onFocus: () -> Void

    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()
        container.onFocus = onFocus
        attach(to: container)
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        container.onFocus = onFocus
        if view.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
    }

    private func attach(to container: TerminalContainer) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        container.terminal = view
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if takesFocus {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                container.window?.makeFirstResponder(view)
            }
        }
    }
}

final class TerminalContainer: NSView {
    weak var terminal: NSView?
    var onFocus: (() -> Void)?
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, let terminal = self.terminal, window.firstResponder === terminal else { return }
                self.onFocus?()
            }
        }
    }
}
