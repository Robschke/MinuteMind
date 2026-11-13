// Purpose: CompanionController, the desktop companion: the little pixel creature that floats over
//          every app, can be dragged anywhere, mirrors recordings, dictation, meeting questions and
//          every Claude session, and carries the meeting pill's popups beside it.
// Dependencies: Sources/App/Supporting/AssistantMascotPose.swift (moods and frames),
//               Sources/App/Supporting/CompanionCast.swift (project creatures, who is in front),
//               Sources/App/Supporting/CompanionAppearance.swift (size and colour),
//               Sources/App/Supporting/CompanionPlacement.swift (geometry),
//               Sources/App/Views/CompanionView.swift (drawing),
//               Sources/App/Supporting/MeetingPillController.swift (its states and popups),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (Claude sessions and status),
//               Sources/App/ViewModels/AppViewModel+Companion.swift (open, reveal, find windows)
// Used by: Sources/App/ViewModels/AppViewModel.swift (owns and starts it),
//          Sources/App/MinuteMindApp.swift (Window menu: Show / Hide Companion)
// Notes: User request 2026-10-13: the creature leaves the main page and becomes a companion on the
//        desktop that replaces the meeting pill completely. User decisions: it reports Claude
//        sessions of every project; a double click brings every window with a running Claude
//        session to it, fanned out beside it. Design decisions (with two design reviews):
//        - Two non-activating panels at screen-saver level + 1 (above the pill's popups, whose
//          shadow margin overlaps the creature): the creature's own 36 x 48 pt panel takes the
//          mouse, with a tracking area for instant hover; bubble and badges sit in a larger panel
//          that ignores the mouse, so no margin ever catches a click meant for the app below.
//          Both are hidden from screen capture and, like the pill, hidden during a screen share
//          (the pill then falls back to its bottom-centre place and the menu bar item). With
//          "Show the companion in screen shares" (off by default) the creature's panel can be
//          captured and stays during a share; its bubble and badges are faded out and the
//          pill's cards keep their share fallback, so nothing private reaches the viewers.
//        - Drag moves it (3 pt before a press counts as a drag), a drop near an edge snaps to it;
//          the position is stored per display, relative to its visible frame.
//        - Click opens the card beside it at once and keeps it 6 s after the pointer leaves (a
//          click is harmless, so nothing waits for a double click). Double click brings the Claude
//          windows; a second double click while they still sit there puts them back. Right click
//          (or Ctrl click): Record or Stop, sessions that need the user, Claude, Bring Claude
//          Windows Here, Open MinuteMind, Notify When Claude Finishes, Reset Position, Hide
//          Companion (the Window menu brings it back). A one-time card explains the gestures.
//        - Claude statuses are read once a second whether or not the creature shows, so nothing
//          bursts out when it reappears. Notices: waiting after 2 s of waiting (permission prompts
//          flicker), errors at once, done only after a turn that worked 30 s or more and only when
//          switched on; never for the session the user is looking at; waiting and errors are not
//          replaced by a done notice.
//        - Docked by default (user request 2026-10-13): it sits in the main window's bottom right
//          corner as child windows of it, at the window's level, so it moves, minimises and hides
//          with the app and other apps' windows cover it. Dragged out it floats free over every
//          app as before; dropped near that corner it docks again (also "Dock to MinuteMind
//          Window" in the menu). A shake takes it out for a while, Go Back returns it to the
//          window. While docked and the window is gone, the pill falls back to its old place.
//        - Size and colour follow CompanionAppearance (Settings, Appearance); a new size resizes
//          both panels around the creature's feet.
//        - Shaking the mouse (MouseShakeDetector, fed by global and local mouse-moved monitors,
//          which need no Accessibility permission and run only while the creature shows and the
//          switch in Settings, Appearance is on) brings it to the pointer (user request
//          2026-10-13). It runs there: a quick dash at about 2800 pt/s with a short ease-out, 0.18
//          to 0.45 s, feet, arms and bob drawn at the 60 Hz travel rate (AssistantMascotPose's
//          running pose), a hop only on landing (user request 2026-10-13: "run cutely to the
//          pointer, fairly fast"). To another display, or with Reduce Motion, it fades out and
//          in instead of sliding through space no screen shows. The dragged position stays its
//          home: the shake spot is not saved, and Go Back in the menu returns it. A click or a
//          drag during the trip stops it.
//        - Scrolling over it while a recording runs, or while the saved card asks for the
//          project (mouse wheel or two-finger swipe), opens the project list (ProjectWheel)
//          beside it and turns it; resting 1.2 s (after the fingers
//          lift) files the recording to the entry shown, a click on a row files it at once, and
//          leaving creature and card or clicking the creature first backs out (user request
//          2026-10-27, refined by a design review).
//        - Projects with their own avatar (sidebar right click, Companion) get a small creature
//          (sidekick) beside it while they run a Claude session, huddled behind it on the side
//          toward the nearer screen edge (docked: inside the window, on the left; geometry and
//          glances in CompanionCrowd); when even a squeezed huddle does not fit, the creature's
//          panels stand `crowdShiftX` from its home `origin`, which drags, saves and docking
//          keep using. Each shows its sessions in its pose only (no light, no bubble): typing
//          on its laptop while one works, waving until answered while one waits, a thumb up for
//          `celebrationDuration` when a turn finishes, the error face. A project that starts
//          waiting or errs comes to the front: it is drawn big in the companion's place, with the
//          companion as a sidekick; a click on a sidekick brings it forward; CompanionCast
//          decides when the home companion takes the front back. The crowd has its own panel that
//          takes the mouse (hover shows a name card in a click-through panel); cards open beside
//          the whole group (`castFrame`), never over the crowd. Every change of the front goes
//          through `changeFront`, which plays the swap scene (CompanionSwapView) in its own
//          click-through panel while the creature, its overlay and the crowd are invisible. Every panel moves, docks, hides
//          and fades with the creature (`allPanels`); an empty crowd is made invisible and
//          click-through, never ordered out (a child window ordered out leaves its parent).
//        - Frame rate: 8 fps while something moves near it (hover, drag, hop, pointer within
//          400 pt that moved in the last 4 s, dictation, the first seconds of a mood), 4 fps while
//          a session works or waits, 2 fps idle, 1 fps asleep; Reduce Motion gives still poses.

import AppKit
import Observation
import SwiftUI

/// What the creature's views draw.
@Observable
@MainActor
final class CompanionModel {
    struct Actions {
        var showOptions: () -> Void = {}
        var openClaude: () -> Void = {}
        var summon: () -> Void = {}
    }

    var frame = MascotFrame(grid: .body)
    var mood: MascotMood = .idle
    /// The bubble goes to the left of the creature (it sits in the right half of the screen).
    var opensLeft = true
    /// False while a popup shows beside the creature; the popup says more than the bubble.
    var showsBubble = true
    var isRecording = false
    /// A detected meeting runs unrecorded.
    var meetingRunning = false
    var isHiddenByUser = UserDefaults.standard.bool(forKey: CompanionController.hiddenKey)
    /// The project creature in front (CompanionCast); nil: the home companion.
    var frontAvatar: MascotAvatar?
    var frontColor: Color?
    var frontName: String?
    /// The small creatures beside it, nearest first.
    var sidekicks: [CompanionSidekick] = []
    /// The sidekick under the pointer (its id).
    var hoveredSidekick: String?
    @ObservationIgnored var actions = Actions()

    /// Each sidekick's canvas inside the crowd panel (origin bottom left), in `sidekicks`' order.
    var crowdSlots: [CGRect] = []

    var spokenState: String {
        if isRecording { return "\(mood.spokenDescription), recording" }
        if meetingRunning { return "\(mood.spokenDescription), meeting not recorded" }
        return mood.spokenDescription
    }
}

/// One small creature beside the companion, as drawn.
struct CompanionSidekick: Identifiable, Equatable {
    let id: String
    /// nil: the home companion.
    let projectID: UUID?
    let name: String
    let avatar: MascotAvatar
    let color: Color?
    let status: TerminalSessionStatus?
    var frame: MascotFrame

    var spokenStatus: String {
        switch status {
        case .working: "working"
        case .waiting: "needs you"
        case .done: "done"
        case .error: "error"
        case .idle, nil: "idle"
        }
    }
}

@MainActor
final class CompanionController {
    static let hiddenKey = "mm.companionHidden"
    static let positionKey = "mm.companionPosition"
    static let doneNoticesKey = "mm.companionDoneNotices"
    static let coachSeenKey = "mm.companionCoachSeen"
    static let dockedKey = "mm.companionDocked"
    /// Free: above every app, one above the pill's popups (whose shadow reaches over the creature).
    private static let freeLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    private static let freeBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    let model = CompanionModel()

