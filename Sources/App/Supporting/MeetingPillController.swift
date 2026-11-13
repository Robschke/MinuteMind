// Purpose: MeetingPillController, the floating "meeting pill" at the bottom of the screen: asks to
//          record when a meeting is detected, shows the running recording, asks before stopping
//          when the end is uncertain, and offers processing once a recording is saved. While the
//          user shares their screen the pill hides and a menu bar item mirrors every state.
// Dependencies: AppKit (NSPanel, NSStatusItem), SwiftUI (Sources/App/Views/MeetingPillView.swift),
//               UserNotifications (heads-up for "Meeting over?" during a screen share),
//               Sources/App/ViewModels/AppViewModel.swift (actions via closures, mic level),
//               Sources/App/Supporting/SharedPublishCard.swift (the saved card's publish rules),
//               Sources/App/Supporting/PillCardCountdown.swift (real hovers, notice countdown)
// Used by: Sources/App/ViewModels/AppViewModel.swift (owns the controller, feeds radar events),
//          Sources/App/Supporting/QuickDictationController.swift (dictation states),
//          Sources/App/Supporting/CompanionController.swift (Record in the companion's menu)
// Notes: UX decisions by the user (2026-09-29), refined by design review 1:
//        - Hidden when idle. A detected meeting shows a one-row glass card; ignored for 10 s it
//          shrinks to a hollow record ring that stays until the call ends. Nothing is ever
//          recorded unasked.
//        - Recording: red dot, level bars and timer; Open and Stop appear after 120 ms of hover
//          and hide 400 ms after the pointer leaves.
//        - A recording ends only when the user stops it (user decision 2026-10-08, after
//          recordings were cut off mid-call). The call app releasing the mic, or long silence,
//          only asks "Meeting over?" with Stop and Keep Recording; the question stays until
//          answered and never stops anything by itself.
//        - After saving: without a project the card asks "Which project?" (recent projects one
//          click each, Other menu, project wheel) for 30 s; picking one starts everything else on
//          its own, no answer leaves the recording in the inbox (user decision 2026-10-27). With
//          a project it says where it went, with Change, for 15 s.
//        - Filed to a Shared Project (already, or picked on the card) it asks "Share with the
//          Acme team?" with Publish and Keep private for 30 s; no answer, Escape or closing it
//          otherwise keeps the recording private (rules in SharedPublishCard.swift, the choice
//          goes to AppViewModel.setPublication through `onSetPublication`).
//        - Every countdown pauses while the pointer is over the pill and resumes with at least
//          3 s left.
//        - One-time consent notice before the very first recording.
//        - Fixed bottom center, 40 pt up so it clears other bottom-center bars (the user runs
//          Wispr Flow). The screen is chosen when the pill appears and kept until it hides, so
//          it never jumps displays mid-meeting.
//        - The idle bar sits lower, 24 pt up (user request 2026-10-05: it was in the way), so its
//          transparent shadow margin ends at the visible frame and never covers the Dock. It
//          follows the mouse to another screen once the pointer stayed there for two 0.25 s
//          ticks (no flicker on a quick sweep across a display edge). A dictation keeps the
//          height it started at, so a meeting detected mid-dictation does not make it jump.
//          Display or Dock changes re-place the visible pill.
//        - Visible to the user, never to other call participants: sharingType = .none, and while
//          a screen share is detected the pill hides and the menu bar item takes over.
//        - State changes are announced to VoiceOver, since the panel never becomes key.
//        The panel is non-activating, so clicking it never steals focus from the call. It sits at
//        screen-saver level and joins all Spaces including full-screen ones.
//        One pill for dictation and meetings (user decision 2026-10-04, Wispr Flow style): when
//        idle a quiet 40x8 pt bar stays visible (overriding "hidden when idle"); hovering opens
//        it to the dictation hint and Record. Quick dictation (QuickDictationController) shows a
//        capsule with a scrolling waveform and the live text over whatever meeting state is
//        active; countdowns hold while dictating and the meeting state returns afterwards.
//        Dictation shows even during a screen share (as the old dictation HUD did); the idle bar
//        hides then.
//        Claude mini tasks (hold key + Control) use the same capsule with an accent-coloured sparkle: listening
//        with Open Chat and Cancel, "Claude is on it" while it works, then "Copied" (answer on
//        the clipboard) or a short failure message.
//        Quick recordings (double tap of the dictation key) use the normal recording capsule plus
//        a quiet "fn to stop" hint, since their stop is the key, not the pill; Stop still works.
//        They never get the "Meeting over?" question (no silence monitor runs for them).
//        Desktop companion (2026-10-13, CompanionController): while the creature shows, the pill has
//        no idle bar and its cards open beside the creature (`companionAnchor`, `placeBesideCompanion`).
//        Cards that need the user open by themselves; the idle card, the ignored-meeting ring and
//        the recording capsule open on a click on the creature, never on hover (`companionClick`). Claude
//        session notices (`showNotice`) use the same panel. Without the companion (hidden by the
//        user, or during a screen share) everything behaves as described above.
//        The project wheel (`showProjectWheel`, scrolled over the companion while recording)
//        outranks every card but dictation, since the user is acting on it right now.

import AppKit
import Observation
import SwiftUI
import UserNotifications

/// What the pill shows about a detected meeting.
struct PillMeeting: Equatable {
    var title: String
    /// Second line, e.g. "Microsoft Teams · 10:00 to 10:30".
    var subtitle: String
    var appBundleID: String?
    /// Calendar event this meeting belongs to, if any.
    var calendarEventID: String?

    /// Title without mail and calendar noise ("FW: ", "[External] ", ...), for display only.
    static func displayTitle(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespaces)
        let prefixes = ["fw:", "fwd:", "wg:", "aw:", "re:", "[external]", "[extern]", "meeting:", "termin:"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where result.lowercased().hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return result.isEmpty ? title : result
    }
}

/// What the voice assistant shows beside the companion (ClaudeAssistantService outcomes).
enum AssistantCard: Equatable {
    /// Text for the user that could not go to a text field: Copy or Insert.
    case answer(String)
    case done(summary: String, details: String)
    /// Claude needs an answer; typed or dictated into the card's field.
    case ask(String)
    case failed(String)
}

/// The project list scrolled over the companion during a recording (CompanionController).
struct ProjectWheelCard: Equatable {
    var wheel: ProjectWheel
    /// When the shown project is taken if the scrolling stays still; nil once taken.
    var commitAt: Date?
    /// Length of the wait, for the draining line.
    var commitDelay: TimeInterval
    /// The recording now files to the selected project.
    var committed = false
    /// What to do next, under the list ("Scroll to change, pause to apply", ...).
    var hint = ""
}

/// A Claude session the companion reports: in a notice beside it and in its hover popup.
struct CompanionSessionRow: Equatable, Identifiable {
    enum Kind: Equatable { case waiting, error, done }
    /// The terminal session's ID.
    var id: UUID
    var kind: Kind
    /// "Acme" or "General".
    var project: String
    /// "Claude 2", or the name the user gave the tab.
    var session: String
    /// What the session asks, for the chat card (ClaudeSessionRequest); nil: a plain row.
    var request: ClaudeSessionRequest? = nil
    /// The project's own creature and its colour (CompanionCast); nil: the home companion.
    var avatar: MascotAvatar? = nil
    var avatarColor: Color? = nil

    var headline: String {
        switch kind {
        case .waiting: return "Claude needs you"
        case .error: return "Claude ran into an error"
        case .done: return "Claude is done"
        }
    }
}

@Observable
@MainActor
final class MeetingPillModel {
    enum State: Equatable {
        case hidden
        case detected(PillMeeting)
        case dot(PillMeeting)
        case consent(PillMeeting)
        case recording
        case confirmStop(EndSignal)
        case saved(sessionID: UUID, title: String, minutes: Int, next: SavedNext, secondsLeft: Int)

        /// Changes only when the kind of state changes, so countdown ticks do not re-animate.
        var kind: Int {
            switch self {
            case .hidden: return 0
            case .detected: return 1
            case .dot: return 2
            case .consent: return 3
            case .recording: return 4
            case .confirmStop: return 5
            case .saved: return 6
            }
        }
    }

