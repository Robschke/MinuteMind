// Purpose: WorkspaceTerminalStore, keeps the live terminals of every project (SwiftTerm running
//          Claude Code, or a plain login shell, in the project's repo) so switching tabs or
//          projects never kills a running agent, and knows which tab strip (workspace pane or
//          window) and which split pane each session sits in and what it is doing.
// Dependencies: SwiftTerm (LocalProcessTerminalView), AppKit, Darwin (libproc, tcgetpgrp, sysctl),
//               Sources/App/Supporting/WorkspaceTerminalLayout.swift (strips and windows),
//               Sources/App/Supporting/WorkspaceTerminalSplit.swift (panes, drop zones),
//               Sources/App/Supporting/TerminalSessionStatus.swift (status from hooks),
//               Sources/App/Supporting/ClaudeSessionRequest.swift (what a session asks, answers),
//               Sources/App/ViewModels/AppViewModel.swift (workspaceLaunch(for:kind:))
// Used by: Sources/App/Views/ProjectWorkspaceView.swift, Sources/App/Views/WorkspaceTerminalPane.swift,
//          Sources/App/Views/WorkspaceClaudeWindowView.swift, Sources/App/Views/ClaudeAssistantWindowView.swift,
//          Sources/App/Supporting/TerminalTabDragController.swift (drop zones and targets)
// Notes: SwiftUI rebuilds NSViewRepresentables freely; the terminal views (and with them the child
//        processes) therefore live here, and the representable only re-parents them.
//        Strips (user request 2026-10-13, see WorkspaceTerminalLayout): a project's workspace pane
//        (key: project ID), the Claude (General) window (`assistantKey`), and windows tabs were
//        dragged out into. A project has at most `maxSessions` sessions across all its strips
//        (design review: tear-offs must not get around the limit). Sessions are numbered with the
//        lowest free number in their root ("Claude 2" is reused after it closes) and carry the
//        title Claude Code sets (OSC). A root starts its first session by itself once per launch;
//        after the user closed or moved them all it stays empty until asked. Sessions are not
//        restored across app launches.
//        Status: every session gets its own MM_TERMINAL_STATUS file (in `terminal-status/`,
//        cleared at launch, deleted on close) written by Claude Code hooks; a 1 s timer reads it
//        together with output, input and bell times (TerminalStatusTracker) and the foreground
//        process. A session that starts waiting while it is not focused is announced to VoiceOver.
//        Restart replaces a session's view with a fresh one: SwiftTerm refuses to start a second
//        process while one runs, and with `exec zsh` there always is one.
//        The terminal follows the theme's background with SF Mono 12; text and ANSI colours come
//        from TerminalPalette, every one at least 4.5:1 on that background whatever the theme.
//        Claude sessions run with theme "auto" (ProjectRepositoryService.writeClaudeHookSettings):
//        Claude queries the background (OSC 11, answered by SwiftTerm) and picks light or dark.
//        `foregroundProcess` looks for a Claude process under the launch shell (and in the pty's
//        foreground group), so the UI can tell whether Claude or the plain shell is in front.
//        Plain terminals (2026-10-13, `Kind.terminal`): the user's login shell (`-l`) in the
//        repo, as tabs in the same strips, so they drag, move, close and survive tab and project
//        switches like Claude tabs. Decisions: they have their own limit (`maxTerminals`, six)
//        and do not count toward the six Claude sessions, because a shell is cheap and must stay
//        available for git or a build while six agents run; they are numbered on their own
//        ("Terminal 1") and always named that way (shell titles are long user@host:path
//        strings), with the program in front as a second label. No hook status: they get no
//        --settings, so with the shell in front they stay idle; a Claude typed by hand there is
//        detected (strictly: node only when it runs Claude Code's script) and then shows the
//        activity heuristic's status and is offered by "Reference in Claude". A clean `exit`
//        closes the tab, as in Terminal.app.
//        Renaming (user request 2026-10-13): a name the user gives a tab (double click, or Rename
//        in its menu) wins over the title Claude Code sets and over "Terminal N", and survives a
//        restart; an empty name goes back to the automatic one.
//        Split panes (user request 2026-10-13, see WorkspaceTerminalSplit): each strip registers
//        two views, the whole strip (`dropZones`) and the flipped area holding its panes
//        (`contentZones`). A dragged tab over a pane gets that pane's zone (its own strip
//        included); over a strip but not on a usable zone it moves to that strip, or, on its
//        own strip, does nothing (`DropTarget.ownStrip`) instead of opening a window. Size
//        checks use the content area on screen.