    private weak var viewModel: AppViewModel?
    private weak var pill: MeetingPillController?
    private var creaturePanel: NSPanel?
    private var overlayPanel: NSPanel?
    /// The projects' small creatures (takes the mouse) and the name card over a hovered one
    /// (ignores it).
    private var sidekickPanel: NSPanel?
    private var nameplatePanel: NSPanel?
    private var nameplateHost: NSHostingView<AnyView>?
    /// Draws the creatures changing places (CompanionSwapView) while the real ones are hidden.
    private var swapPanel: NSPanel?
    private var swapHost: NSHostingView<AnyView>?
    private var swapEnd: Task<Void, Never>?
    private var isSwapping = false
    private static let swapDuration: TimeInterval = 0.45
    /// The sidekick row while the swap scene stands in for it: invisible, still taking clicks.
    private static let clickableAlpha: CGFloat = 0.01
    /// Who is in front, and the cast as of the last status tick.
    private var front = CompanionFront()
    /// The sidekick clicked last and when (nil: the home companion), for a double click.
    private var lastSidekickClick: (projectID: UUID?, at: Date)?
    private var castProjects: [CompanionCastMember] = []
    private var castHome: CompanionCastMember?
    /// The overlay panel's origin at home; the creature panel sits `sideMargin` to its right.
    /// The panels stand `crowdShiftX` from it while the crowd needs room at a screen edge.
    private var origin: CGPoint = .zero
    /// How far the panels stand from `origin` sideways (CompanionCrowd's step-in, signed).
    private var crowdShiftX: CGFloat = 0
    /// The crowd stands to the creature's right (else its left).
    private var crowdOutwardRight = false
    private var started = false
    private var isScreenSharing = false
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var statusTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?

    private var lastMouse: CGPoint?
    private var lastMouseMove = Date.distantPast
    private var isHovering = false
    private var drag: (start: CGPoint, origin: CGPoint, moved: Bool)?
    private var hopStart: Date?
    private var moodSince = Date()
    private var celebrateUntil: Date?
    private let menuActions = CompanionMenuActions()