    /// Why the pill asks whether the meeting is over.
    enum EndSignal: Equatable {
        /// Both sides were silent this long.
        case silence(TimeInterval)
        /// The call app (by name) released the microphone or quit.
        case callEnded(String)
    }

    /// Quick dictation shown over whatever meeting state is active (nil when not dictating).
    enum Dictation: Equatable {
        case listening(text: String)
        case inserting
        /// Brief confirmation after the paste; `copied` when the text went to the clipboard.
        case done(copied: Bool)
        /// Claude mini task (hold key + Control): listening while held, with Open Chat and Cancel.
        case claudeListening
        case claudeWorking
        /// The answer is on the clipboard.
        case claudeCopied
        case claudeFailed(String)

        var isClaude: Bool {
            switch self {
            case .claudeListening, .claudeWorking, .claudeCopied, .claudeFailed: return true
            default: return false
            }
        }
    }

    var state: State = .hidden {
        // An open Clipboard list belongs to the state it was opened in.
        didSet { if oldValue.kind != state.kind { showsClipboard = false } }
    }
    var dictation: Dictation?
    /// Recent dictation levels, oldest first, for the scrolling waveform.
    var dictationLevels: [Float] = Array(repeating: 0, count: MeetingPillModel.waveSamples)
    /// The dictation microphone delivers sound. Until then the capsule shows it is still
    /// starting, because words spoken meanwhile are lost (AirPods take about a second).
    var dictationMicLive = false
    /// The microphone still delivers no sound `MeetingPillController.micStallDelay` after the
    /// capsule showed (or after a device change): the capsule says so in words.
    var dictationMicStalled = false
    /// Show the quiet idle bar when there is no meeting state (Wispr Flow style).
    var idleBarEnabled = false
    var idleExpanded = false {
        didSet { if !idleExpanded { showsClipboard = false } }
    }
    /// The companion card shows the Clipboard list instead of its buttons.
    var showsClipboard = false
    /// Where the Clipboard list reads from (live: a copy made while it shows appears at once).
    @ObservationIgnored var clipboardSource: ClipboardHistory?
    /// The last copied texts, newest first.
    var clipboardItems: [ClipboardHistory.Item] { clipboardSource?.items ?? [] }
    /// "Hold fn to dictate", or nil when quick dictation is off.
    var dictationHint: String?
    var level: Float = 0
    var recordingStartedAt: Date?
    /// "fn to stop" while a quick recording runs; nil for meetings.
    var recordingStopHint: String?
    var isHovering = false
    var showsRecordingControls = false {
        didSet { if !showsRecordingControls { showsClipboard = false } }
    }
    var dotExpanded = false {
        didSet { if !dotExpanded { showsClipboard = false } }
    }
    /// 1 at the start of the saved countdown, 0 when it expires.
    var countdownProgress: Double = 1

    // Desktop companion (CompanionController): the pill's content opens beside the creature.
    /// True while the companion shows; the idle bar is gone then and popups anchor to it.
    var companionMode = false
    /// The popup sits left of the creature (content aligns to its trailing edge).
    var opensLeft = true
    /// A short note beside the creature about a Claude session.
    var notice: CompanionSessionRow?
    /// Claude sessions that wait or failed, listed in the creature's hover popup.
    var attentionRows: [CompanionSessionRow] = []
    /// A recording hint ("Already recording") is flashing, so the capsule shows without hover.
    var hintFlashing = false
    /// A click on the creature opened the card: it stays 6 s after the pointer leaves.
    var cardPinned = false
    /// The one-time card that explains the creature's gestures.
    var showsCoach = false
    /// The voice assistant's current card, nil when none shows.
    var assistant: AssistantCard?
    /// A request runs in the background (the companion works meanwhile).
    var assistantWorking = false
    /// The answer being typed or dictated into an ASK card.
    var askDraft = ""
    /// The reply typed into a Claude session's chat card.
    var sessionDraft = ""
    /// The listening capsule shows that selected text goes along.
    var assistantHasSelection = false
    /// The project list while the user scrolls over the companion, nil otherwise.
    var projectWheel: ProjectWheelCard?

    static let waveSamples = 18

    var elapsed: TimeInterval { recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// What is on screen: dictation wins over the meeting state; the idle bar shows otherwise.
    /// Changes trigger a resize and the state transition animation.
    var displayKind: Int {
        switch dictation {
        case .listening: return 20
        case .inserting: return 21
        case .done: return 22
        case .claudeListening: return 23
        case .claudeWorking: return 24
        case .claudeCopied: return 25
        case .claudeFailed: return 26
        case nil: return state == .hidden ? (idleBarEnabled ? 10 : 0) : state.kind
        }
    }

    /// Countdowns hold while the pointer is over the pill or the user is dictating.
    /// VoiceOver users cannot hover, so cards wait for them.
    var holdsCountdown: Bool { isHovering || dictation != nil || NSWorkspace.shared.isVoiceOverEnabled }

    // Actions, wired by the controller.
    @ObservationIgnored var record: (PillMeeting) -> Void = { _ in }
    @ObservationIgnored var ignore: () -> Void = {}
    @ObservationIgnored var confirmConsent: (PillMeeting) -> Void = { _ in }
    @ObservationIgnored var stop: () -> Void = {}
    @ObservationIgnored var keepRecording: () -> Void = {}
    @ObservationIgnored var openApp: () -> Void = {}
    /// What happens to a saved recording next (MeetingProcessingRule).
    enum SavedNext: Equatable {
        /// No project yet: the card asks. `quick` are one-click choices (recently used projects),
        /// `all` every project and General for the Other menu. Nothing is processed until one is
        /// picked; unanswered, the recording waits in the Inbox.
        /// `processes`: automatic processing is on, so a pick starts everything else.
        case chooseProject(quick: [ProjectWheel.Item], all: [ProjectWheel.Item], processes: Bool)
        /// Has a project: transcript, summary and knowledge follow on their own.
        case filed(project: String, all: [ProjectWheel.Item])
        /// Automatic processing is off: only on request.
        case manual
        /// Filed to a Shared Project: Publish or Keep private (SharedPublishCard.swift has the
        /// rules). `alreadyFiled`: it came to the card with that project (calendar mapping,
        /// record picker, picked while recording), so the card says where it went and offers
        /// Change; false once picked on the card. `processes`: false offers Process Now after
        /// the answer.
        case publish(project: String, alreadyFiled: Bool, all: [ProjectWheel.Item], processes: Bool)

        /// The saved card's second line after the duration.
        var hint: String {
            switch self {
            case .chooseProject: return "Which project?"
            case .filed(let project, _): return "Filed to \(project), summary follows"
            case .manual: return "Process now, or find it in Inbox"
            case .publish(let project, let alreadyFiled, _, _):
                return alreadyFiled ? "Filed to \(project)" : Self.publishQuestion(project)
            }
        }

        var asksForProject: Bool {
            if case .chooseProject = self { return true }
            return false
        }

        /// Every choice for the project menu.
        var allChoices: [ProjectWheel.Item] {
            switch self {
            case .chooseProject(_, let all, _), .filed(_, let all), .publish(_, _, let all, _): return all
            case .manual: return []
            }
        }
    }

    @ObservationIgnored var process: (UUID) -> Void = { _ in }
    @ObservationIgnored var later: (UUID) -> Void = { _ in }
    @ObservationIgnored var openInbox: (UUID) -> Void = { _ in }
    /// Closes the saved card without deferring anything (its recording is filed already).
    @ObservationIgnored var dismissSaved: () -> Void = {}
    /// Other / Change on the saved card: the project wheel opens for that recording.
    @ObservationIgnored var openProjectWheel: (UUID) -> Void = { _ in }
    /// The saved card's project choice: the recording files to that project (or General).
    @ObservationIgnored var chooseProject: (UUID, ProjectWheel.Item) -> Void = { _, _ in }
    /// Publish or Keep private on the saved card of a recording in a Shared Project.
    @ObservationIgnored var answerPublication: (UUID, MeetingPublication) -> Void = { _, _ in }
    @ObservationIgnored var recordNow: () -> Void = {}
    @ObservationIgnored var openClaudeChat: () -> Void = {}
    @ObservationIgnored var cancelClaudeTask: () -> Void = {}
    /// Companion popup: bring a Claude session forward, open the Claude (General) window.
    @ObservationIgnored var showSession: (UUID) -> Void = { _ in }
    /// Chat card: answer the session in place, or open the card for a row of the list.
    @ObservationIgnored var answerSession: (CompanionSessionRow, ClaudeSessionRequest.Answer) -> Void = { _, _ in }
    @ObservationIgnored var openSessionChat: (CompanionSessionRow) -> Void = { _ in }
    @ObservationIgnored var closeNotice: () -> Void = {}
    @ObservationIgnored var openClaude: () -> Void = {}
    @ObservationIgnored var summonClaude: () -> Void = {}
    /// Companion card: open the Clipboard list, put an entry back on the clipboard, paste it.
    @ObservationIgnored var openClipboard: () -> Void = {}
    @ObservationIgnored var clipboardCopy: (ClipboardHistory.Item) -> Void = { _ in }
    @ObservationIgnored var clipboardInsert: (ClipboardHistory.Item) -> Void = { _ in }
    @ObservationIgnored var assistantCopy: () -> Void = {}
    @ObservationIgnored var assistantInsert: () -> Void = {}
    @ObservationIgnored var assistantDismiss: () -> Void = {}
    @ObservationIgnored var assistantSend: () -> Void = {}
    @ObservationIgnored var assistantCancel: () -> Void = {}
    @ObservationIgnored var dismissCoach: () -> Void = {}
    /// A click on a row of the project wheel (its index in the list).
    @ObservationIgnored var projectWheelPick: (Int) -> Void = { _ in }
    /// The recording capsule beside the companion explains the wheel (first recordings only).
    var showsWheelHint = false
    /// A hover intent changed what should be on screen; the controller re-checks visibility.
    @ObservationIgnored var presentationChanged: () -> Void = {}

    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    /// Hover intent for the recording capsule: reveal after 120 ms, hide 400 ms after leaving.
    func hoverRecording(_ inside: Bool, intent: Int = 120) {
        hover(inside, open: intent, close: 400) { $0.showsRecordingControls = $1 }
    }

    /// Hover on the idle bar: open to the dictation hint and Record after 150 ms.
    func hoverIdle(_ inside: Bool, intent: Int = 150) {
        hover(inside, open: intent, close: 400) { $0.idleExpanded = $1 }
    }

    /// Hover on a card that belongs to the current state's click card (tool row, Clipboard list):
    /// it keeps that card open like hovering the card itself.
    func hoverCurrentCard(_ inside: Bool) {
        switch state {
        case .dot: hoverDot(inside)
        case .recording: hoverRecording(inside)
        default: hoverIdle(inside)
        }
    }

    /// Hover on the ignored-meeting ring: expand to "Record <title>" after 150 ms.
    func hoverDot(_ inside: Bool, intent: Int = 150) {
        hover(inside, open: intent, close: 300) { $0.dotExpanded = $1 }
    }

    /// Opens after `open` ms inside, closes `close` ms after leaving (6 s when a click pinned it).
    private func hover(_ inside: Bool, open: Int, close: Int, apply: @escaping (MeetingPillModel, Bool) -> Void) {
        isHovering = inside
        hoverTask?.cancel()
        let delay = inside ? open : (cardPinned ? 6000 : close)
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            apply(self, inside)
            if !inside { self.cardPinned = false }
            self.presentationChanged()
        }
    }