import AppKit
import Darwin
import Observation
import SwiftTerm
import SwiftUI

/// One terminal tab of a workspace: a Claude Code session or a plain terminal.
@Observable
@MainActor
final class WorkspaceTerminalSession: Identifiable {
    /// What the tab was started as. A plain terminal runs the user's login shell; Claude can
    /// still be started in it by hand (then `foreground` says so).
    enum Kind: Equatable, Sendable {
        /// Claude Code with a model alias ("opus", "sonnet").
        case claude(model: String)
        case terminal

        var isTerminal: Bool { self == .terminal }
    }

    let id = UUID()
    /// Numbered per kind within a workspace: "Claude 2", "Terminal 1".
    let number: Int
    let kind: Kind
    /// The project whose repo the session runs in.
    let projectID: UUID
    /// The terminal title Claude Code (or the shell) set, trimmed; empty until one arrives.
    fileprivate(set) var title = ""
    /// The name the user gave the tab; nil while the automatic name applies.
    fileprivate(set) var customName: String?
    /// Replaced on restart, so views showing it re-attach the new one.
    fileprivate(set) var view: WorkspaceTerminalView
    fileprivate(set) var status: TerminalSessionStatus = .idle
    fileprivate(set) var foreground: WorkspaceTerminalStore.Foreground
    /// Plain terminals: the program in front when it is not the shell ("vim", "npm"), else nil.
    fileprivate(set) var program: String?
    @ObservationIgnored fileprivate var delegate: TerminalDelegate?
    @ObservationIgnored fileprivate var tracker = TerminalStatusTracker()
    /// The hook file's modification date when it was last read.
    @ObservationIgnored fileprivate var hookFileDate: Date?
    /// The latest status event (from the hook file, or a lone Esc) and when it happened.
    @ObservationIgnored fileprivate var hookDate: Date?
    @ObservationIgnored fileprivate var hookStatus: TerminalSessionStatus?
    /// The latest hook payload, and the last request Claude made (kept apart: a permission
    /// prompt's notification overwrites the request in the file), for the companion's chat card.
    @ObservationIgnored fileprivate var latestPayload: Data?
    @ObservationIgnored fileprivate var requestPayload: Data?

    /// What the session asks of the user right now, nil while it works or idles.
    var request: ClaudeSessionRequest? {
        guard !isTerminal else { return nil }
        return ClaudeSessionRequest.from(request: requestPayload, latest: latestPayload, status: status)
    }

    fileprivate init(number: Int, kind: Kind, projectID: UUID, view: WorkspaceTerminalView) {
        self.number = number
        self.kind = kind
        self.projectID = projectID
        self.view = view
        self.foreground = kind.isTerminal ? .shell : .claude
    }

    var isTerminal: Bool { kind.isTerminal }

    /// The Claude Code model alias ("opus", "sonnet"); nil for a plain terminal.
    var model: String? {
        if case .claude(let model) = kind { return model }
        return nil
    }

    /// "Opus", "Sonnet"; empty for a plain terminal.
    var modelName: String {
        guard let model else { return "" }
        return model.prefix(1).uppercased() + model.dropFirst()
    }

    /// A plain terminal is always "Terminal N": shells set long user@host:path titles.
    var displayName: String {
        if let customName { return customName }
        if isTerminal { return "Terminal \(number)" }
        return title.isEmpty ? "Claude \(number)" : title
    }

    /// What runs in a plain terminal besides the shell, for the tab's second label.
    var runningLabel: String? {
        guard isTerminal else { return nil }
        return foreground == .claude ? "Claude" : program
    }

    /// The file this session's Claude Code hooks write their payloads to.
    var statusFile: URL { WorkspaceTerminalStore.statusDirectory.appendingPathComponent("\(id.uuidString).json") }

    /// "Claude 2, Sonnet, waiting for you", "Terminal 1, running vim": tooltips and VoiceOver.
    var accessibilityDescription: String {
        var parts = [displayName]
        if let model, model != "opus" { parts.append(modelName) }
        if isTerminal, foreground != .claude {
            if let program { parts.append("running \(program)") }
        } else if foreground != .claude {
            parts.append(status == .error ? "Claude exited with an error" : "shell")
        } else {
            if isTerminal { parts.append("Claude") }
            switch status {
            case .idle: break
            case .working: parts.append("working")
            case .waiting: parts.append("waiting for you")
            case .done: parts.append("done")
            case .error: parts.append("error")
            }
        }
        return parts.joined(separator: ", ")
    }
}