    // Claude session tracking (statusTick).
    private var lastStatuses: [UUID: TerminalSessionStatus]?
    private var workingSince: [UUID: Date] = [:]
    /// When each session's last turn finished, for the sidekicks' thumb up.
    private var finishedAt: [UUID: Date] = [:]
    /// A sidekick types or waves, so frames must come often enough to show it.
    private var sidekicksMove = false
    private var waitingSince: [UUID: Date] = [:]
    private var notifiedWaiting: Set<UUID> = []
    // Coming to the pointer when the mouse is shaken.
    private var shakeDetector = MouseShakeDetector()
    private var mouseMonitors: [Any] = []
    private var travel: (from: CGPoint, to: CGPoint, start: Date, duration: TimeInterval)?
    private var travelTimer: Timer?
    /// A shake moved it away from its home (the window corner or the spot it was dragged to).
    private var isAway = false
    /// Lives in the main window's corner instead of floating free.
    private var isDocked = UserDefaults.standard.object(forKey: CompanionController.dockedKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isDocked, forKey: Self.dockedKey) }
    }
    /// The window the panels are attached to as child windows while docked.
    private weak var dockWindow: NSWindow?
    private var dockObservers: [NSObjectProtocol] = []

    /// The project list scrolled over the creature during a recording, and the recording it is for.
    private var wheel: (state: ProjectWheel, sessionID: UUID)?
    private var wheelTask: Task<Void, Never>?
    /// The scrolling rests this long before the shown project is taken.
    private static let wheelCommitDelay: TimeInterval = 1.2
    /// The confirmation stays this long after it was taken.
    private static let wheelConfirmDuration: TimeInterval = 1.4

    /// Windows moved by the last summon: where they were and where they went.
    private var summoned: [(window: NSWindow, from: NSRect, to: NSRect)] = []

    /// Eyes follow the pointer this long after it last moved.
    private static let followDuration: TimeInterval = 3
    /// Without any input for this long the creature falls asleep.
    private static let sleepAfter: TimeInterval = 300
    private static let celebrationDuration: TimeInterval = 8
    private static let waitingDebounce: TimeInterval = 2
    private static let doneMinimumWork: TimeInterval = 30

    static var doneNoticesEnabled: Bool {
        UserDefaults.standard.object(forKey: doneNoticesKey) as? Bool ?? true
    }

    // MARK: - Lifecycle

    func start(viewModel: AppViewModel, pill: MeetingPillController) {
        self.viewModel = viewModel
        self.pill = pill
        // During a share the cards never open beside the creature: they keep the share fallback.
        pill.companionAnchor = { [weak self] in self?.isScreenSharing == true ? nil : self?.castFrame }
        pill.onPanelVisibilityChanged = { [weak self] in self?.updateBubbleVisibility() }
        pill.onProjectWheelPick = { [weak self] index in self?.pickFromWheel(index) }
        pill.onOpenProjectWheel = { [weak self] sessionID in self?.openWheel(for: sessionID) }
        pill.onScrollOverPanel = { [weak self] event in self?.scrolledOverCard(event) ?? false }
        pill.onWheelEscape = { [weak self] in self?.escapeWheel() }
        pill.onAnswerSession = { [weak self] row, answer in
            guard let self, let expected = row.request, let viewModel = self.viewModel else { return false }
            if viewModel.workspaceTerminals.answer(answer, to: row.id, expected: expected) { return true }
            // The card was out of date: show what the session asks now.
            DispatchQueue.main.async { [weak self] in
                guard let self, let session = viewModel.workspaceTerminals.claudeSessions.first(where: { $0.id == row.id }),
                      session.request != nil else { return }
                self.pill?.showNotice(self.row(for: session, kind: row.kind), force: true)
            }
            return false
        }
        model.actions = .init(
            showOptions: { [weak self] in self?.pill?.companionClick() },
            openClaude: { [weak self] in self?.viewModel?.openClaudeAssistant() },
            summon: { [weak self] in self?.summonOrRestore() })
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restorePosition() }
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .companionAppearanceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearanceChanged() }
        }
        let statusTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusTick() }
        }
        statusTimer.tolerance = 0.2
        RunLoop.main.add(statusTimer, forMode: .common)
        self.statusTimer = statusTimer
        started = true
        applyVisibility()
    }

    /// The creature's canvas on screen while it shows.
    var creatureFrame: NSRect? {
        guard let creaturePanel, creaturePanel.isVisible else { return nil }
        return creaturePanel.frame
    }

    /// The creature and its sidekicks: cards open beside the whole group, never over the row.
    private var castFrame: NSRect? {
        guard let creature = creatureFrame else { return nil }
        guard !model.sidekicks.isEmpty, let row = sidekickPanel?.frame, row.width > 0 else { return creature }
        return creature.union(row)
    }

    /// Every panel, back to front: the creature stays on top, the crowd stands behind its
    /// bubble and badges.
    private var allPanels: [NSPanel] {
        [sidekickPanel, overlayPanel, nameplatePanel, creaturePanel, swapPanel].compactMap { $0 }
    }

    private func orderAllFront() {
        allPanels.forEach { $0.orderFrontRegardless() }
    }

    func setHidden(_ hidden: Bool) {
        model.isHiddenByUser = hidden
        UserDefaults.standard.set(hidden, forKey: Self.hiddenKey)
        applyVisibility()
    }

    func screenSharingChanged(_ sharing: Bool) {
        isScreenSharing = sharing
        applyVisibility()
    }

    /// Hidden because the screen is shared and the user keeps it out of shares (the default).
    private var hiddenForShare: Bool {
        isScreenSharing && !CompanionAppearance.shared.visibleInScreenShares
    }

    /// Who may capture the creature, and whether its bubble and badges show: viewers of a share
    /// see at most the creature itself.
    private func applySharing() {
        let sharing: NSWindow.SharingType = CompanionAppearance.shared.visibleInScreenShares ? .readOnly : .none
        creaturePanel?.sharingType = sharing
        sidekickPanel?.sharingType = sharing
        overlayPanel?.alphaValue = isScreenSharing ? 0 : 1
        nameplatePanel?.alphaValue = isScreenSharing ? 0 : 1
    }

    /// Docked and at home: rides in the main window's corner.
    private var ridesInWindow: Bool { isDocked && !isAway }

    /// The main window while it is on screen (not closed, not minimised).
    private var visibleMainWindow: NSWindow? {
        guard let window = viewModel?.mainWindow, window.isVisible, !window.isMiniaturized else { return nil }
        return window
    }

    private func applyVisibility() {
        var visible = started && !model.isHiddenByUser && !hiddenForShare
        // Docked without a window to ride in: gone with the app until the window is back.
        if visible, ridesInWindow, visibleMainWindow == nil { visible = false }
        if visible {
            if creaturePanel == nil {
                makePanels()
                restorePosition()
            }
            applySharing()
            if ridesInWindow, let window = visibleMainWindow {
                attach(to: window)
            } else {
                detach()
                orderAllFront()
            }
            layoutCast()
            updateMouseMonitors()
            tick()
            pill?.companionChanged()
            if !UserDefaults.standard.bool(forKey: Self.coachSeenKey) {
                pill?.showCoach { UserDefaults.standard.set(true, forKey: Self.coachSeenKey) }
            }
        } else {
            cancelTravel()
            detach()
            allPanels.forEach { $0.orderOut(nil) }
            updateMouseMonitors()
            timer?.invalidate()
            timer = nil
            timerInterval = 0
            if isHovering {
                isHovering = false
                pill?.companionHover(false)
            }
            pill?.companionChanged()
        }
    }

    private func makePanels() {
        let overlay = Self.makePanel(size: CompanionPlacement.panelSize)
        overlay.ignoresMouseEvents = true
        overlay.contentView = NSHostingView(rootView: CompanionOverlayView(model: model))
        overlayPanel = overlay

        let creature = Self.makePanel(size: CompanionPlacement.creatureSize)
        let container = NSView(frame: NSRect(origin: .zero, size: CompanionPlacement.creatureSize))
        let hosting = NSHostingView(rootView: CompanionCreatureView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        // On top of the drawing: takes every click, drag and right click for the controller.
        let mouse = CompanionMouseView(frame: container.bounds)
        mouse.autoresizingMask = [.width, .height]
        mouse.controller = self
        container.addSubview(mouse)
        creature.contentView = container
        creaturePanel = creature

        let row = Self.makePanel(size: CompanionPlacement.sidekickSize)
        let rowContainer = NSView(frame: NSRect(origin: .zero, size: CompanionPlacement.sidekickSize))
        let rowHosting = NSHostingView(rootView: CompanionSidekickRow(model: model))
        rowHosting.frame = rowContainer.bounds
        rowHosting.autoresizingMask = [.width, .height]
        rowContainer.addSubview(rowHosting)
        let rowMouse = SidekickMouseView(frame: rowContainer.bounds)
        rowMouse.autoresizingMask = [.width, .height]
        rowMouse.controller = self
        rowContainer.addSubview(rowMouse)
        row.contentView = rowContainer
        // Empty until a project with an avatar runs a session; never ordered out (a child window
        // ordered out leaves its parent), only made invisible and click-through.
        row.alphaValue = 0
        row.ignoresMouseEvents = true
        sidekickPanel = row

        let nameplate = Self.makePanel(size: CGSize(width: 10, height: 10))
        nameplate.ignoresMouseEvents = true
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        nameplate.contentView = host
        nameplate.alphaValue = 0
        nameplateHost = host
        nameplatePanel = nameplate

        let swap = Self.makePanel(size: CGSize(width: 10, height: 10))
        swap.ignoresMouseEvents = true
        let swapHost = NSHostingView(rootView: AnyView(EmptyView()))
        swap.contentView = swapHost
        swap.alphaValue = 0
        self.swapHost = swapHost
        swapPanel = swap
    }

    private static func makePanel(size: CGSize) -> NSPanel {
        let panel = CompanionPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = freeLevel
        panel.collectionBehavior = freeBehavior
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.sharingType = .none
        panel.isMovable = false
        return panel
    }

    // MARK: - Docking

    /// Rides in the window's bottom right corner as its child windows, at its level.
    private func attach(to window: NSWindow) {
        let panels = allPanels
        if dockWindow !== window {
            detach()
            dockWindow = window
            for panel in panels {
                panel.level = window.level
                panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
                window.addChildWindow(panel, ordered: .above)
            }
            let center = NotificationCenter.default
            // Child windows follow moves by themselves; a resize needs the new corner.
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                dockObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.followDockWindow() }
                })
            }
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                dockObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dockWindowChanged() }
                })
            }
        }
        panels.forEach { $0.orderFront(nil) }
        setOrigin(CompanionPlacement.dockedOrigin(in: window.frame))
    }

    /// Floats free again, above every app.
    private func detach() {
        let panels = allPanels
        if let window = dockWindow {
            panels.forEach { window.removeChildWindow($0) }
        }
        dockWindow = nil
        dockObservers.forEach(NotificationCenter.default.removeObserver)
        dockObservers = []
        for panel in panels {
            panel.level = Self.freeLevel
            panel.collectionBehavior = Self.freeBehavior
        }
    }

    private func followDockWindow() {
        guard ridesInWindow, let window = dockWindow, drag == nil, travel == nil else { return }
        setOrigin(CompanionPlacement.dockedOrigin(in: window.frame))
        pill?.companionMoved()
    }

    private func dockWindowChanged() {
        // After the notification the window's state is settled.
        DispatchQueue.main.async { [weak self] in
            self?.applyVisibility()
        }
    }

    /// Docks into the main window's corner (menu, or a drop near it).
    private func dock() {
        isDocked = true
        isAway = false
        applyVisibility()
    }

    // MARK: - Position

    private func setOrigin(_ newOrigin: CGPoint) {
        origin = newOrigin
        layoutCast()
    }

    /// Puts the creature at its home (the position the user dragged it to).
    private func restorePosition() {
        guard creaturePanel != nil else { return }
        cancelTravel()
        isAway = false
        if isDocked {
            if let window = visibleMainWindow { setOrigin(CompanionPlacement.dockedOrigin(in: window.frame)) }
            pill?.companionChanged()
            return
        }
        let saved = UserDefaults.standard.dictionary(forKey: Self.positionKey)
        let savedScreen = (saved?["screen"] as? Int).flatMap { id in NSScreen.screens.first { $0.companionDisplayID == id } }
        // Not NSScreen.main: it follows the key window, so the creature would hop displays.
        guard let screen = savedScreen ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        if savedScreen != nil, let x = saved?["x"] as? Double, let y = saved?["y"] as? Double {
            setOrigin(CompanionPlacement.absolute(CGPoint(x: x, y: y), in: visible))
        } else {
            setOrigin(CompanionPlacement.defaultOrigin(in: visible))
        }
        pill?.companionChanged()
    }

    /// A new size: resize both panels and keep the creature standing where it stood (same feet,
    /// same centre line), still on its display.
    private func appearanceChanged() {
        applySharing()
        // Only during a share does an appearance setting (show in shares) change visibility.
        if isScreenSharing { applyVisibility() }
        updateMouseMonitors()
        guard let creaturePanel, let overlayPanel else { return }
        cancelTravel()
        // Where it stands at home, without the crowd's step-in.
        let old = creaturePanel.frame.offsetBy(dx: -crowdShiftX, dy: 0)
        creaturePanel.setContentSize(CompanionPlacement.creatureSize)
        overlayPanel.setContentSize(CompanionPlacement.panelSize)
        var newOrigin = CGPoint(
            x: old.midX - CompanionPlacement.creatureSize.width / 2 - CompanionPlacement.sideMargin,
            y: old.minY)
        if ridesInWindow, let window = dockWindow {
            newOrigin = CompanionPlacement.dockedOrigin(in: window.frame)
        } else if let screen = screen(for: old) {
            newOrigin = CompanionPlacement.clamped(newOrigin, in: screen.visibleFrame)
        }
        setOrigin(newOrigin)
        if creaturePanel.isVisible, !isAway, !isDocked { savePosition() }
        pill?.companionMoved()
        tick()
    }

    private func savePosition() {
        guard let creature = creatureFrame, let screen = screen(for: creature) else { return }
        let relative = CompanionPlacement.relative(origin, in: screen.visibleFrame)
        UserDefaults.standard.set(
            ["screen": screen.companionDisplayID ?? 0, "x": Double(relative.x), "y": Double(relative.y)],
            forKey: Self.positionKey)
    }

    /// Back to the start: docked in the window corner, the free spot forgotten.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.positionKey)
        dock()
        restorePosition()
    }

    private func screen(for creature: NSRect) -> NSScreen? {
        let center = NSPoint(x: creature.midX, y: creature.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.screens.first
    }

    // MARK: - Mouse (from CompanionMouseView)

    fileprivate func hoverChanged(_ inside: Bool) {
        guard inside != isHovering else { return }
        isHovering = inside
        pill?.companionHover(inside)
        tick()
    }

    // MARK: - Project wheel

    /// The project list for the running recording, or for the one the saved card asks about.
    /// Opened by scrolling over the creature, or by Other / Change on the saved card (`openWheel`);
    /// scrolling over the creature or over the list turns it. One loop (`runWheelLoop`) decides:
    /// the shown entry is taken once the scrolling rested `wheelCommitDelay` (a trackpad rests only
    /// after the fingers lift); moving the pointer onto the list after the last scroll pauses that
    /// so a row can be clicked, and a click takes it at once; leaving creature and list for 0.25 s
    /// backs out, and Escape does too (MeetingPillController); an untouched list closes after 3 s
    /// unless the pointer rests on it; dictation closes it.
    fileprivate func scrolled(_ event: NSEvent) {
        handleWheelScroll(event)
    }

    /// A scroll over the pill's panel: turns the list while it shows. True when the wheel took it.
    func scrolledOverCard(_ event: NSEvent) -> Bool {
        guard wheel != nil, !wheelCommitted else { return false }
        handleWheelScroll(event)
        return true
    }

    /// Other / Change on the saved card: the list opens at once, without a scroll.
    func openWheel(for sessionID: UUID) {
        guard let viewModel, let session = viewModel.sessions.first(where: { $0.id == sessionID }) else { return }
        startWheel(for: session, gestureActive: false, fromClick: true)
    }

    /// Escape: the list closes without taking anything.
    func escapeWheel() {
        guard wheel != nil, !wheelCommitted else { return }
        cancelWheel()
    }

    /// The running recording, or the one the saved card is about.
    private var wheelTargetID: UUID? {
        viewModel?.isRecording == true ? viewModel?.currentSession?.id : pill?.savedSessionID
    }

    private func startWheel(for session: RecordingSession, gestureActive: Bool, fromClick: Bool) {
        guard let viewModel else { return }
        // A running recording's list ends in No Project, the saved card's question in Later, and
        // changing an already filed recording in nothing.
        let isRecording = viewModel.isRecording && viewModel.currentSession?.id == session.id
        let tail: AppViewModel.WheelTail = isRecording ? .noProject : (pill?.savedAsksForProject == true ? .later : .none)
        wheel = (ProjectWheel(
            items: viewModel.projectWheelItems(tail: tail),
            selected: viewModel.projectWheelSelection(for: session)), session.id)
        wheelCommitted = false
        wheelMoved = false
        wheelGestureActive = gestureActive
        wheelOpenedByClick = fromClick
        wheelOpenedAt = Date()
        wheelRestingSince = Date()
        wheelLastScroll = .distantPast
        wheelLastNotch = .distantPast
        wheelCardEnteredAt = fromClick ? Date() : .distantFuture
        if !fromClick { pill?.collapseCompanionCard() }
        showWheel()
        runWheelLoop()
    }

    private func handleWheelScroll(_ event: NSEvent) {
        // An open list keeps its recording even if the saved card behind it has gone.
        let openTarget = wheelCommitted ? nil : wheel?.sessionID
        guard let viewModel, let targetID = openTarget ?? wheelTargetID, drag == nil,
              let session = viewModel.sessions.first(where: { $0.id == targetID }) else { return }
        let precise = event.hasPreciseScrollingDeltas
        let momentum = !event.momentumPhase.isEmpty
        let ended = event.phase == .ended || event.phase == .cancelled
        if wheel == nil || wheel?.sessionID != session.id || wheelCommitted {
            // Only a mostly vertical, real movement opens it (no sideways swipe, no glide).
            guard !momentum, !ended, event.scrollingDeltaY != 0,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return }
            startWheel(for: session, gestureActive: precise, fromClick: false)
            return
        }
        guard var current = wheel, !momentum else { return }
        if precise {
            if event.phase == .began { wheelGestureActive = true }
            if ended {
                wheelGestureActive = false
                wheelRestingSince = Date()
                wheelLastScroll = Date()
            }
        } else {
            // Free-spin and smooth-scrolling mice send a burst per flick: at most one step per 60 ms.
            guard Date().timeIntervalSince(wheelLastNotch) >= 0.06 else { return }
        }
        let moved = current.state.scroll(
            deltaY: event.scrollingDeltaY, precise: precise, momentum: false, began: event.phase == .began)
        wheel = current
        guard moved else { return }
        if !precise { wheelLastNotch = Date() }
        wheelMoved = true
        wheelRestingSince = Date()
        wheelLastScroll = Date()
        lastMouseMove = Date()
        showWheel(commitAt: wheelCommitAt)
    }

    private var wheelCommitted = false
    private var wheelMoved = false
    private var wheelGestureActive = false
    private var wheelOpenedByClick = false
    private var wheelOpenedAt = Date.distantPast
    private var wheelRestingSince = Date.distantPast
    private var wheelLastScroll = Date.distantPast
    private var wheelLastNotch = Date.distantPast
    /// When the pointer last came onto the list (distantFuture while it is not on it).
    private var wheelCardEnteredAt = Date.distantFuture
    private var wheelCommitAt: Date?
    private var wheelPausedOnCard = false

    private func runWheelLoop() {
        wheelTask?.cancel()
        wheelTask = Task { [weak self] in
            var outsideSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, !self.wheelCommitted, self.wheel != nil else { return }
                let now = Date()
                guard self.pill?.model.dictation == nil else { self.cancelWheel(); return }
                // Where the pointer is, not hover events: a card swapped under a still pointer
                // gets none, and the creature's exit can arrive after the card's entry.
                let overCard = self.pill?.panelFrame?.contains(NSEvent.mouseLocation) == true && !self.isHovering
                if overCard {
                    if self.wheelCardEnteredAt == .distantFuture { self.wheelCardEnteredAt = now }
                } else {
                    self.wheelCardEnteredAt = .distantFuture
                }
                let inside = self.isHovering || overCard
                // A list opened by a click gets a moment before leaving counts.
                let settling = self.wheelOpenedByClick && now.timeIntervalSince(self.wheelOpenedAt) < 1
                if !inside && !settling {
                    outsideSince = outsideSince ?? now
                    if now.timeIntervalSince(outsideSince!) >= 0.25 { self.cancelWheel(); return }
                    continue
                }
                outsideSince = nil
                // On the list after the last scroll: the user is going for a row, so wait.
                let paused = overCard && self.wheelLastScroll < self.wheelCardEnteredAt
                if paused || self.wheelGestureActive { self.wheelRestingSince = now }
                if !self.wheelMoved {
                    if now.timeIntervalSince(self.wheelOpenedAt) >= 3, !paused, !settling { self.cancelWheel(); return }
                    if paused != self.wheelPausedOnCard {
                        self.wheelPausedOnCard = paused
                        self.showWheel()
                    }
                    continue
                }
                let commitAt = paused || self.wheelGestureActive
                    ? nil : self.wheelRestingSince.addingTimeInterval(Self.wheelCommitDelay)
                if commitAt != self.wheelCommitAt || paused != self.wheelPausedOnCard {
                    self.wheelPausedOnCard = paused
                    self.showWheel(commitAt: commitAt)
                }
                if let commitAt, now >= commitAt {
                    self.commitWheel()
                    return
                }
            }
        }
    }

    private func showWheel(commitAt: Date? = nil) {
        guard let wheel else { return }
        wheelCommitAt = commitAt
        let hint: String
        if wheelCommitted {
            hint = ""
        } else if !wheelMoved {
            hint = wheelOpenedByClick ? "Scroll or click a project" : "Scroll to change, pause to apply"
        } else if wheelPausedOnCard {
            hint = "Click a project to pick it"
        } else if wheelGestureActive {
            hint = "Lift your fingers to apply"
        } else {
            hint = "Move away or press Esc to cancel"
        }
        pill?.showProjectWheel(.init(
            wheel: wheel.state, commitAt: commitAt, commitDelay: Self.wheelCommitDelay,
            committed: wheelCommitted, hint: hint))
        tick()
    }

    /// A click on a row of the card: that entry is taken at once.
    func pickFromWheel(_ index: Int) {
        guard var current = wheel, !wheelCommitted else { return }
        current.state.select(index)
        wheel = current
        commitWheel()
    }

    private func commitWheel() {
        guard let wheel, let viewModel, let selected = wheel.state.selected else { return }
        wheelTask?.cancel()
        if selected.isLater {
            // The saved card's Later: the recording waits in the Inbox.
            pill?.laterSaved(for: wheel.sessionID)
        } else if selected.projectID != nil, pill?.savedSessionID == wheel.sessionID {
            // Opened from the saved card: it files and confirms there ("Filed to X", or Process
            // Now with automatic processing off), so the list just closes.
            pill?.projectChosen(wheel.sessionID, selected)
            cancelWheel()
            return
        } else {
            viewModel.assignProjectFromWheel(selected.projectID, to: wheel.sessionID)
            // A real project answers the saved card's question ("No Project" leaves it open).
            if selected.projectID != nil { pill?.endSaved(for: wheel.sessionID) }
        }
        wheelCommitted = true
        showWheel()
        hopStart = Date()
        wheelTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.wheelConfirmDuration))
            guard !Task.isCancelled else { return }
            self?.cancelWheel()
        }
    }

    /// Closes the list; nothing changes unless it was already taken.
    private func cancelWheel() {
        wheelTask?.cancel()
        wheelTask = nil
        wheel = nil
        wheelCommitted = false
        wheelCommitAt = nil
        wheelPausedOnCard = false
        pill?.hideProjectWheel()
    }

    fileprivate func mouseDown() {
        // A click on the creature backs out of an open project list.
        if wheel != nil, !wheelCommitted { cancelWheel() }
        cancelTravel()
        // From where it stands: a step-in becomes part of the dragged position.
        drag = (NSEvent.mouseLocation, CGPoint(x: origin.x + crowdShiftX, y: origin.y), false)
    }

    fileprivate func mouseDragged() {
        guard var current = drag else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - current.start.x
        let dy = mouse.y - current.start.y
        if !current.moved, hypot(dx, dy) < 3 { return }
        if !current.moved {
            // Pulled out of the window: it floats free from here on.
            detach()
            orderAllFront()
        }
        current.moved = true
        drag = current
        setOrigin(CGPoint(x: current.origin.x + dx, y: current.origin.y + dy))
        pill?.companionMoved()
    }

    fileprivate func mouseUp(clickCount: Int) {
        let moved = drag?.moved == true
        // Cleared first, so the drop's layout may step in again.
        drag = nil
        if moved {
            // Dropped near the window corner: docks again.
            if let window = visibleMainWindow, CompanionPlacement.isNearDock(origin, windowFrame: window.frame) {
                dock()
                pill?.companionMoved()
                return
            }
            // Dropped elsewhere: keep it on the display it landed on, snapped to a near edge.
            if let creature = creatureFrame, let screen = screen(for: creature) {
                setOrigin(CompanionPlacement.snapped(origin, in: screen.visibleFrame))
            }
            // Wherever the user drags it becomes its new home.
            isDocked = false
            isAway = false
            savePosition()
            pill?.companionMoved()
            return
        }
        hopStart = Date()
        if clickCount >= 2 {
            openFrontSessions(of: front.projectID)
        } else if let row = frontProjectChat() {
            // A project creature in front talks about its own session.
            pill?.model.openSessionChat(row)
        } else {
            pill?.companionClick()
        }
        tick()
    }

    fileprivate func showMenu(_ event: NSEvent, in view: NSView) {
        guard let pill else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuActions.handlers = [:]
        @discardableResult
        func add(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(CompanionMenuActions.run(_:)), keyEquivalent: "")
            item.target = menuActions
            item.tag = menu.items.count
            menuActions.handlers[item.tag] = action
            menu.addItem(item)
            return item
        }
        if viewModel?.isRecording == true {
            add("Stop Recording") { pill.model.stop() }
        } else {
            // A detected meeting is recorded as that meeting.
            add("Record") { if !pill.recordOfferedMeeting() { pill.model.recordNow() } }
        }
        if !pill.model.attentionRows.isEmpty {
            menu.addItem(.separator())
            for row in pill.model.attentionRows.prefix(6) {
                add("\(row.headline): \(row.project), \(row.session)") { pill.model.showSession(row.id) }
            }
        }
        menu.addItem(.separator())
        if pill.model.assistantWorking {
            add("Cancel Claude Task") { pill.model.assistantCancel() }
        }
        add("Claude (General)") { [weak self] in self?.viewModel?.openClaudeAssistant() }
        add("Bring Claude Windows Here") { [weak self] in self?.summonOrRestore() }
        add("Open MinuteMind") { pill.model.openApp() }
        if isAway {
            add("Go Back") { [weak self] in self?.goHome() }
        }
        if !isDocked {
            add("Dock to MinuteMind Window") { [weak self] in self?.dock() }
        }
        menu.addItem(.separator())
        let done = add("Notify When Claude Finishes") {
            UserDefaults.standard.set(!Self.doneNoticesEnabled, forKey: Self.doneNoticesKey)
        }
        done.state = Self.doneNoticesEnabled ? .on : .off
        add("Reset Position") { [weak self] in self?.resetPosition() }
        add("Hide Companion") { [weak self] in self?.setHidden(true) }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    // MARK: - Coming to the pointer

    /// Watches the pointer only while a shake can do something: the creature shows and the
    /// switch is on.
    private func updateMouseMonitors() {
        let wanted = creatureFrame != nil && CompanionAppearance.shared.comesOnShake
        guard wanted == mouseMonitors.isEmpty else { return }
        if wanted {
            shakeDetector.reset()
            // Mouse moves in other apps (global) and in MinuteMind itself (local).
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.mouseMoved(at: event.timestamp) }
            }) { mouseMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.mouseMoved(at: event.timestamp) }
                return event
            }) { mouseMonitors.append(local) }
        } else {
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors = []
        }
    }

    private func mouseMoved(at time: TimeInterval) {
        guard drag == nil, travel == nil else {
            shakeDetector.reset()
            return
        }
        let pointer = NSEvent.mouseLocation
        guard shakeDetector.add(x: pointer.x, at: time) else { return }
        comeToPointer(pointer)
    }

    /// Back to its home: the window corner when docked, else the spot it was last dragged to.
    private func goHome() {
        guard let creature = creatureFrame else { return }
        if isDocked {
            guard let window = visibleMainWindow else {
                // No window to go back to: it waits with the app.
                isAway = false
                applyVisibility()
                return
            }
            isAway = false
            move(to: CompanionPlacement.dockedOrigin(in: window.frame), crossesDisplays: screen(for: creature) != window.screen)
            return
        }
        let saved = UserDefaults.standard.dictionary(forKey: Self.positionKey)
        let homeScreen = (saved?["screen"] as? Int).flatMap { id in NSScreen.screens.first { $0.companionDisplayID == id } }
            ?? NSScreen.screens.first
        guard let homeScreen else { return }
        let visible = homeScreen.visibleFrame
        let home: CGPoint
        if let x = saved?["x"] as? Double, let y = saved?["y"] as? Double {
            home = CompanionPlacement.absolute(CGPoint(x: x, y: y), in: visible)
        } else {
            home = CompanionPlacement.defaultOrigin(in: visible)
        }
        move(to: home, crossesDisplays: screen(for: creature) != homeScreen)
        isAway = false
    }

    /// Runs over beside the pointer, on the pointer's screen; its home stays where it was.
    private func comeToPointer(_ pointer: CGPoint) {
        guard let creature = creatureFrame,
              let pointerScreen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) else { return }
        let target = CompanionPlacement.originNear(pointer: pointer, in: pointerScreen.visibleFrame)
        guard hypot(target.x - origin.x, target.y - origin.y) > 4 else { return }
        // Out of the window for the trip; Go Back brings it home again.
        isAway = true
        detach()
        orderAllFront()
        move(to: target, crossesDisplays: screen(for: creature) != pointerScreen)
    }

    /// Runs there, or fades out and in when it changes displays or motion is reduced.
    private func move(to target: CGPoint, crossesDisplays: Bool) {
        cancelTravel()
        if crossesDisplays || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fade(to: target)
            return
        }
        let distance = hypot(target.x - origin.x, target.y - origin.y)
        let duration = distance * Self.travelPeakFactor / Self.travelSpeed
        travel = (origin, target, Date(), min(0.45, max(0.18, duration)))
        travelTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.travelStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        travelTimer = timer
        travelStep()
    }

    private func travelStep() {
        guard let travel else {
            travelTimer?.invalidate()
            return
        }
        let elapsed = Date().timeIntervalSince(travel.start)
        let progress = travel.duration > 0 ? min(1, elapsed / travel.duration) : 1
        let eased = Self.dashProgress(progress)
        setOrigin(CGPoint(
            x: travel.from.x + (travel.to.x - travel.from.x) * eased,
            y: travel.from.y + (travel.to.y - travel.from.y) * eased))
        pill?.companionMoved()
        guard progress >= 1 else {
            // Draw at the travel rate, so the feet keep up with the dash.
            tick()
            return
        }
        cancelTravel()
        // Home in the window again: ride along as its child.
        if ridesInWindow { applyVisibility() }
        // A little hop on landing.
        hopStart = Date()
        tick()
    }

    /// Running speed in points per second; the trip lasts 0.18 to 0.45 s whatever the distance.
    private static let travelSpeed: CGFloat = 2800
    /// Full speed for the first 70 % of the trip, then a short ease-out.
    private static let travelCruise: Double = 0.7
    /// Peak speed over average speed of `dashProgress`.
    private static let travelPeakFactor = 2 / (1 + travelCruise)

    /// Distance covered (0 to 1) at a point of the trip (0 to 1): constant speed, then it slows
    /// down evenly to a stop.
    private static func dashProgress(_ progress: Double) -> Double {
        let cruise = travelCruise
        let speed = travelPeakFactor
        guard progress > cruise else { return speed * progress }
        let late = progress - cruise
        return min(1, speed * progress - speed * late * late / (2 * (1 - cruise)))
    }

    private func cancelTravel() {
        travel = nil
        travelTimer?.invalidate()
        travelTimer = nil
    }

    /// Out, over, in: 0.15 s each way.
    private func fade(to target: CGPoint) {
        // The row and the name card keep their own visibility (alpha 0 while empty).
        let panels = [creaturePanel, overlayPanel].compactMap { $0 }
        let rowShown = !model.sidekicks.isEmpty
        if rowShown { sidekickPanel?.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panels.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setOrigin(target)
                if self.ridesInWindow { self.applyVisibility() }
                self.pill?.companionMoved()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    panels.forEach { $0.animator().alphaValue = 1 }
                    if rowShown { self.sidekickPanel?.animator().alphaValue = 1 }
                }
                self.tick()
            }
        })
    }

    // MARK: - Summoning Claude windows

    /// Brings the Claude windows beside the creature; when they still sit where the last summon
    /// put them, puts them back instead.
    private func summonOrRestore() {
        let stillSummoned = !summoned.isEmpty && summoned.allSatisfy { $0.window.isVisible && $0.window.frame == $0.to }
        if stillSummoned {
            for move in summoned { move.window.setFrame(move.from, display: true, animate: true) }
            summoned = []
            return
        }
        guard let viewModel else { return }
        Task { [weak self] in
            let windows = await viewModel.claudeWindows()
            guard let self, !windows.isEmpty, let creature = self.creatureFrame, let screen = self.screen(for: creature) else { return }
            let frames = CompanionPlacement.fannedFrames(for: windows.map(\.frame.size), creature: creature, in: screen.visibleFrame)
            NSApp.activate(ignoringOtherApps: true)
            var moves: [(window: NSWindow, from: NSRect, to: NSRect)] = []
            for (window, frame) in zip(windows, frames).reversed() {
                moves.append((window, window.frame, frame))
                window.setFrame(frame, display: true, animate: true)
                window.orderFront(nil)
            }
            windows.first?.makeKeyAndOrderFront(nil)
            // Read back: the window may have adjusted the frame (minimum sizes).
            self.summoned = moves.map { ($0.window, $0.from, $0.window.frame) }
        }
    }

    // MARK: - Animation ticks

    private func updateBubbleVisibility() {
        let showsBubble = !(pill?.isPanelVisible ?? false)
        if model.showsBubble != showsBubble { model.showsBubble = showsBubble }
    }

    private func scheduleTimer(_ interval: TimeInterval) {
        guard interval != timerInterval else { return }
        timerInterval = interval
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.2
        // Common modes: keeps moving while a menu is open or a window live-resizes.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let creaturePanel, creaturePanel.isVisible, let viewModel, let pill else { return }
        let now = Date()
        let mouse = NSEvent.mouseLocation
        if mouse != lastMouse {
            if lastMouse != nil { lastMouseMove = now }
            lastMouse = mouse
        }
        let creature = creaturePanel.frame

        var signals = MascotMood.Signals()
        let sessions = viewModel.workspaceTerminals.claudeSessions
        let frontMember = front.projectID.flatMap { id in castProjects.first { $0.projectID == id } }
        let reported = Set(castProjects.compactMap(\.projectID))
        // The creature in front shows its own sessions; the home companion every session no
        // project creature reports.
        signals.claudeStatuses = sessions
            .filter { session in frontMember.map { session.projectID == $0.projectID } ?? !reported.contains(session.projectID) }
            .map(\.status)
        signals.isRecording = viewModel.isRecording
        switch pill.model.state {
        case .detected, .consent, .confirmStop: signals.meetingQuestion = true
        case .saved: signals.isCelebrating = true
        case .dot: signals.meetingRunning = true
        default: break
        }
        switch pill.model.dictation {
        // Perks up only once the microphone delivers sound, like the capsule's wave.
        case .listening, .claudeListening: signals.dictating = pill.model.dictationMicLive
        case .inserting: signals.dictating = true
        case .claudeWorking: signals.claudeTaskWorking = true
        case .claudeCopied: signals.isCelebrating = true
        case .claudeFailed: signals.claudeTaskFailed = true
        case .done, nil: break
        }
        // The voice assistant: working in the background, asking, done or failed.
        if pill.model.assistantWorking { signals.claudeTaskWorking = true }
        switch pill.model.assistant {
        case .ask: signals.meetingQuestion = true
        case .done: signals.isCelebrating = true
        case .failed: signals.claudeTaskFailed = true
        case .answer, nil: break
        }
        if let celebrateUntil, now < celebrateUntil { signals.isCelebrating = true }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .mouseMoved)
        signals.isDrowsy = !isHovering && idleSeconds > Self.sleepAfter

        let mood = MascotMood.resolve(signals)
        if mood != model.mood {
            if mood == .celebrating { hopStart = now }
            model.mood = mood
            moodSince = now
        }
        let moodAge = now.timeIntervalSince(moodSince)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frame = AssistantMascotPose.frame(.init(
            mood: mood,
            time: now.timeIntervalSinceReferenceDate,
            look: look(at: mouse, creature: creature, now: now),
            hovering: isHovering,
            hopAge: hopStart.map { now.timeIntervalSince($0) },
            moodAge: moodAge,
            headphones: signals.isRecording,
            avatar: frontMember?.avatar ?? CompanionAppearance.shared.avatar,
            animated: !reduceMotion,
            running: travel.map { $0.to.x >= $0.from.x ? 1 : -1 }
        ))
        if frame != model.frame { model.frame = frame }
        if model.frontAvatar != frontMember?.avatar { model.frontAvatar = frontMember?.avatar }
        if model.frontName != frontMember?.name { model.frontName = frontMember?.name }
        let frontColor = frontMember.map(Self.bodyColor(of:))
        if model.frontColor != frontColor { model.frontColor = frontColor }
        updateSidekicks(frontMember: frontMember, drowsy: signals.isDrowsy, now: now, animated: !reduceMotion)
        if model.isRecording != signals.isRecording { model.isRecording = signals.isRecording }
        if model.meetingRunning != signals.meetingRunning { model.meetingRunning = signals.meetingRunning }
        if let screen = screen(for: creature) {
            let opensLeft = CompanionPlacement.opensLeft(creature: creature, in: screen.visibleFrame)
            if model.opensLeft != opensLeft { model.opensLeft = opensLeft }
        }
        updateBubbleVisibility()
        layoutCast()
        scheduleTimer(reduceMotion ? 1 : interval(mood: mood, moodAge: moodAge, mouse: mouse, creature: creature, now: now))
    }

    /// How often to draw: fast only while something visibly moves.
    private func interval(mood: MascotMood, moodAge: TimeInterval, mouse: CGPoint, creature: NSRect, now: Date) -> TimeInterval {
        let hopping = hopStart.map { now.timeIntervalSince($0) < AssistantMascotPose.hopDuration } ?? false
        let pointerNear = hypot(mouse.x - creature.midX, mouse.y - creature.midY) < 400
            && now.timeIntervalSince(lastMouseMove) < 4
        let freshMood = mood.talks ? moodAge < AssistantMascotPose.talkDuration + 0.5 : moodAge < 1
        let flapping = mood == .celebrating && moodAge < AssistantMascotPose.celebrationFlapping + 0.5
        let excited = (mood == .waiting && moodAge < AssistantMascotPose.waitingExcitement)
            || (mood == .working && moodAge < 10)
        if isHovering || drag != nil || travel != nil || hopping || pointerNear || freshMood || flapping || excited || mood == .dictating {
            return 0.125
        }
        // Typing and waving flip four times a second; slower frames would freeze them.
        if sidekicksMove { return 0.25 }
        switch mood {
        case .working, .waiting: return 0.25
        case .sleeping: return 1
        default: return 0.5
        }
    }

    /// Where the eyes point when the pointer moved lately.
    private func look(at mouse: CGPoint, creature: NSRect, now: Date) -> (x: Int, y: Int)? {
        guard now.timeIntervalSince(lastMouseMove) < Self.followDuration else { return nil }
        let dx = mouse.x - creature.midX
        let dy = mouse.y - creature.midY
        let threshold: CGFloat = 24
        return (dx < -threshold ? -1 : dx > threshold ? 1 : 0, dy > threshold ? -1 : dy < -threshold ? 1 : 0)
    }

    // MARK: - Claude sessions (once a second, shown or not)

    private func statusTick() {
        guard let viewModel, let pill else { return }
        // A docked creature follows its window: back when the window is (reopened, restored),
        // gone when it is not.
        if started, ridesInWindow, !model.isHiddenByUser, !hiddenForShare, travel == nil, drag == nil {
            let window = visibleMainWindow
            let shown = creaturePanel?.isVisible ?? false
            if shown != (window != nil) || (window != nil && dockWindow !== window) { applyVisibility() }
        }
        let now = Date()
        let sessions = viewModel.workspaceTerminals.claudeSessions
        let current = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.status) })
        updateCast(sessions: sessions, now: now)
        defer { lastStatuses = current }
        for id in workingSince.keys where current[id] == nil { workingSince[id] = nil }
        for id in waitingSince.keys where current[id] == nil { waitingSince[id] = nil }
        for id in finishedAt.keys where current[id] == nil { finishedAt[id] = nil }
        notifiedWaiting.formIntersection(current.keys)

        // The first tick only learns the statuses; nothing changed yet.
        if let lastStatuses {
            for session in sessions {
                let id = session.id
                let old = lastStatuses[id] ?? .idle
                let status = session.status
                if status != old {
                    switch status {
                    case .working:
                        // A turn interrupted by a permission prompt keeps its start.
                        if workingSince[id] == nil { workingSince[id] = now }
                    case .waiting:
                        waitingSince[id] = now
                    case .error:
                        workingSince[id] = nil
                        notify(session, kind: .error, now: now)
                    case .done:
                        finishedAt[id] = now
                        let worked = workingSince[id].map { now.timeIntervalSince($0) } ?? 0
                        workingSince[id] = nil
                        if worked >= Self.doneMinimumWork { notify(session, kind: .done, now: now) }
                    case .idle:
                        workingSince[id] = nil
                    }
                }
                if status == .waiting {
                    if let since = waitingSince[id], now.timeIntervalSince(since) >= Self.waitingDebounce,
                       !notifiedWaiting.contains(id) {
                        notifiedWaiting.insert(id)
                        notify(session, kind: .waiting, now: now)
                    }
                } else {
                    waitingSince[id] = nil
                    notifiedWaiting.remove(id)
                }
            }
        }

        pill.setAttentionRows(sessions.compactMap { session in
            switch session.status {
            case .waiting: row(for: session, kind: .waiting)
            case .error: row(for: session, kind: .error)
            default: nil
            }
        })
        // A notice goes away once its session moved on, closed, or the user is looking at it.
        if let notice = pill.model.notice {
            let status = current[notice.id]
            let resolved = status == nil
                || (notice.kind == .waiting && status != .waiting)
                || (notice.kind == .error && status != .error)
            if resolved || viewModel.isLookingAtTerminalSession(notice.id) { pill.clearNotice() }
        }
    }

    private func notify(_ session: WorkspaceTerminalSession, kind: CompanionSessionRow.Kind, now: Date) {
        guard let viewModel, let pill else { return }
        // The user is looking at it: no notice, no hop.
        if viewModel.isLookingAtTerminalSession(session.id) { return }
        // A project creature that needs the user comes to the front.
        if kind != .done, castProjects.contains(where: { $0.projectID == session.projectID }) {
            let members = castProjects, busy = homeBusy
            changeFront { $0.promote(session.projectID, members: members, homeBusy: busy) }
        }
        if kind == .done {
            celebrateUntil = now.addingTimeInterval(Self.celebrationDuration)
            hopStart = now
            guard Self.doneNoticesEnabled else { return }
        }
        pill.showNotice(row(for: session, kind: kind))
    }

    // MARK: - Cast (projects' creatures, CompanionCast)

    /// The home companion has work of its own: recording, dictation, a meeting question, the
    /// voice assistant. It then stands in front.
    private var homeBusy: Bool {
        guard let viewModel, let pill else { return false }
        if viewModel.isRecording || pill.model.assistantWorking || pill.model.assistant != nil { return true }
        switch pill.model.dictation {
        case .done, nil: break
        default: return true
        }
        switch pill.model.state {
        case .detected, .consent, .confirmStop, .saved: return true
        default: return false
        }
    }

    private func updateCast(sessions: [WorkspaceTerminalSession], now: Date) {
        guard let viewModel else { return }
        let pairs = sessions.map { (projectID: $0.projectID, status: $0.status) }
        let home = CompanionAppearance.shared.avatar
        castProjects = CompanionCast.projectMembers(
            projects: viewModel.projects.sorted(by: Project.isOrderedBefore), sessions: pairs, homeAvatar: home)
        castHome = CompanionCast.homeMember(avatar: home, projectMembers: castProjects, sessions: pairs)
        let members = castProjects, busy = homeBusy
        changeFront { $0.update(members: members, homeBusy: busy, now: now) }
    }

    /// A project creature's body colour: the project's colour where CompanionCast asks for it,
    /// else its avatar's natural one (never the user's own colour, which is the home companion's).
    private static func bodyColor(of member: CompanionCastMember) -> Color {
        if let hex = member.colorHex { return Color(hex: hex) }
        if let natural = member.avatar.naturalBody { return Color(nsColor: ThemeColor.srgb(natural)) }
        return DesignSystem.Colors.accent
    }

    private var sidekickMoodSince: [String: (mood: MascotMood, since: Date)] = [:]
    private var sidekickHops: [String: Date] = [:]

    /// The sidekicks beside the creature in front, nearest first: the home companion (while a
    /// project stands in front), then the other projects.
    private func updateSidekicks(frontMember: CompanionCastMember?, drowsy: Bool, now: Date, animated: Bool) {
        var members = castProjects.filter { $0.projectID != frontMember?.projectID }
        if frontMember != nil, let castHome { members.insert(castHome, at: 0) }
        let sessions = viewModel?.workspaceTerminals.claudeSessions ?? []
        let reported = Set(castProjects.compactMap(\.projectID))
        var moods: [MascotMood] = []
        let sidekicks = members.enumerated().map { index, member -> CompanionSidekick in
            let own = sessions
                .filter { session in member.projectID.map { session.projectID == $0 } ?? !reported.contains(session.projectID) }
            let statuses = own.map(\.status)
            var signals = MascotMood.Signals()
            signals.claudeStatuses = statuses
            signals.isDrowsy = drowsy
            signals.isCelebrating = own.contains { session in
                session.status == .done
                    && finishedAt[session.id].map { now.timeIntervalSince($0) < Self.celebrationDuration } ?? false
            }
            // A sidekick celebrates with its thumb up.
            var mood = MascotMood.resolve(signals)
            if mood == .celebrating { mood = .thumbsUp }
            moods.append(mood)
            if sidekickMoodSince[member.id]?.mood != mood { sidekickMoodSince[member.id] = (mood, now) }
            let since = sidekickMoodSince[member.id]?.since ?? now
            // Idle ones chat: neighbours glance at each other (status poses come first).
            let glance = mood == .idle && animated
                ? CompanionCrowd.glance(
                    index: index, count: members.count, outwardRight: crowdOutwardRight,
                    time: now.timeIntervalSinceReferenceDate)
                : nil
            let frame = AssistantMascotPose.frame(.init(
                mood: mood,
                time: now.timeIntervalSinceReferenceDate,
                look: glance,
                hovering: model.hoveredSidekick == member.id,
                hopAge: sidekickHops[member.id].map { now.timeIntervalSince($0) },
                moodAge: now.timeIntervalSince(since),
                avatar: member.avatar,
                animated: animated,
                keepsWaving: true))
            return CompanionSidekick(
                id: member.id, projectID: member.projectID, name: member.name, avatar: member.avatar,
                color: member.projectID == nil ? nil : Self.bodyColor(of: member),
                status: CompanionCast.worst(statuses), frame: frame)
        }
        let ids = Set(sidekicks.map(\.id))
        sidekickMoodSince = sidekickMoodSince.filter { ids.contains($0.key) }
        sidekickHops = sidekickHops.filter { ids.contains($0.key) }
        sidekicksMove = moods.contains { $0 == .working || $0 == .waiting }
        if sidekicks != model.sidekicks { model.sidekicks = sidekicks }
        if let hovered = model.hoveredSidekick, !ids.contains(hovered) { sidekickHovered(nil) }
    }

    /// Places the creature at `origin` and its crowd beside it on the side toward the nearer
    /// screen edge (docked: inside the window, on the left), squeezed when the edge is near;
    /// when even the tightest huddle does not fit, the creature steps inward (CompanionCrowd).
    /// An empty crowd is hidden.
    private func layoutCast() {
        guard let creaturePanel else { return }
        let home = CompanionPlacement.creatureRect(panelOrigin: origin)
        let count = model.sidekicks.count
        var layout = CompanionCrowd.Layout(slots: [], stepIn: 0)
        if count > 0 {
            let docked = ridesInWindow && dockWindow != nil
            let visible = screen(for: home)?.visibleFrame
            let outwardRight = !docked && visible.map { CompanionPlacement.opensLeft(creature: home, in: $0) } == true
            let room: CGFloat
            if docked, let window = dockWindow {
                room = home.minX - window.frame.minX
            } else if let visible {
                room = outwardRight ? visible.maxX - home.maxX : home.minX - visible.minX
            } else {
                room = .greatestFiniteMagnitude
            }
            crowdOutwardRight = outwardRight
            layout = CompanionCrowd.layout(
                count: count, creature: home, pixel: CompanionPlacement.sidekickPixel,
                outwardRight: outwardRight, room: room,
                // Never under the pointer while dragged, nor out of its window corner.
                allowsStepIn: !docked && drag?.moved != true)
        }
        let shift = crowdOutwardRight ? -layout.stepIn : layout.stepIn
        crowdShiftX = shift
        let overlayOrigin = CGPoint(x: origin.x + shift, y: origin.y)
        if let overlayPanel, overlayPanel.frame.origin != overlayOrigin { overlayPanel.setFrameOrigin(overlayOrigin) }
        let creatureOrigin = CGPoint(x: home.minX + shift, y: home.minY)
        if creaturePanel.frame.origin != creatureOrigin { creaturePanel.setFrameOrigin(creatureOrigin) }
        layoutCrowd(layout.slots.map { $0.offsetBy(dx: shift, dy: 0) })
    }

    /// Puts the crowd panel over `slots` (screen rectangles), or hides it while empty.
    private func layoutCrowd(_ slots: [CGRect]) {
        guard let row = sidekickPanel else { return }
        guard !slots.isEmpty else {
            if row.alphaValue != 0 { row.alphaValue = 0 }
            row.ignoresMouseEvents = true
            if !model.crowdSlots.isEmpty { model.crowdSlots = [] }
            if model.hoveredSidekick != nil { sidekickHovered(nil) }
            return
        }
        let frame = slots.reduce(CGRect.null) { $0.union($1) }
        if row.frame != frame { row.setFrame(frame, display: true) }
        let local = slots.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        if model.crowdSlots != local { model.crowdSlots = local }
        // During a swap the scene stands in for the crowd. Not quite 0: a window at alpha 0 may
        // let clicks through, and the second click of a double click lands during the swap.
        let alpha: CGFloat = isSwapping ? Self.clickableAlpha : 1
        if row.alphaValue != alpha { row.alphaValue = alpha }
        row.ignoresMouseEvents = false
        if let hovered = model.hoveredSidekick { placeNameplate(for: hovered) }
    }

    /// A sidekick's canvas on screen, by its index in `model.sidekicks`.
    private func sidekickSlotOnScreen(_ index: Int) -> CGRect? {
        guard let row = sidekickPanel?.frame, model.crowdSlots.indices.contains(index) else { return nil }
        return model.crowdSlots[index].offsetBy(dx: row.minX, dy: row.minY)
    }

    fileprivate func sidekickHovered(_ index: Int?) {
        let sidekick = index.flatMap { model.sidekicks.indices.contains($0) ? model.sidekicks[$0] : nil }
        guard model.hoveredSidekick != sidekick?.id else { return }
        model.hoveredSidekick = sidekick?.id
        if let sidekick {
            nameplateHost?.rootView = AnyView(CompanionNameplate(sidekick: sidekick))
            placeNameplate(for: sidekick.id)
            if !isScreenSharing { nameplatePanel?.alphaValue = 1 }
        } else {
            nameplatePanel?.alphaValue = 0
        }
        tick()
    }

    /// The name card centred over its sidekick, just above the crowd.
    private func placeNameplate(for id: String) {
        guard let panel = nameplatePanel, let host = nameplateHost, let row = sidekickPanel?.frame,
              let index = model.sidekicks.firstIndex(where: { $0.id == id }),
              let slot = sidekickSlotOnScreen(index) else { return }
        let size = host.fittingSize
        var frame = NSRect(x: slot.midX - size.width / 2, y: row.maxY, width: size.width, height: size.height)
        if let screen = screen(for: row) {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// A click on a sidekick brings it to the front (the home companion too).
    fileprivate func sidekickClicked(_ index: Int) {
        // A click during a swap would start from the places it is heading to.
        guard !isSwapping, model.sidekicks.indices.contains(index) else { return }
        let sidekick = model.sidekicks[index]
        if wheel != nil, !wheelCommitted { cancelWheel() }
        sidekickHovered(nil)
        lastSidekickClick = (sidekick.projectID, Date())
        changeFront { $0.choose(sidekick.projectID, now: Date()) }
    }

    /// The second click of a double click on a sidekick: the first one already brought it to the
    /// front, so the row under the pointer shows someone else now; the remembered click names it.
    fileprivate func sidekickDoubleClicked() {
        guard let click = lastSidekickClick,
              Date().timeIntervalSince(click.at) <= NSEvent.doubleClickInterval + 0.1 else { return }
        lastSidekickClick = nil
        openFrontSessions(of: click.projectID)
    }

    /// A double click: a project creature brings its session forward (the one that needs the
    /// user, else the one focused last); the home companion fans the Claude windows out.
    private func openFrontSessions(of projectID: UUID?) {
        pill?.collapseCompanionCard()
        if let projectID {
            // The chat the first click opened would repeat what the session now shows.
            pill?.model.closeNotice()
            viewModel?.revealProjectSession(projectID)
        } else {
            summonOrRestore()
        }
    }

    // MARK: - Changing places

    /// Where one creature stands: the bottom left of its canvas, its pixel size, how it looks.
    private struct Placement {
        let origin: CGPoint
        let pixel: CGFloat
        let avatar: MascotAvatar
        let color: Color?
    }

    /// Every creature on screen by cast id ("home" or the project's UUID).
    private func placements() -> [String: Placement] {
        guard let creature = creaturePanel?.frame else { return [:] }
        var result: [String: Placement] = [:]
        let frontID = front.projectID?.uuidString ?? "home"
        result[frontID] = Placement(
            origin: creature.origin, pixel: CompanionPlacement.pixel,
            avatar: model.frontAvatar ?? CompanionAppearance.shared.avatar, color: model.frontColor)
        for (index, sidekick) in model.sidekicks.enumerated() {
            guard let slot = sidekickSlotOnScreen(index) else { continue }
            result[sidekick.id] = Placement(
                origin: slot.origin, pixel: CompanionPlacement.sidekickPixel, avatar: sidekick.avatar, color: sidekick.color)
        }
        return result
    }

    /// Changes who is in front; when someone else ends up there, they change places on screen.
    private func changeFront(_ change: (inout CompanionFront) -> Void) {
        let before = front.projectID
        let start = placements()
        change(&front)
        guard front.projectID != before else { return }
        hopStart = Date()
        tick()
        animateSwap(from: start, to: placements())
    }

    private func animateSwap(from start: [String: Placement], to end: [String: Placement]) {
        guard !isSwapping, let swapPanel, let swapHost, let creaturePanel, creaturePanel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !isScreenSharing else { return }
        let newFront = front.projectID?.uuidString ?? "home"
        let movers = end.compactMap { id, target -> CompanionSwapMover? in
            guard let origin = start[id] else { return nil }
            let comesForward = id == newFront
            return CompanionSwapMover(
                id: id, avatar: target.avatar, color: target.color,
                from: origin.origin, to: target.origin, fromPixel: origin.pixel, toPixel: target.pixel,
                arc: comesForward ? 6 * CompanionPlacement.pixel : 3 * CompanionPlacement.pixel,
                delay: comesForward ? 0.07 : 0)
        }
        guard movers.count > 1 else { return }
        // Room for every way and the highest hop.
        var area = movers.reduce(CGRect.null) { rect, mover in
            rect.union(CGRect(origin: mover.from, size: CGSize(width: 12 * mover.fromPixel, height: 16 * mover.fromPixel)))
                .union(CGRect(origin: mover.to, size: CGSize(width: 12 * mover.toPixel, height: 16 * mover.toPixel)))
        }
        area = area.insetBy(dx: -4, dy: 0)
        area.size.height += 8 * CompanionPlacement.pixel
        let swap = CompanionSwap(start: Date(), duration: Self.swapDuration, movers: movers, frame: area)
        swapHost.rootView = AnyView(CompanionSwapView(swap: swap))
        swapPanel.setFrame(area, display: true)
        swapPanel.alphaValue = 1
        isSwapping = true
        creaturePanel.alphaValue = 0
        overlayPanel?.alphaValue = 0
        sidekickPanel?.alphaValue = Self.clickableAlpha
        swapEnd?.cancel()
        swapEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.swapDuration))
            guard let self, !Task.isCancelled else { return }
            self.isSwapping = false
            self.creaturePanel?.alphaValue = 1
            self.overlayPanel?.alphaValue = self.isScreenSharing ? 0 : 1
            self.swapPanel?.alphaValue = 0
            self.swapHost?.rootView = AnyView(EmptyView())
            // Lands with a hop.
            self.hopStart = Date()
            self.tick()
        }
    }

    /// The chat for the project in front: its session that waits or erred, else the one that
    /// finished last; nil for the home companion or a project with nothing to say.
    private func frontProjectChat() -> CompanionSessionRow? {
        guard let id = front.projectID, let viewModel else { return nil }
        let sessions = viewModel.workspaceTerminals.claudeSessions.filter { $0.projectID == id && $0.request != nil }
        let session = sessions.first { $0.status == .waiting || $0.status == .error } ?? sessions.first
        guard let session else { return nil }
        let kind: CompanionSessionRow.Kind = switch session.status {
        case .waiting: .waiting
        case .error: .error
        default: .done
        }
        return row(for: session, kind: kind)
    }

    fileprivate func sidekickMenu(_ event: NSEvent, in view: NSView) {
        showMenu(event, in: view)
    }

    private func row(for session: WorkspaceTerminalSession, kind: CompanionSessionRow.Kind) -> CompanionSessionRow {
        let project = session.projectID == ProjectRepositoryService.generalProjectID
            ? "General"
            : viewModel?.projects.first { $0.id == session.projectID }?.name ?? "Project"
        let member = castProjects.first { $0.projectID == session.projectID }
        return CompanionSessionRow(
            id: session.id, kind: kind, project: project, session: session.displayName,
            request: session.request, avatar: member?.avatar, avatarColor: member.map(Self.bodyColor(of:)))
    }
}