    /// A click on the creature: open the quiet state's card at once and pin it, or close it.
    func togglePinnedCard() {
        hoverTask?.cancel()
        let open: Bool
        switch state {
        case .hidden:
            open = !(idleExpanded && cardPinned)
            idleExpanded = open
        case .dot:
            open = !(dotExpanded && cardPinned)
            dotExpanded = open
        case .recording:
            open = !(showsRecordingControls && cardPinned)
            showsRecordingControls = open
        default:
            return
        }
        cardPinned = open
        presentationChanged()
    }

    func collapsePinnedCard() {
        hoverTask?.cancel()
        cardPinned = false
        idleExpanded = false
        dotExpanded = false
        showsRecordingControls = false
        presentationChanged()
    }
}

@MainActor
final class MeetingPillController {
    static let consentKey = "mm.recordingConsentAcknowledged"
    static let wheelHintCountKey = "mm.wheelHintCount"

    let model = MeetingPillModel()

    /// Hooks into AppViewModel.
    var onRecord: (PillMeeting) -> Void = { _ in }
    var onStop: () -> Void = {}
    var onOpenApp: () -> Void = {}
    var onProcess: (UUID) -> Void = { _ in }
    var onLater: (UUID) -> Void = { _ in }
    /// A saved meeting without a project: show the Inbox, where its project is chosen.
    var onOpenInbox: (UUID) -> Void = { _ in }
    /// A project was picked on the saved card (or the menu bar item).
    var onChooseProject: (UUID, UUID) -> Void = { _, _ in }
    /// Whether a project is a Shared Project (AppViewModel.isSharedProject).
    var isSharedProject: (UUID?) -> Bool = { _ in false }
    /// The name of the Shared Project a saved recording is filed to; nil for none, General or a
    /// Private project.
    var sharedProjectOfSession: (UUID) -> String? = { _ in nil }
    /// The saved card's publish answer (AppViewModel.setPublication).
    var onSetPublication: (UUID, MeetingPublication) -> Void = { _, _ in }
    /// Record from the idle bar (no detected meeting).
    var onRecordNow: () -> Void = {}
    /// Claude task buttons, wired by QuickDictationController.
    var onOpenClaudeChat: () -> Void = {}
    var onCancelClaudeTask: () -> Void = {}
    /// Companion popup actions, wired by AppViewModel.
    var onShowSession: (UUID) -> Void = { _ in }
    /// Answers a Claude session from its chat card (CompanionController wires the terminals).
    /// False when the request was no longer current (nothing was typed).
    var onAnswerSession: (CompanionSessionRow, ClaudeSessionRequest.Answer) -> Bool = { _, _ in false }
    var onOpenClaude: () -> Void = {}
    var onSummonClaude: () -> Void = {}
    /// A row of the project wheel was clicked (CompanionController takes it).
    var onProjectWheelPick: (Int) -> Void = { _ in }
    /// Other / Change on the saved card: open the project wheel for that recording.
    var onOpenProjectWheel: (UUID) -> Void = { _ in }
    /// A scroll over the panel, for the open project wheel; true when it was taken.
    var onScrollOverPanel: (NSEvent) -> Bool = { _ in false }
    /// Escape while the project wheel shows: close it without taking anything.
    var onWheelEscape: () -> Void = {}
    /// The panel appeared or disappeared (the companion hides its bubble while a popup shows).
    var onPanelVisibilityChanged: () -> Void = {}
    var levelProvider: () -> Float = { 0 }
    /// The companion creature's frame on screen while it shows, nil otherwise. Popups open beside
    /// it; without it the pill sits at the bottom centre as it always did.
    var companionAnchor: () -> NSRect? = { nil }

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var statusItem: NSStatusItem?
    private var pinnedScreen: NSScreen?
    /// Idle bar screen follow: polls the mouse screen while the idle bar shows.
    private var screenFollowTimer: Timer?
    private var followCandidate: NSScreen?
    private var followTicks = 0
    /// Whether the current dictation started from the idle bar (and so uses its lower anchor).
    private var dictationUsesIdleAnchor = false
    private var screenObserver: NSObjectProtocol?
    private var isScreenSharing = false
    private var countdownTask: Task<Void, Never>?
    private var levelTimer: Timer?
    private var dictationTimer: Timer?
    private var dictationLevelProvider: () -> Float = { 0 }
    private var dictationLiveProvider: () -> Bool = { false }
    /// Since when the capsule waits for the microphone, for the stall notice.
    private var dictationWaitingSince = Date.distantPast
    private static let micStallDelay: TimeInterval = 3
    private var statusTimer: Timer?
    private var dismissedMeeting: PillMeeting?
    /// A meeting detected while the pill was busy (e.g. showing "saved"); shown once it is free.
    private var pendingMeeting: PillMeeting?
    private var settleTask: Task<Void, Never>?
    private var lastLayoutKind = -1
    private var noticeTask: Task<Void, Never>?
    private var assistantDismissTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var coachDismissed: () -> Void = {}
    private let statusActions = StatusActions()