@Observable
@MainActor
final class WorkspaceTerminalStore {
    enum Foreground: Equatable { case claude, shell, none }

    /// Groups the sessions of the main page's Claude window (General workspace folder).
    static let assistantKey = UUID(uuidString: "C1A0DE00-0000-0000-0000-000000000001")!

    /// Most Claude sessions per project, across its workspace and its windows.
    static let maxSessions = 6
    /// Most plain terminals per project; they do not count toward `maxSessions`.
    static let maxTerminals = 6

    /// The launch for a tab of a kind: Claude Code with its model, or the login shell.
    typealias Launcher = (WorkspaceTerminalSession.Kind) -> AppViewModel.ClaudeLaunch

    /// Where each session's hooks report (one JSON file per session).
    static let statusDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MinuteMind/terminal-status", isDirectory: true)

    /// Where a dragged tab would land.
    enum DropTarget: Equatable {
        /// Another strip's tab strip or status strip: the tab moves there.
        case strip(UUID)
        /// A pane of a strip: the centre shows the tab there, an edge splits the pane.
        case pane(groupID: UUID, paneID: UUID, zone: WorkspaceTerminalSplit.DropZone)
        /// Its own strip where it has nowhere to go: releasing does nothing.
        case ownStrip
    }

    private(set) var layout = WorkspaceTerminalLayout()
    private var sessionsByID: [UUID: WorkspaceTerminalSession] = [:]
    /// Roots that started their first session this launch (they never auto-start again).
    private var autoStarted: Set<UUID> = []
    /// Where a dragged tab would land, highlighted while the pointer is over it.
    var dropTarget: DropTarget?
    /// Where a window opened for a torn-off tab goes (screen coordinates), taken by the window.
    @ObservationIgnored var pendingWindowFrames: [UUID: NSRect] = [:]
    /// The panes on screen per strip, for finding drop targets during a tab drag.
    @ObservationIgnored private var dropZones: [UUID: WeakView] = [:]
    /// The area holding a strip's panes (below its tab strip), for drop zones inside panes.
    @ObservationIgnored private var contentZones: [UUID: WeakView] = [:]
    @ObservationIgnored private var appearanceObserver: NSKeyValueObservation?
    @ObservationIgnored private var themeObserver: NSObjectProtocol?
    @ObservationIgnored private var timer: Timer?
    /// When each session was last focused (clicked into, or brought forward), for the companion's
    /// double click; ignored by observation so a click redraws nothing.
    @ObservationIgnored private var focusedAt: [UUID: Date] = [:]