/// Never becomes key, so clicking the creature leaves focus where it was.
private final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Catches the mouse over the creature and hands it to the controller; hover through a tracking
/// area, so the card opens without waiting for the next animation frame.
private final class CompanionMouseView: NSView {
    weak var controller: CompanionController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { controller?.hoverChanged(true) }
    override func mouseExited(with event: NSEvent) { controller?.hoverChanged(false) }

    override func mouseDown(with event: NSEvent) {
        // Ctrl click is a right click, as everywhere on the Mac.
        if event.modifierFlags.contains(.control) {
            controller?.showMenu(event, in: self)
        } else {
            controller?.mouseDown()
        }
    }

    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged() }

    override func mouseUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { return }
        controller?.mouseUp(clickCount: event.clickCount)
    }

    override func rightMouseDown(with event: NSEvent) { controller?.showMenu(event, in: self) }

    override func scrollWheel(with event: NSEvent) { controller?.scrolled(event) }
}

/// Takes clicks and hover over the crowd; which sidekick is found from its slot (CompanionCrowd).
private final class SidekickMouseView: NSView {
    weak var controller: CompanionController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func index(of event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return CompanionCrowd.index(at: point, slots: controller?.model.crowdSlots ?? [])
    }

    override func mouseMoved(with event: NSEvent) { controller?.sidekickHovered(index(of: event)) }
    override func mouseEntered(with event: NSEvent) { controller?.sidekickHovered(index(of: event)) }
    override func mouseExited(with event: NSEvent) { controller?.sidekickHovered(nil) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { controller?.sidekickMenu(event, in: self) }
    }

    override func mouseUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { return }
        if event.clickCount >= 2 {
            controller?.sidekickDoubleClicked()
            return
        }
        guard let index = index(of: event) else { return }
        controller?.sidekickClicked(index)
    }

    override func rightMouseDown(with event: NSEvent) { controller?.sidekickMenu(event, in: self) }
}

/// Target for the context menu's entries.
private final class CompanionMenuActions: NSObject {
    var handlers: [Int: () -> Void] = [:]
    @objc func run(_ sender: NSMenuItem) { handlers[sender.tag]?() }
}

extension NSScreen {
    /// The display's CoreGraphics ID, stable across launches for the same display.
    var companionDisplayID: Int? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }
}