    init() {
        model.record = { [weak self] meeting in self?.recordTapped(meeting) }
        model.confirmConsent = { [weak self] meeting in
            UserDefaults.standard.set(true, forKey: Self.consentKey)
            self?.onRecord(meeting)
        }
        model.ignore = { [weak self] in self?.ignoreTapped() }
        model.stop = { [weak self] in self?.onStop() }
        model.keepRecording = { [weak self] in self?.keepRecordingTapped() }
        model.openApp = { [weak self] in self?.onOpenApp() }
        model.process = { [weak self] id in self?.finishSaved { self?.onProcess(id) } }
        model.later = { [weak self] id in self?.finishSaved { self?.onLater(id) } }
        model.openInbox = { [weak self] id in self?.finishSaved { self?.onOpenInbox(id) } }
        model.chooseProject = { [weak self] id, item in self?.projectChosen(id, item) }
        model.answerPublication = { [weak self] id, publication in self?.publicationAnswered(id, publication) }
        model.dismissSaved = { [weak self] in self?.finishSaved {} }
        model.openProjectWheel = { [weak self] id in self?.onOpenProjectWheel(id) }
        model.recordNow = { [weak self] in
            self?.model.idleExpanded = false
            self?.onRecordNow()
        }
        model.openClaudeChat = { [weak self] in self?.onOpenClaudeChat() }
        model.cancelClaudeTask = { [weak self] in self?.onCancelClaudeTask() }
        model.showSession = { [weak self] id in
            self?.clearNotice()
            self?.model.idleExpanded = false
            self?.onShowSession(id)
            self?.applyVisibility()
        }
        model.answerSession = { [weak self] row, answer in
            guard let self else { return }
            if self.onAnswerSession(row, answer) {
                self.model.sessionDraft = ""
                self.clearNotice()
            } else {
                // Answered elsewhere or replaced: nothing was typed; the companion shows the
                // session's current request instead, if it has one.
                self.clearNotice()
                self.announce("Already answered in the session")
            }
        }
        model.openSessionChat = { [weak self] row in
            self?.model.idleExpanded = false
            self?.model.dotExpanded = false
            self?.showNotice(row, force: true)
        }
        model.closeNotice = { [weak self] in self?.clearNotice() }
        model.openClaude = { [weak self] in
            self?.model.collapsePinnedCard()
            self?.onOpenClaude()
            self?.applyVisibility()
        }
        model.summonClaude = { [weak self] in
            self?.model.collapsePinnedCard()
            self?.onSummonClaude()
        }
        model.openClipboard = { [weak self] in self?.model.showsClipboard = true }
        // The row shows "Copied" for a moment (ClipboardRow), then the card closes.
        model.clipboardCopy = { [weak self] item in
            ClipboardHistory.copy(item)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.model.collapsePinnedCard()
            }
        }
        // The panel never takes focus, so the app the user was typing in is still frontmost.
        // Without Accessibility the text stays on the clipboard and the system prompt opens,
        // so Insert never silently does nothing.
        model.clipboardInsert = { [weak self] item in
            self?.model.collapsePinnedCard()
            ClipboardHistory.copy(item)
            guard TextInsertionService.isTrusted else {
                TextInsertionService.requestPermission()
                return
            }
            Task {
                switch item.content {
                case .text(let text): try? await TextInsertionService.insertAtCursor(text, trimming: false)
                case .image(let image): try? await TextInsertionService.insertImageAtCursor(image.data, type: image.type)
                }
            }
        }
        model.dismissCoach = { [weak self] in
            guard let self else { return }
            self.model.showsCoach = false
            self.coachDismissed()
            self.applyVisibility()
        }
        model.projectWheelPick = { [weak self] index in self?.onProjectWheelPick(index) }
        model.presentationChanged = { [weak self] in self?.applyVisibility() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resizeIfVisible() }
        }
    }

    // MARK: - Companion

    // MARK: - Voice assistant

    /// Shows an assistant card; a DONE card goes away after 8 s unless hovered.
    func showAssistant(_ card: AssistantCard) {
        model.assistant = card
        if case .ask = card { model.askDraft = "" }
        announce({
            switch card {
            case .answer: return "Claude's answer is ready"
            case .done(let summary, _): return "Done: \(summary)"
            case .ask(let question): return "Claude asks: \(question)"
            case .failed(let message): return message
            }
        }())
        applyVisibility()
        resizeIfVisible()
        assistantDismissTask?.cancel()
        guard case .done = card else { return }
        assistantDismissTask = Task { [weak self] in
            var left = 8
            while left > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if !self.pointerHolds() { left -= 1 }
            }
            self?.clearAssistant()
        }
    }

    func clearAssistant() {
        assistantDismissTask?.cancel()
        model.assistant = nil
        model.askDraft = ""
        applyVisibility()
        resizeIfVisible()
    }

    // MARK: - Project wheel

    /// Shows or updates the project list scrolled over the companion.
    func showProjectWheel(_ card: ProjectWheelCard) {
        let opening = model.projectWheel == nil
        model.projectWheel = card
        if opening { updateEscapeMonitor() }
        if opening {
            announce("Project for this recording: \(card.wheel.selected?.name ?? "")")
            applyVisibility()
        } else if card.committed {
            announce("Recording files to \(card.wheel.selected?.name ?? "")")
        }
        resizeIfVisible()
    }

    func hideProjectWheel() {
        guard model.projectWheel != nil else { return }
        model.projectWheel = nil
        applyVisibility()
        resizeIfVisible()
        updateEscapeMonitor()
    }

    func setAssistantWorking(_ working: Bool) {
        model.assistantWorking = working
    }

    /// Only an ASK card takes the keyboard (the panel never activates the app).
    private func updateKeyFocus() {
        guard let panel = panel as? PillPanel else { return }
        var asking = false
        if case .ask = model.assistant { asking = true }
        // A chat card with a reply field may take the keyboard when clicked, never by itself:
        // a notice must not pull typing away from the app the user is in.
        panel.allowsKey = asking || model.notice?.request?.takesReply == true
        if asking, panel.isVisible { panel.makeKey() } else if panel.isKeyWindow { panel.resignKey() }
    }

    /// Whether a popup (or the pill) is on screen; the companion hides its bubble meanwhile.
    var isPanelVisible: Bool { panel?.isVisible == true }

    /// The companion appeared, disappeared or moved: switch modes and re-place what shows.
    func companionChanged() {
        let active = companionAnchor() != nil
        if model.companionMode != active {
            model.companionMode = active
            model.idleExpanded = false
            applyVisibility()
        } else {
            resizeIfVisible()
        }
    }

    /// The creature moved (dragged): follow it without the resize settle.
    func companionMoved() {
        guard let panel, panel.isVisible else { return }
        place(panel, size: panel.frame.size)
    }

    /// The pointer entered or left the creature. Hovering opens nothing (user decision
    /// 2026-10-13: cards open on a click, the rest is driven by the dictation key); it holds
    /// countdowns, and a card opened by a click closes 6 s after the pointer left.
    func companionHover(_ inside: Bool) {
        guard model.cardPinned, model.dictation == nil else {
            model.isHovering = inside
            return
        }
        switch model.state {
        case .hidden: model.hoverIdle(inside, intent: 0)
        case .dot: model.hoverDot(inside, intent: 0)
        case .recording: model.hoverRecording(inside, intent: 0)
        default: model.isHovering = inside
        }
    }

    /// A click on the creature opens (or closes) its card.
    func companionClick() {
        if model.showsCoach { model.dismissCoach() }
        guard model.dictation == nil else { return }
        model.togglePinnedCard()
    }

    func collapseCompanionCard() {
        model.collapsePinnedCard()
    }

    /// The one-time card explaining the creature; `onDismiss` runs when the user closes it.
    func showCoach(onDismiss: @escaping () -> Void) {
        guard !model.showsCoach else { return }
        coachDismissed = onDismiss
        model.showsCoach = true
        applyVisibility()
        resizeIfVisible()
    }

    /// A note about a Claude session beside the creature for about seven seconds (held while
    /// hovered). Only shown when the pill has nothing more important up; a done notice never
    /// replaces one about a session that waits or failed.
    func showNotice(_ row: CompanionSessionRow, force: Bool = false) {
        if !force, row.kind == .done, let current = model.notice, current.kind != .done { return }
        // A reply being typed for another session stays until it is sent or closed.
        if !force, let current = model.notice, current.id != row.id, !model.sessionDraft.isEmpty { return }
        if model.notice?.id != row.id { model.sessionDraft = "" }
        model.notice = row
        announce("\(row.headline), \(row.project)", priority: row.kind == .done ? .medium : .high)
        applyVisibility()
        resizeIfVisible()
        noticeTask?.cancel()
        // A chat card gives time to read; hovering or a started reply holds it (NoticeCountdown).
        let seconds = row.request == nil ? 7 : (row.kind == .done ? 15 : 30)
        noticeTask = Task { [weak self] in
            var countdown = NoticeCountdown(seconds: seconds)
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let expired = countdown.tick(
                    hovering: self.pointerHolds(), typing: !self.model.sessionDraft.isEmpty,
                    focused: self.panel?.isKeyWindow == true)
                if expired { break }
            }
            self?.clearNotice()
        }
    }

    func clearNotice() {
        noticeTask?.cancel()
        guard model.notice != nil else { return }
        model.notice = nil
        applyVisibility()
        resizeIfVisible()
    }

    func setAttentionRows(_ rows: [CompanionSessionRow]) {
        guard model.attentionRows != rows else { return }
        model.attentionRows = rows
        resizeIfVisible()
    }

    /// In companion mode only what needs the user opens by itself; the idle popup, the ignored
    /// meeting and the running recording open on hover.
    private var companionWantsPanel: Bool {
        switch model.state {
        case .hidden: return model.idleExpanded || model.notice != nil || model.showsCoach
        case .dot: return model.dotExpanded || model.notice != nil
        case .recording: return model.showsRecordingControls || model.hintFlashing || model.notice != nil
        default: return true
        }
    }

    // MARK: - Idle bar and dictation

    /// Turns the idle bar on or off and sets the dictation hint it shows on hover.
    func configureIdleBar(enabled: Bool, dictationHint: String?) {
        model.dictationHint = dictationHint
        guard model.idleBarEnabled != enabled else { return }
        model.idleBarEnabled = enabled
        applyVisibility()
    }

    /// Quick dictation started: the pill becomes the dictation capsule. `levelProvider` is the
    /// microphone level of the dictation engine, `liveProvider` whether that microphone delivers
    /// sound yet. `claude` starts a Claude mini task instead.
    func dictationStarted(
        claude: Bool = false, levelProvider: @escaping () -> Float,
        liveProvider: @escaping () -> Bool = { false }
    ) {
        model.dictationLevels = Array(repeating: 0, count: MeetingPillModel.waveSamples)
        model.dictationMicLive = false
        model.dictationMicStalled = false
        model.idleExpanded = false
        if model.dictation == nil { dictationUsesIdleAnchor = model.state == .hidden }
        model.dictation = claude ? .claudeListening : .listening(text: "")
        dictationLevelProvider = levelProvider
        dictationLiveProvider = liveProvider
        dictationWaitingSince = Date()
        dictationTimer?.invalidate()
        dictationTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.dictation != nil else { return }
                var levels = self.model.dictationLevels
                levels.removeFirst()
                levels.append(self.dictationLevelProvider())
                self.model.dictationLevels = levels
                self.followDictationMicrophone()
            }
        }
        applyVisibility()
    }

    /// "Listening" is announced (and shown) only once the microphone delivers sound; a device
    /// change that restarts the microphone puts the capsule back to waiting.
    private func followDictationMicrophone() {
        switch model.dictation {
        case .listening, .claudeListening: break
        default: return
        }
        let live = dictationLiveProvider()
        if live != model.dictationMicLive {
            model.dictationMicLive = live
            if live {
                model.dictationMicStalled = false
                announce(model.dictation == .claudeListening ? "Claude is listening" : "Listening")
            } else {
                dictationWaitingSince = Date()
            }
        }
        if !live, !model.dictationMicStalled,
           Date().timeIntervalSince(dictationWaitingSince) >= Self.micStallDelay {
            model.dictationMicStalled = true
            announce("Microphone not ready")
        }
    }

    /// The spoken task went to Claude; the bars run flat while it works.
    func claudeWorking() {
        dictationLevelProvider = { 0 }
        model.dictation = .claudeWorking
        announce("Claude is working")
    }

    /// Claude's answer is on the clipboard (or the task failed): say so, then step aside.
    func claudeFinished(error: String? = nil) {
        dictationTimer?.invalidate()
        dictationTimer = nil
        let shown: MeetingPillModel.Dictation = error.map { .claudeFailed($0) } ?? .claudeCopied
        model.dictation = shown
        announce(error == nil ? "Claude's answer copied" : "Claude task failed")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(error == nil ? 2500 : 4000))
            // Only clear what this call put up; a new dictation may have started meanwhile.
            guard let self, self.model.dictation == shown else { return }
            self.dictationEnded()
        }
    }

    func dictationText(_ text: String) {
        guard case .listening = model.dictation else { return }
        model.dictation = .listening(text: text)
    }

    /// The microphone is off: keep the waveform timer running on silence so the bars run flat.
    func dictationInserting() {
        dictationLevelProvider = { 0 }
        model.dictation = .inserting
    }

    /// Pasted: the capsule shrinks back into the idle bar (or the meeting state) at once. When the
    /// text went to the clipboard instead, say so for 1.5 s first.
    func dictationFinished(copied: Bool) {
        guard copied else {
            dictationEnded()
            return
        }
        dictationTimer?.invalidate()
        dictationTimer = nil
        model.dictation = .done(copied: true)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, case .done = self.model.dictation else { return }
            self.dictationEnded()
        }
    }

    func dictationEnded() {
        dictationTimer?.invalidate()
        dictationTimer = nil
        model.dictation = nil
        model.isHovering = false
        applyVisibility()
    }

    // MARK: - Events from the app

    func meetingDetected(_ meeting: PillMeeting) {
        guard dismissedMeeting != meeting else { return }
        guard case .hidden = model.state else {
            // Back-to-back meetings: keep it and offer it as soon as the current card is gone.
            pendingMeeting = meeting
            return
        }
        // After 10 s (paused while hovered) the card shrinks to the ring.
        runCountdown(from: 10, state: { _ in .detected(meeting) }) { [weak self] in
            guard let self, case .detected(let current) = self.model.state, current == meeting else { return }
            self.setState(.dot(meeting))
        }
        announce("Meeting detected: \(meeting.title). Record?")
    }

    /// The call ended without a recording: drop any prompt for it.
    func meetingEnded() {
        dismissedMeeting = nil
        pendingMeeting = nil
        switch model.state {
        case .detected, .dot, .consent:
            countdownTask?.cancel()
            setState(.hidden)
        default: break
        }
    }

    func recordingStarted(at date: Date, stopHint: String? = nil) {
        // The first few recordings tell how to pick the project by scrolling over the companion.
        let hintCount = UserDefaults.standard.integer(forKey: Self.wheelHintCountKey)
        model.showsWheelHint = hintCount < 3
        if model.showsWheelHint { UserDefaults.standard.set(hintCount + 1, forKey: Self.wheelHintCountKey) }
        countdownTask?.cancel()
        model.recordingStartedAt = date
        model.recordingStopHint = stopHint
        setState(.recording)
        announce("Recording started")
        startLevelTimer()
        // Beside the companion the capsule only opens on hover: show it for 3 s as confirmation
        // (a hotkey or a double tap gives no other sign that the recording started).
        if model.companionMode { flashCapsule(seconds: 3) }
    }

    /// Long silence or the call app letting go of the mic: ask whether the meeting is over. The
    /// recording keeps running until the user answers Stop.
    func askIfMeetingEnded(_ signal: MeetingPillModel.EndSignal) {
        guard case .recording = model.state else { return }
        countdownTask?.cancel()
        setState(.confirmStop(signal))
        announce("Meeting over? Recording continues until you stop it")
        if isScreenSharing { notifyMeetingOver() }
    }

    /// A short note in the recording capsule's hint slot for 1.5 s (e.g. "Already recording"
    /// after a double tap while a meeting records), then the previous hint returns.
    func flashRecordingHint(_ text: String) {
        guard case .recording = model.state else { return }
        let previous = model.recordingStopHint
        model.recordingStopHint = text
        flashCapsule(seconds: 1.5)
        announce(text)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.model.recordingStopHint == text else { return }
            self.model.recordingStopHint = previous
        }
    }

    /// Shows the recording capsule beside the companion for a moment without hover.
    private func flashCapsule(seconds: Double) {
        model.hintFlashing = true
        applyVisibility()
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.model.hintFlashing = false
            self.applyVisibility()
        }
    }

    /// A recording too short to keep (an accidental quick recording) was deleted: the capsule
    /// shrinks back into the idle bar, no saved card.
    func recordingDiscarded() {
        levelTimer?.invalidate()
        levelTimer = nil
        countdownTask?.cancel()
        model.recordingStartedAt = nil
        model.recordingStopHint = nil
        announce("Too short, recording discarded")
        setState(.hidden)
    }

    func recordingStopped(sessionID: UUID, title: String, duration: TimeInterval, next: MeetingPillModel.SavedNext) {
        levelTimer?.invalidate()
        levelTimer = nil
        model.recordingStartedAt = nil
        model.recordingStopHint = nil
        let minutes = max(1, Int((duration / 60).rounded()))
        // Filed to a Shared Project already: the card asks whether to publish it.
        let next = next.askingToPublish(sharedProject: sharedProjectOfSession(sessionID))
        if next.asksForProject {
            announce("\(title) saved. Which project?")
        } else if case .publish(let project, _, _, _) = next {
            announce("\(title) saved. \(MeetingPillModel.SavedNext.publishQuestion(project))")
        } else {
            announce("\(title) saved")
        }
        // A question waits longer than a note; hovering holds both.
        let seconds = next.waitsForAnswer ? 30 : 15
        runCountdown(from: seconds, state: { .saved(sessionID: sessionID, title: title, minutes: minutes, next: next, secondsLeft: $0) }) { [weak self] in
            self?.finishSaved { self?.onLater(sessionID) }
        }
    }

    /// The recording the saved card is about, while it shows.
    var savedSessionID: UUID? {
        if case .saved(let sessionID, _, _, _, _) = model.state { return sessionID }
        return nil
    }

    /// Whether the saved card is asking which project its recording belongs to.
    var savedAsksForProject: Bool {
        if case .saved(_, _, _, let next, _) = model.state { return next.asksForProject }
        return false
    }

    /// The panel's frame while it shows, for telling whether the pointer is over a card.
    var panelFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    /// Whether the pointer really is on the card or the creature, for the countdowns. A hover
    /// flag left over from a card that went away under the pointer (no hover exit arrives then,
    /// see PillHover) is cleared here, so it can never hold a card for good.
    private func pointerHolds() -> Bool {
        let areas = [panelFrame, companionAnchor()].compactMap { $0 }
        let real = PillHover.isReal(flag: model.isHovering, pointer: NSEvent.mouseLocation, areas: areas)
        if model.isHovering, !real { model.isHovering = false }
        return real
    }

    /// A project was picked on the saved card (or in the wheel opened from it): file it, then
    /// confirm for a moment with Change still at hand, or offer Process Now when automatic
    /// processing is off. A Shared Project turns the card into the publish question instead,
    /// with a fresh 30 s countdown (also when Change picks another Shared Project).
    func projectChosen(_ sessionID: UUID, _ item: ProjectWheel.Item) {
        guard let projectID = item.projectID else { return }
        onChooseProject(sessionID, projectID)
        guard case .saved(let current, let title, let minutes, let next, _) = model.state, current == sessionID else { return }
        let picked = next.picking(item.name, shared: isSharedProject(projectID))
        if case .publish = picked {
            announce("Filed to \(item.name). \(MeetingPillModel.SavedNext.publishQuestion(item.name))")
            runCountdown(from: 30, state: { .saved(sessionID: sessionID, title: title, minutes: minutes, next: picked, secondsLeft: $0) }) { [weak self] in
                self?.finishSaved { self?.onLater(sessionID) }
            }
            return
        }
        announce("Filed to \(item.name)")
        runCountdown(from: 5, state: { .saved(sessionID: sessionID, title: title, minutes: minutes, next: picked, secondsLeft: $0) }) { [weak self] in
            self?.finishSaved {}
        }
    }

    /// Publish or Keep private on the saved card. Then it closes like OK, or (automatic
    /// processing off) offers Process Now as the card does without the question.
    func publicationAnswered(_ sessionID: UUID, _ publication: MeetingPublication) {
        guard case .saved(let current, let title, let minutes, let next, _) = model.state, current == sessionID,
              case .publish(let project, _, _, _) = next else { return }
        onSetPublication(sessionID, publication)
        announce(publication == .published ? "Shared with the \(project) team" : "Kept private")
        countdownTask?.cancel()
        guard let after = next.afterPublishAnswer else {
            setState(.hidden)
            return
        }
        runCountdown(from: 15, state: { .saved(sessionID: sessionID, title: title, minutes: minutes, next: after, secondsLeft: $0) }) { [weak self] in
            self?.finishSaved { self?.onLater(sessionID) }
        }
    }

    /// The project wheel filed the saved recording: its own confirmation replaces the card.
    func endSaved(for sessionID: UUID) {
        guard savedSessionID == sessionID else { return }
        finishSaved {}
    }

    /// Later from the project wheel: like the card's Later button.
    func laterSaved(for sessionID: UUID) {
        guard savedSessionID == sessionID else { return }
        finishSaved { onLater(sessionID) }
    }

    // MARK: - Escape

    /// Escape while the saved card or the project wheel shows and the pointer is on it or on the
    /// creature. The panel never takes the keyboard, so a key monitor watches for it, only while
    /// one of them is up (global for other apps, local for MinuteMind's own windows; the key
    /// still reaches the app in front). It closes an open wheel, then answers the saved card:
    /// Later while it asks for a project, OK once it is filed, Keep private (and close) while it
    /// asks to publish (user request 2026-10-28: "click escape, it's like pressing later").
    private var escapeMonitors: [Any] = []

    private func updateEscapeMonitor() {
        var wanted = model.projectWheel != nil
        if case .saved = model.state { wanted = true }
        if wanted == !escapeMonitors.isEmpty { return }
        if wanted {
            let handle: (NSEvent) -> Void = { [weak self] event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor in self?.escapePressed() }
            }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handle) {
                escapeMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
                handle(event)
                return event
            }) {
                escapeMonitors.append(local)
            }
        } else {
            escapeMonitors.forEach(NSEvent.removeMonitor)
            escapeMonitors = []
        }
    }

    private func escapePressed() {
        // Only while the pointer is on the card or the creature: Escape in another app (stopping
        // Claude in a terminal, closing a dialog) must not answer the card.
        let mouse = NSEvent.mouseLocation
        let onCard = panelFrame?.contains(mouse) == true || companionAnchor()?.contains(mouse) == true
        guard onCard else { return }
        if model.projectWheel?.committed == false { onWheelEscape() }
        guard case .saved(let sessionID, _, _, let next, _) = model.state else { return }
        if next.asksForProject { model.later(sessionID) } else { model.dismissSaved() }
    }

    func screenSharingChanged(_ sharing: Bool) {
        isScreenSharing = sharing
        applyVisibility()
    }

    // MARK: - Recording the offered meeting

    /// Records the meeting the pill offers, if any. Returns false when the pill has nothing to
    /// record, so the caller falls back to a plain start.
    func recordOfferedMeeting() -> Bool {
        switch model.state {
        case .detected(let meeting), .dot(let meeting): recordTapped(meeting); return true
        case .consent(let meeting): model.confirmConsent(meeting); return true
        default: return false
        }
    }

    // MARK: - Actions

    private func recordTapped(_ meeting: PillMeeting) {
        countdownTask?.cancel()
        if UserDefaults.standard.bool(forKey: Self.consentKey) {
            onRecord(meeting)
        } else {
            setState(.consent(meeting))
        }
    }

    private func ignoreTapped() {
        countdownTask?.cancel()
        switch model.state {
        case .detected(let meeting), .dot(let meeting), .consent(let meeting):
            dismissedMeeting = meeting
        default: break
        }
        setState(.hidden)
    }

    private func keepRecordingTapped() {
        countdownTask?.cancel()
        setState(.recording)
    }

    /// Closes the saved card. Closed while it asks to publish (no answer in 30 s, Escape, Later)
    /// the recording stays private, said explicitly so it is filed under private/.
    private func finishSaved(_ action: () -> Void) {
        countdownTask?.cancel()
        if case .saved(let sessionID, _, _, let next, _) = model.state, let unanswered = next.unansweredPublication {
            onSetPublication(sessionID, unanswered)
        }
        setState(.hidden)
        action()
    }

    /// Counts down once per second, pausing while hovered and resuming with at least 3 s left.
    private func runCountdown(from seconds: Int, state: @escaping (Int) -> MeetingPillModel.State, onExpire: @escaping () -> Void) {
        countdownTask?.cancel()
        setState(state(seconds))
        model.countdownProgress = 1
        countdownTask = Task { [weak self] in
            var left = seconds
            var wasHovering = false
            while left > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                // Clears a hover flag the pointer left behind, so only a real hover holds.
                _ = self.pointerHolds()
                if self.model.holdsCountdown {
                    wasHovering = true
                    continue
                }
                if wasHovering {
                    wasHovering = false
                    left = max(left, 3)
                }
                left -= 1
                self.model.state = state(left)
                self.model.countdownProgress = Double(left) / Double(seconds)
            }
            guard !Task.isCancelled else { return }
            onExpire()
        }
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.level = self.levelProvider()
            }
        }
    }

    // MARK: - Presentation

    private func setState(_ state: MeetingPillModel.State) {
        defer { updateEscapeMonitor() }
        let kindChanged = state.kind != model.state.kind
        model.state = state
        if kindChanged {
            model.isHovering = false
            model.showsRecordingControls = false
            model.dotExpanded = false
            model.idleExpanded = false
        }
        if case .hidden = state {
            pinnedScreen = nil
            if let pending = pendingMeeting {
                pendingMeeting = nil
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    self?.meetingDetected(pending)
                }
            }
        }
        applyVisibility()
    }

    private func applyVisibility() {
        defer {
            updateScreenFollow()
            updateKeyFocus()
            onPanelVisibilityChanged()
        }
        // An assistant card or the project wheel shows in every mode (beside the companion or at the bottom centre).
        if model.dictation == nil, model.assistant != nil || model.projectWheel != nil {
            removeStatusItem()
            showPanel()
            return
        }
        // Dictation always shows the pill, even while sharing: the user needs to see it listen,
        // and the old dictation HUD behaved the same.
        if model.dictation != nil {
            removeStatusItem()
            showPanel()
            return
        }
        // Companion mode never applies during a screen share (the anchor is nil then, even when
        // the creature stays visible), so no menu bar item is needed here.
        if model.companionMode {
            removeStatusItem()
            if companionWantsPanel { showPanel() } else { panel?.orderOut(nil) }
            return
        }
        if model.state == .hidden {
            removeStatusItem()
            if model.idleBarEnabled && !isScreenSharing {
                showPanel()
            } else {
                panel?.orderOut(nil)
                pinnedScreen = nil
            }
            return
        }
        if isScreenSharing {
            panel?.orderOut(nil)
            showStatusItem()
            return
        }
        removeStatusItem()
        showPanel()
    }

    /// Runs the screen-follow poll only while the idle bar is what the pill shows.
    private func updateScreenFollow() {
        let idleBarShowing = !model.companionMode && model.state == .hidden && model.dictation == nil
            && panel?.isVisible == true
        guard idleBarShowing else {
            screenFollowTimer?.invalidate()
            screenFollowTimer = nil
            followCandidate = nil
            followTicks = 0
            return
        }
        guard screenFollowTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followMouseScreen() }
        }
        timer.tolerance = 0.1
        screenFollowTimer = timer
    }

    /// Moves the idle bar to the mouse screen after the pointer stayed there for two ticks.
    private func followMouseScreen() {
        guard let panel, panel.isVisible, model.state == .hidden, model.dictation == nil,
              !model.isHovering else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        guard screen != pinnedScreen else {
            followCandidate = nil
            followTicks = 0
            return
        }
        if screen == followCandidate {
            followTicks += 1
        } else {
            followCandidate = screen
            followTicks = 1
        }
        guard followTicks >= 2 else { return }
        followCandidate = nil
        followTicks = 0
        place(panel, size: panel.frame.size)
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        resizeAndPosition(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = PillPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The SwiftUI content draws its own soft shadow; a window shadow would add a dark ring.
        panel.hasShadow = false
        panel.sharingType = .none
        #if DEBUG
        if captureVisibleForDemo { panel.sharingType = .readOnly }
        #endif
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.scrollHandler = { [weak self] event in self?.onScrollOverPanel(event) ?? false }

        let hosting = NSHostingView(rootView: AnyView(
            MeetingPillView(model: model, onSizeChange: { [weak self] in self?.resizeIfVisible() })))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        hostingView = hosting
        return panel
    }

    private func resizeIfVisible() {
        guard let panel, panel.isVisible else { return }
        resizeAndPosition(panel)
    }

    /// Grows at once, shrinks only after the SwiftUI transition finished, so outgoing content and
    /// its shadow are never clipped, then settles on the exact size.
    private func resizeAndPosition(_ panel: NSPanel) {
        guard let hostingView else { return }
        let fitting = hostingView.fittingSize
        let current = panel.isVisible ? panel.frame.size : .zero
        let grown = NSSize(width: max(fitting.width, current.width), height: max(fitting.height, current.height))
        place(panel, size: panel.isVisible ? grown : fitting)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, let panel = self.panel, panel.isVisible, let hostingView = self.hostingView else { return }
            self.place(panel, size: hostingView.fittingSize)
        }
    }

    private func place(_ panel: NSPanel, size: NSSize) {
        if model.companionMode, let creature = companionAnchor() {
            placeBesideCompanion(panel, size: size, creature: creature)
            return
        }
        // The idle bar follows the mouse screen between meetings; anything else stays pinned.
        if model.state == .hidden && model.dictation == nil && !model.isHovering {
            pinnedScreen = nil
        }
        if pinnedScreen == nil {
            let mouse = NSEvent.mouseLocation
            pinnedScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        }
        let screen = pinnedScreen.flatMap { NSScreen.screens.contains($0) ? $0 : nil } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        // 40 pt of clearance for the visible pill, minus the 24 pt shadow padding at the bottom.
        // When only the hover changed, keep the left edge so content does not slide under the
        // pointer; state changes re-center.
        // The idle bar and the dictation capsule grow from the center, so they always re-center.
        let kind = model.displayKind
        let centered = model.dictation != nil || model.state == .hidden
        let keepLeft = !centered && kind == lastLayoutKind && panel.isVisible && model.isHovering
        lastLayoutKind = kind
        let x = keepLeft ? panel.frame.minX : frame.midX - size.width / 2
        let idleAnchor = model.dictation == nil ? model.state == .hidden : dictationUsesIdleAnchor
        let clearance = idleAnchor ? MeetingPillView.idleBottomClearance : MeetingPillView.bottomClearance
        let y = frame.minY + clearance - MeetingPillView.insets(for: model).bottom
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    /// Beside the creature, on the side with more room, centred on it vertically.
    private func placeBesideCompanion(_ panel: NSPanel, size: NSSize, creature: NSRect) {
        let center = NSPoint(x: creature.midX, y: creature.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let opensLeft = CompanionPlacement.opensLeft(creature: creature, in: visible)
        if model.opensLeft != opensLeft { model.opensLeft = opensLeft }
        let insets = MeetingPillView.insets(for: model)
        let origin = CompanionPlacement.popupOrigin(
            creature: creature, popupSize: size,
            insets: (insets.top, insets.leading, insets.bottom, insets.trailing), in: visible)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func announce(_ text: String, priority: NSAccessibilityPriorityLevel = .high) {
        // Posted on the app element: the panel may not exist yet on the first state change.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: priority.rawValue,
        ])
    }

    // MARK: - Menu bar item (while sharing)

    private func showStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateStatusItem() }
            }
        }
        updateStatusItem()
    }

    private func removeStatusItem() {
        statusTimer?.invalidate()
        statusTimer = nil
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    /// Mirrors the pill: title and menu follow the current state.
    private func updateStatusItem() {
        guard let item = statusItem, let button = item.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusActions.handlers = [:]
        func add(_ title: String, _ action: (() -> Void)? = nil) {
            let entry = NSMenuItem(title: title, action: #selector(StatusActions.run(_:)), keyEquivalent: "")
            entry.target = statusActions
            entry.isEnabled = action != nil
            entry.tag = menu.items.count
            if let action { statusActions.handlers[entry.tag] = action }
            menu.addItem(entry)
        }

        let symbol: String
        var title = ""
        var red = false
        switch model.state {
        case .hidden:
            return
        case .detected(let meeting), .dot(let meeting), .consent(let meeting):
            symbol = "record.circle"
            add("Record \(PillMeeting.displayTitle(meeting.title))") { [weak self] in self?.recordTapped(meeting) }
            add("Not Now") { [weak self] in self?.ignoreTapped() }
        case .recording:
            symbol = "record.circle.fill"; red = true
            title = MeetingPillView.format(model.elapsed)
            add("Recording")
            add("Stop Recording") { [weak self] in self?.onStop() }
            add("Open MinuteMind") { [weak self] in self?.onOpenApp() }
        case .confirmStop:
            symbol = "record.circle.fill"; red = true
            title = "Meeting over?"
            add("Keep Recording") { [weak self] in self?.keepRecordingTapped() }
            add("Stop Recording") { [weak self] in self?.onStop() }
        case .saved(let sessionID, let meetingTitle, _, let next, _):
            symbol = "checkmark.circle"
            add("\(PillMeeting.displayTitle(meetingTitle)) saved")
            add(next.hint)
            /// A submenu of every project; picking one files the recording.
            func projects(_ title: String, _ items: [ProjectWheel.Item]) {
                guard !items.isEmpty else { return }
                let submenu = NSMenu()
                for item in items {
                    let entry = NSMenuItem(title: item.name, action: #selector(StatusActions.run(_:)), keyEquivalent: "")
                    entry.target = statusActions
                    entry.tag = 1000 + submenu.items.count + 100 * menu.items.count
                    statusActions.handlers[entry.tag] = { [weak self] in self?.model.chooseProject(sessionID, item) }
                    submenu.addItem(entry)
                }
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.submenu = submenu
                menu.addItem(parent)
            }
            switch next {
            case .chooseProject(let quick, let all, _):
                for item in quick {
                    add("File to \(item.name)") { [weak self] in self?.model.chooseProject(sessionID, item) }
                }
                projects("Other Project", all)
                add("Open Inbox") { [weak self] in self?.model.openInbox(sessionID) }
                add("Later") { [weak self] in self?.model.later(sessionID) }
            case .filed(_, let all):
                projects("Change Project", all)
                add("OK") { [weak self] in self?.model.dismissSaved() }
            case .manual:
                add("Process Now") { [weak self] in self?.model.process(sessionID) }
                add("Later") { [weak self] in self?.model.later(sessionID) }
            case .publish(let project, let alreadyFiled, let all, _):
                if alreadyFiled { add(MeetingPillModel.SavedNext.publishQuestion(project)) }
                add("Publish") { [weak self] in self?.model.answerPublication(sessionID, .published) }
                add("Keep private") { [weak self] in self?.model.answerPublication(sessionID, .keptPrivate) }
                if alreadyFiled { projects("Change Project", all) }
            }
        }
        item.menu = menu

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if red, let image {
            button.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        } else {
            image?.isTemplate = true
            button.image = image
        }
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.attributedTitle = NSAttributedString(string: title.isEmpty ? "" : " \(title)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    }

    /// A menu bar title change is easy to miss while presenting, so also post a notification.
    private func notifyMeetingOver() {
        let content = UNMutableNotificationContent()
        content.title = "Meeting over?"
        content.body = "MinuteMind keeps recording until you stop it. Use the menu bar item to stop."
        let request = UNNotificationRequest(identifier: "mm.pill.meeting-over", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    #if DEBUG
    /// Debug aid: MM_PILL_DEMO=1 walks through every state so the pill can be checked by eye.
    /// MM_PILL_DEMO=visible also lets screenshots capture it (normally excluded from capture).
    func runDemoIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["MM_PILL_DEMO"] else { return }
        captureVisibleForDemo = mode == "visible"
        // The idle bar may have created the panel already, before this flag was set.
        if captureVisibleForDemo { panel?.sharingType = .readOnly }
        let meeting = PillMeeting(title: "FW: Weekly Sync", subtitle: "Microsoft Teams \u{00B7} 10:00 to 10:30", appBundleID: "com.microsoft.teams2", calendarEventID: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            configureIdleBar(enabled: true, dictationHint: "Hold fn to dictate"); try? await Task.sleep(for: .seconds(3))
            model.idleExpanded = true; resizeIfVisible(); try? await Task.sleep(for: .seconds(3))
            model.idleExpanded = false
            var phase = 0.0
            // The first dictation waits for its microphone like AirPods do, the later ones not.
            let micLiveAt = Date().addingTimeInterval(1.2)
            dictationStarted(
                levelProvider: { phase += 0.7; return Float(0.02 + 0.03 * (1 + sin(phase))) },
                liveProvider: { Date() >= micLiveAt })
            try? await Task.sleep(for: .seconds(3))
            dictationText("Can you send me the slides from the kickoff by Friday")
            try? await Task.sleep(for: .seconds(3))
            dictationInserting(); try? await Task.sleep(for: .seconds(2))
            dictationFinished(copied: false); try? await Task.sleep(for: .seconds(2))
            dictationStarted(claude: true, levelProvider: { phase += 0.7; return Float(0.02 + 0.03 * (1 + sin(phase))) }, liveProvider: { true })
            try? await Task.sleep(for: .seconds(3))
            claudeWorking(); try? await Task.sleep(for: .seconds(2))
            claudeFinished(); try? await Task.sleep(for: .seconds(3))
            setState(.detected(meeting)); try? await Task.sleep(for: .seconds(3))
            setState(.dot(meeting)); try? await Task.sleep(for: .seconds(3))
            model.dotExpanded = true; try? await Task.sleep(for: .seconds(3))
            setState(.consent(meeting)); try? await Task.sleep(for: .seconds(3))
            model.recordingStartedAt = Date().addingTimeInterval(-754)
            setState(.recording); startLevelTimer(); try? await Task.sleep(for: .seconds(3))
            model.showsRecordingControls = true; try? await Task.sleep(for: .seconds(3))
            dictationStarted(levelProvider: { phase += 0.7; return Float(0.02 + 0.03 * (1 + sin(phase))) }, liveProvider: { true })
            dictationText("Note: follow up with legal on the contract")
            try? await Task.sleep(for: .seconds(3))
            dictationEnded(); try? await Task.sleep(for: .seconds(1))
            levelTimer?.invalidate()
            setState(.confirmStop(.silence(180))); try? await Task.sleep(for: .seconds(3))
            setState(.saved(sessionID: UUID(), title: "Weekly Sync", minutes: 32, next: .chooseProject(quick: [.init(projectID: UUID(), name: "Acme", avatar: .duck), .init(projectID: UUID(), name: "Phoenix", avatar: .lime)], all: [], processes: true), secondsLeft: 9))
            model.countdownProgress = 0.6
            try? await Task.sleep(for: .seconds(3))
            // Shared Projects: filed to one already, then picked on the card.
            setState(.saved(sessionID: UUID(), title: "Weekly Sync", minutes: 32, next: .publish(project: "Acme", alreadyFiled: true, all: [], processes: true), secondsLeft: 24))
            model.countdownProgress = 0.8
            try? await Task.sleep(for: .seconds(3))
            setState(.saved(sessionID: UUID(), title: "Weekly Sync", minutes: 32, next: .publish(project: "Acme", alreadyFiled: false, all: [], processes: true), secondsLeft: 24))
            model.countdownProgress = 0.8
            try? await Task.sleep(for: .seconds(3))
            setState(.hidden)
        }
    }

    private var captureVisibleForDemo = false
    #endif
}

/// Target for the menu bar item's menu entries.
private final class StatusActions: NSObject {
    var handlers: [Int: () -> Void] = [:]
    @objc func run(_ sender: NSMenuItem) { handlers[sender.tag]?() }
}

/// Never becomes key, so a click on the pill leaves focus in the call app; only while the
/// assistant asks something it takes the keyboard for the answer field.
private final class PillPanel: NSPanel {
    var allowsKey = false
    /// Scrolls over the panel go here first (the project wheel); true when taken.
    var scrollHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, scrollHandler?(event) == true { return }
        super.sendEvent(event)
    }
}