    init() {
        appearanceObserver = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.sessionsByID.values.forEach { self.applyPalette($0.view) }
            }
        }
        // A new theme recolours running terminals right away.
        themeObserver = NotificationCenter.default.addObserver(
            forName: .minuteMindThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sessionsByID.values.forEach { self.applyPalette($0.view) }
            }
        }
        // Status files of an earlier launch belong to sessions that no longer exist. Never from a
        // test process: the folder is the real app's, and its running sessions write there.
        if !AppViewModel.isTestProcess { try? FileManager.default.removeItem(at: Self.statusDirectory) }
        try? FileManager.default.createDirectory(at: Self.statusDirectory, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Reading

    func sessions(for groupID: UUID) -> [WorkspaceTerminalSession] {
        (layout.group(groupID)?.sessionIDs ?? []).compactMap { sessionsByID[$0] }
    }

    func session(_ id: UUID) -> WorkspaceTerminalSession? { sessionsByID[id] }

    /// Every Claude session of every project and window (plain terminals left out), for the
    /// desktop companion.
    var claudeSessions: [WorkspaceTerminalSession] {
        sessionsByID.values.filter { !$0.isTerminal }.sorted { $0.number < $1.number }
    }

    /// Every session of a workspace (or the Claude window), including its windows'.
    func sessions(rootedAt rootID: UUID) -> [WorkspaceTerminalSession] {
        layout.sessionIDs(rootedAt: rootID).compactMap { sessionsByID[$0] }
    }

    func group(_ id: UUID) -> WorkspaceTerminalLayout.Group? { layout.group(id) }

    func groupID(of session: WorkspaceTerminalSession) -> UUID? { layout.groupID(containing: session.id) }

    func windows(rootedAt rootID: UUID) -> [WorkspaceTerminalLayout.Group] { layout.windows(rootedAt: rootID) }

    func focusedID(in groupID: UUID) -> UUID? { layout.group(groupID)?.focusedID }

    /// The session "Reference in Claude" and other typed input go to: the focused one, else the first.
    func targetSession(for groupID: UUID) -> WorkspaceTerminalSession? {
        let list = sessions(for: groupID)
        return list.first { $0.id == focusedID(in: groupID) } ?? list.first
    }

    /// Whether a root has started its first session this launch.
    func hasStarted(_ rootID: UUID) -> Bool { autoStarted.contains(rootID) }

    /// Whether another tab of this kind fits: Claude sessions and plain terminals have
    /// separate limits per project (windows included).
    func canAddSession(in groupID: UUID, kind: WorkspaceTerminalSession.Kind = .claude(model: "opus")) -> Bool {
        guard let group = layout.group(groupID) else { return false }
        return Self.hasRoom(for: kind, among: sessions(rootedAt: group.rootID).map(\.kind))
    }

    /// Pure limit check, unit tested.
    static func hasRoom(for kind: WorkspaceTerminalSession.Kind, among kinds: [WorkspaceTerminalSession.Kind]) -> Bool {
        let same = kinds.filter { $0.isTerminal == kind.isTerminal }.count
        return same < (kind.isTerminal ? maxTerminals : maxSessions)
    }

    /// The lowest number not in use (numbers are counted per kind, so a closed "Claude 2" is
    /// reused before "Claude 4" and terminals start at "Terminal 1").
    static func nextNumber(used: Set<Int>) -> Int {
        (1...).first { !used.contains($0) } ?? used.count + 1
    }

    // MARK: - Sessions

    /// Creates a root strip and, the first time this launch, its first (Opus) session. Call outside `body`.
    func ensureSession(in rootID: UUID, projectID: UUID, launch: Launcher) {
        layout.ensureRoot(rootID, projectID: projectID)
        guard !autoStarted.contains(rootID) else { return }
        autoStarted.insert(rootID)
        if sessions(rootedAt: rootID).isEmpty { addSession(in: rootID, kind: .claude(model: "opus"), launch: launch) }
    }

    /// Starts another tab at the end of a strip: a Claude session (up to `maxSessions` per
    /// project) or a plain terminal (up to `maxTerminals`). It shows in the focused pane, or,
    /// with `splitting`, in a new pane at that edge of the given pane (nil when that does not
    /// fit `size`).
    @discardableResult
    func addSession(
        in groupID: UUID, kind: WorkspaceTerminalSession.Kind, launch: Launcher,
        splitting split: (pane: UUID, zone: WorkspaceTerminalSplit.DropZone)? = nil, size: CGSize? = nil
    ) -> WorkspaceTerminalSession? {
        guard let group = layout.group(groupID), canAddSession(in: groupID, kind: kind) else { return nil }
        if let split, !canSplit(split.pane, split.zone, in: groupID, size: size) { return nil }
        let used = Set(sessions(rootedAt: group.rootID).filter { $0.isTerminal == kind.isTerminal }.map(\.number))
        let session = WorkspaceTerminalSession(
            number: Self.nextNumber(used: used), kind: kind, projectID: group.projectID, view: makeView())
        attachDelegate(to: session)
        start(session, launch: launch(kind))
        sessionsByID[session.id] = session
        if let split {
            layout.append(session.id, to: groupID, splitting: split.pane, split.zone, size: size)
        } else {
            layout.append(session.id, to: groupID)
        }
        return session
    }

    /// Ends the session's process and removes its tab. A window left without tabs disappears.
    func close(_ sessionID: UUID) {
        guard let session = sessionsByID.removeValue(forKey: sessionID) else { return }
        session.view.terminate()
        session.view.removeFromSuperview()
        try? FileManager.default.removeItem(at: session.statusFile)
        layout.remove(sessionID)
        focusedAt[sessionID] = nil
    }

    /// Ends whatever runs in the session and starts it again (Claude, or a fresh shell) in a
    /// fresh terminal.
    func restart(_ session: WorkspaceTerminalSession, launch: Launcher) {
        session.view.terminate()
        session.view.removeFromSuperview()
        session.view = makeView()
        session.title = ""
        try? FileManager.default.removeItem(at: session.statusFile)
        session.tracker.reset()
        session.hookFileDate = nil
        session.hookDate = nil
        session.hookStatus = nil
        session.latestPayload = nil
        session.requestPayload = nil
        session.status = .idle
        session.program = nil
        attachDelegate(to: session)
        start(session, launch: launch(session.kind))
        setFocused(session.id)
    }

    /// Names the tab; an empty name brings back the automatic one.
    func rename(_ session: WorkspaceTerminalSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customName = trimmed.isEmpty ? nil : trimmed
    }

    func setFocused(_ sessionID: UUID) {
        layout.setFocused(sessionID)
        focusedAt[sessionID] = Date()
    }

    /// When the session was last focused this launch; nil: never.
    func lastFocused(_ sessionID: UUID) -> Date? { focusedAt[sessionID] }

    /// Types text into a session's terminal, e.g. an @path reference for Claude, and brings it forward.
    func send(_ text: String, to session: WorkspaceTerminalSession) {
        session.view.send(txt: text)
        session.view.window?.makeKeyAndOrderFront(nil)
        session.view.window?.makeFirstResponder(session.view)
        setFocused(session.id)
    }

    // MARK: - Windows

    /// Moves sessions of a strip into a new window strip and returns its ID; the caller opens
    /// the window ("workspace-claude", value: the ID). `frame` places it (screen coordinates).
    func tearOff(_ sessionIDs: [UUID], from groupID: UUID, frame: NSRect? = nil) -> UUID? {
        let windowID = UUID()
        if let frame { pendingWindowFrames[windowID] = frame }
        guard layout.tearOff(sessionIDs, from: groupID, windowID: windowID) != nil else {
            pendingWindowFrames[windowID] = nil
            return nil
        }
        return windowID
    }

    func move(_ sessionID: UUID, to groupID: UUID) {
        layout.move(sessionID, to: groupID)
    }

    // MARK: - Panes

    /// Shows a tab in a pane (centre) or splits the pane with it (an edge), moving it from
    /// another strip if needed. `size` is the strip's content area; nil takes the one on screen.
    @discardableResult
    func place(
        _ sessionID: UUID, in groupID: UUID, pane paneID: UUID, zone: WorkspaceTerminalSplit.DropZone,
        size: CGSize? = nil
    ) -> Bool {
        layout.place(sessionID, in: groupID, pane: paneID, zone: zone, size: size ?? contentSize(of: groupID))
    }

    /// Whether `place` would do something.
    func canPlace(
        _ sessionID: UUID, in groupID: UUID, pane paneID: UUID, zone: WorkspaceTerminalSplit.DropZone,
        size: CGSize? = nil
    ) -> Bool {
        var trial = layout
        return trial.place(sessionID, in: groupID, pane: paneID, zone: zone, size: size ?? contentSize(of: groupID))
    }

    /// Whether a new tab fits in a new pane at that edge of the pane.
    func canSplit(
        _ paneID: UUID, _ zone: WorkspaceTerminalSplit.DropZone, in groupID: UUID, size: CGSize? = nil
    ) -> Bool {
        var trial = layout
        return trial.append(UUID(), to: groupID, splitting: paneID, zone, size: size ?? contentSize(of: groupID))
    }

    /// Hides a pane; its session keeps running as a tab.
    func closePane(_ paneID: UUID, in groupID: UUID) {
        layout.closePane(paneID, in: groupID)
    }

    func setSplitFraction(_ splitID: UUID, to fraction: Double, in groupID: UUID) {
        layout.setSplitFraction(splitID, to: fraction, in: groupID)
    }

    /// The strip's pane area on screen, if shown.
    private func contentSize(of groupID: UUID) -> CGSize? {
        guard let view = contentZones[groupID]?.view, view.window != nil else { return nil }
        return view.bounds.size
    }

    /// The window was closed: its tabs return to the strip they came from (or the nearest one open).
    func windowClosed(_ groupID: UUID) {
        layout.closeWindow(groupID)
        dropZones[groupID] = nil
        contentZones[groupID] = nil
    }

    /// "Move to Workspace": the window's tabs go straight to its workspace (or Claude window).
    func moveToRoot(_ groupID: UUID) {
        layout.moveToRoot(groupID)
    }

    /// Every window of the root closes and its tabs return to the root's strip.
    func bringBack(rootID: UUID) {
        layout.bringBack(rootID: rootID)
    }

    // MARK: - Drop zones

    /// A pane registers the view covering its strip and terminals, so a dragged tab can land on it.
    func registerDropZone(_ view: NSView, for groupID: UUID) {
        dropZones[groupID] = WeakView(view: view)
    }

    /// A pane registers the (flipped) view covering its split panes, for drop zones inside them.
    func registerContentZone(_ view: NSView, for groupID: UUID) {
        contentZones[groupID] = WeakView(view: view)
    }

    /// The pane's view on screen for a strip, if it is shown.
    func dropZoneView(for groupID: UUID) -> NSView? {
        guard let view = dropZones[groupID]?.view, view.window?.isVisible == true else { return nil }
        return view
    }

    /// A window frame (screen coordinates) whose content covers a strip where it is shown now,
    /// kept on its screen; nil when the strip is not on screen. Popping all tabs out opens the
    /// window right there, so its panes keep the room they had.
    func windowFrame(over groupID: UUID) -> NSRect? {
        guard let view = dropZoneView(for: groupID), let window = view.window else { return nil }
        let content = window.convertToScreen(view.convert(view.bounds, to: nil))
        let frame = NSWindow.frameRect(forContentRect: content, styleMask: [.titled, .closable, .miniaturizable, .resizable])
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return frame }
        return TerminalTabDragController.clamp(frame, to: visible)
    }

    /// Where a dragged tab would land: a pane zone of a strip of the same project (its own strip
    /// included), another strip's tab strip, or its own strip where it cannot go; nil outside
    /// every strip (a new window). Only the frontmost window under the pointer counts (`below`
    /// skips the drag ghost).
    func dropTarget(
        at point: NSPoint, session sessionID: UUID, projectID: UUID, source sourceID: UUID, below ghost: Int
    ) -> DropTarget? {
        let windowNumber = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: ghost)
        for (id, zone) in dropZones {
            guard let view = zone.view, let window = view.window, window.isVisible,
                  window.windowNumber == windowNumber,
                  layout.group(id)?.projectID == projectID
            else { continue }
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            guard frame.contains(point) else { continue }
            if let target = paneTarget(at: point, groupID: id, sessionID: sessionID) { return target }
            return id == sourceID ? .ownStrip : .strip(id)
        }
        return nil
    }

    /// The zone of the pane under the pointer, if dropping there does something. An edge that
    /// would make a pane too small falls back to the centre.
    private func paneTarget(at point: NSPoint, groupID: UUID, sessionID: UUID) -> DropTarget? {
        guard let content = contentZones[groupID]?.view, let window = content.window,
              let group = layout.group(groupID)
        else { return nil }
        let local = content.convert(window.convertPoint(fromScreen: point), from: nil)
        let size = content.bounds.size
        guard content.bounds.contains(local), let pane = group.split.pane(at: local, in: size) else { return nil }
        let zone = WorkspaceTerminalSplit.zone(at: local, in: pane.frame)
        for candidate in zone == .center ? [zone] : [zone, .center]
        where canPlace(sessionID, in: groupID, pane: pane.id, zone: candidate, size: size) {
            return .pane(groupID: groupID, paneID: pane.id, zone: candidate)
        }
        return nil
    }

    // MARK: - Status

    /// Foreground process, hook status and activity of every session; runs once a second.
    private func refresh() {
        let now = Date()
        for session in sessionsByID.values {
            let foreground = foregroundProcess(of: session)
            if session.foreground != foreground {
                // Claude started by hand in a plain terminal starts from a clean slate: the
                // shell's earlier output says nothing about Claude.
                if session.isTerminal, foreground == .claude { session.tracker.reset(at: now) }
                session.foreground = foreground
            }
            if session.isTerminal {
                let program = foreground == .shell ? frontProgram(of: session) : nil
                if session.program != program { session.program = program }
            }
            readHookFile(of: session)
            let bell = session.view.bellRung
            session.view.bellRung = false
            var sample = TerminalStatusTracker.Sample(
                lastOutput: session.view.lastOutput, lastInput: session.view.lastInput, bell: bell, now: now)
            if let date = session.hookDate { sample.hook = (session.hookStatus, date) }
            if let escape = session.view.lastEscape, session.status == .waiting, escape > (session.hookDate ?? .distantPast) {
                // Esc answers a prompt with "no": Claude stops and waits for a new prompt.
                session.hookDate = escape
                session.hookStatus = .idle
                sample.hook = (.idle, escape)
            }
            var status = session.tracker.update(sample)
            // With the plain shell in front only an error (Claude exited non-zero) is worth showing.
            if foreground != .claude, status != .error { status = .idle }
            if session.status != status {
                if status == .waiting, !isFocused(session) {
                    AccessibilityNotification.Announcement("\(session.displayName) is waiting for you").post()
                }
                session.status = status
            }
        }
    }

    private func isFocused(_ session: WorkspaceTerminalSession) -> Bool {
        guard let groupID = layout.groupID(containing: session.id) else { return false }
        return focusedID(in: groupID) == session.id && session.view.window?.isKeyWindow == true
    }

    private func readHookFile(of session: WorkspaceTerminalSession) {
        let url = session.statusFile
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified != session.hookFileDate,
              let data = try? Data(contentsOf: url)
        else { return }
        session.hookFileDate = modified
        session.hookDate = modified
        session.hookStatus = TerminalSessionStatus.fromHookPayload(data)
        session.latestPayload = data
        if ClaudeSessionRequest.isRequestPayload(data) {
            session.requestPayload = data
        } else if ClaudeSessionRequest.endsRequest(data) {
            session.requestPayload = nil
        }
    }

    /// Answers the session's request with Claude Code's keys, with a short pause between
    /// steps so a prompt has closed before the next input arrives (ClaudeSessionRequest).
    /// Returns false, and types nothing, when the session no longer asks `expected` (answered
    /// in the terminal meanwhile, or a new prompt replaced it): keys meant for the card's
    /// request must never answer another one.
    @discardableResult
    func answer(_ answer: ClaudeSessionRequest.Answer, to sessionID: UUID, expected: ClaudeSessionRequest) -> Bool {
        guard let session = sessionsByID[sessionID], !session.isTerminal else { return false }
        readHookFile(of: session)
        guard session.request == expected else { return false }
        let steps = ClaudeSessionRequest.keys(for: answer)
        // Answered: the card's request is gone until the next hook event says otherwise.
        session.requestPayload = nil
        Task { @MainActor [weak self] in
            for (index, step) in steps.enumerated() {
                if index > 0 { try? await Task.sleep(for: .milliseconds(450)) }
                // Typed in place: the user stays in the app they are in.
                guard let self, let live = self.sessionsByID[sessionID] else { return }
                live.view.send(txt: step)
            }
        }
        return true
    }

    /// What is in front in the session's terminal right now. The launch shell runs Claude
    /// without job control (zsh -c), so the pty's process group is the shell's own; instead we
    /// look for a Claude process among the shell's children (and the foreground group, for a
    /// Claude started by hand from the interactive shell).
    private func foregroundProcess(of session: WorkspaceTerminalSession) -> Foreground {
        guard let process = session.view.process, process.running, process.shellPid > 0 else { return .none }
        var candidates = Self.childPIDs(of: process.shellPid)
        if process.childfd >= 0 {
            let group = tcgetpgrp(process.childfd)
            if group > 0 { candidates.append(group) }
        }
        let isClaude = candidates.contains { Self.isClaudeProcess($0, strict: session.isTerminal) }
        return isClaude ? .claude : .shell
    }

    /// Claude Code's process: the native binary (path ends in .../claude) or, for npm installs,
    /// node. Under our Claude launch shell any node is Claude; in a plain terminal (`strict`)
    /// node only counts when it runs Claude Code's script, so a dev server is not taken for it.
    private static func isClaudeProcess(_ pid: pid_t, strict: Bool) -> Bool {
        let name = processName(pid)
        if name.contains("claude") { return true }
        guard name.hasSuffix("/node") else { return false }
        return !strict || arguments(of: pid).dropFirst().contains { $0.lowercased().contains("claude") }
    }

    /// Plain terminals: the program in the pty's foreground group when it is not the shell
    /// itself ("vim", "npm"); nil while the shell waits for a command.
    private func frontProgram(of session: WorkspaceTerminalSession) -> String? {
        guard let process = session.view.process, process.running, process.childfd >= 0 else { return nil }
        let group = tcgetpgrp(process.childfd)
        guard group > 0, group != process.shellPid else { return nil }
        let name = (Self.processPath(group) as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    /// Executable path, lowercased. Not proc_name: the native Claude Code binary names its
    /// process after its version ("2.1.285"), while the path still ends in .../claude.
    private static func processName(_ pid: pid_t) -> String {
        processPath(pid).lowercased()
    }

    private static func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    /// A process's argv (KERN_PROCARGS2: argc, the executable path, NUL padding, then the
    /// arguments; the environment that follows is not read).
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        let header = MemoryLayout<Int32>.size
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > header else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > header else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = header
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    // MARK: - Terminal views

    private func makeView() -> WorkspaceTerminalView {
        let view = WorkspaceTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.caretColor = .controlAccentColor
        view.optionAsMetaKey = true
        applyPalette(view)
        return view
    }

    private func attachDelegate(to session: WorkspaceTerminalSession) {
        let delegate = TerminalDelegate(session: session, store: self)
        session.delegate = delegate
        session.view.processDelegate = delegate
    }

    private func start(_ session: WorkspaceTerminalSession, launch: AppViewModel.ClaudeLaunch) {
        session.view.startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: launch.environment + ["MM_TERMINAL_STATUS=\(session.statusFile.path)"],
            execName: (launch.executable as NSString).lastPathComponent,
            currentDirectory: launch.repo.path)
    }

    /// Background follows the theme; text and the ANSI colours are made readable on it
    /// (`TerminalPalette`), the caret takes the accent.
    private func applyPalette(_ view: LocalProcessTerminalView) {
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = ThemeStore.shared.theme
        let background = theme.background.resolved(dark: isDark)
        view.nativeBackgroundColor = ThemeColor.srgb(background)
        let text = TerminalPalette.readable(theme.textPrimary.resolved(dark: isDark), on: background)
        view.nativeForegroundColor = ThemeColor.srgb(text)
        view.caretColor = ThemeColor.srgb(theme.accent.resolved(dark: isDark))
        view.installColors(TerminalPalette.ansi(on: background).map { hex in
            SwiftTerm.Color(red8: UInt16((hex >> 16) & 0xFF), green8: UInt16((hex >> 8) & 0xFF), blue8: UInt16(hex & 0xFF))
        })
    }
}

private struct WeakView {
    weak var view: NSView?
}

/// The terminal view, recording when output last arrived, when the user last typed, and
/// whether the bell rang.
final class WorkspaceTerminalView: LocalProcessTerminalView {
    fileprivate(set) var lastOutput: Date?
    fileprivate(set) var lastInput: Date?
    /// The last lone Esc key (not the start of an arrow-key sequence).
    fileprivate(set) var lastEscape: Date?
    fileprivate var bellRung = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        lastOutput = Date()
        super.dataReceived(slice: slice)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let now = Date()
        lastInput = now
        if data.count == 1, data.first == 0x1B { lastEscape = now }
        super.send(source: source, data: data)
    }

    /// Claude rings the bell when it waits for the user: flag it instead of beeping.
    override func bell(source: Terminal) {
        bellRung = true
    }
}

private final class TerminalDelegate: LocalProcessTerminalViewDelegate {
    weak var session: WorkspaceTerminalSession?
    weak var store: WorkspaceTerminalStore?

    init(session: WorkspaceTerminalSession, store: WorkspaceTerminalStore) {
        self.session = session
        self.store = store
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// A plain terminal whose shell exited cleanly (`exit`, Ctrl+D) closes its tab, as in
    /// Terminal.app; after a failure it stays so the output can be read. Claude tabs never get
    /// here in normal use (their launch shell ends in `exec zsh -l`).
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let sourceID = ObjectIdentifier(source)
        Task { @MainActor [weak session, weak store] in
            guard let session, let store, session.isTerminal, exitCode == 0,
                  ObjectIdentifier(session.view) == sourceID
            else { return }
            store.close(session.id)
        }
    }

    /// Claude Code titles its terminal after the conversation; that names the pane.
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = ObjectIdentifier(source)
        Task { @MainActor [weak session] in
            guard let session, ObjectIdentifier(session.view) == sourceID else { return }
            session.title = trimmed
        }
    }
}
