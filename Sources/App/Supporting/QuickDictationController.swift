// Purpose: Orchestrates global quick dictation: hotkey pressed, microphone listens, text is
//          pasted at the cursor of whatever app is frontmost. The Wispr Flow style flow. Holding
//          the hold key with Control calls the voice assistant instead (ClaudeAssistantService):
//          the spoken request, with any selected text, goes to Claude, which acts with its tools
//          or hands text back. A double tap starts a quick recording, which the next press stops.
// Dependencies: Sources/App/Services/QuickDictationService.swift (recognition),
//               Sources/App/Services/TextInsertionService.swift (paste at cursor),
//               Sources/App/Services/ClaudeTaskService.swift (chat links),
//               Sources/App/Services/ClaudeAssistantService.swift (voice assistant runs),
//               Sources/App/Supporting/SelectionCapture.swift (selected text, editable cursor),
//               Sources/App/Supporting/MeetingPillController.swift (the shared pill shows dictation),
//               Sources/App/Config/AutomationSettings.swift (enabled / mode / language / Claude task),
//               Sources/App/Store/DictationHistoryStore.swift (every result is kept for the Clipboard).
// Used by: Sources/App/MinuteMindApp.swift (AppDelegate wires the hotkeys)
// Notes: Two interaction modes, mirroring what dictation tools converge on:
//        - toggle: press the hotkey to start, press again to insert
//        - push-to-talk: hold the hotkey, release to insert
//        Accessibility permission is checked up front, because without it we can capture audio but
//        never deliver the text — better to prompt immediately than to dictate into the void.
//        Feedback lives in the meeting pill (2026-10-04, user decision): one floating surface for
//        dictation and meetings, like Wispr Flow. The separate dictation HUD was removed.
//        Push-to-talk waits `holdDelay` before it starts listening. A release before that is a
//        tap: it never starts the microphone (no flicker, no empty insert).
//        Hold key + Control = Claude task, push-to-talk like dictation: it listens while both are
//        held and the release of the hold key sends it; the pill offers Open Chat and Cancel.
//        Control may come first or within `holdDelay` after the hold key, before dictation has
//        started. The answer is pasted at the cursor like a dictation and left on the clipboard.
//        Double tap = quick recording (user request 2026-10-04): a normal recording session of
//        kind .quickRecording, stopped by the next press of the key (on key down, the release is
//        swallowed). Only quick recordings stop that way: a recording started with the mouse in
//        the pill stops only with the mouse, so a dictation during a meeting can never end it.
//        The two taps must be close (`doubleTapGap`) so two aborted dictation attempts never
//        record; presses in the first `quickRecordingGrace` of a quick recording are ignored (a
//        stray extra tap must not stop it at once), and AppViewModel discards quick recordings
//        under 2 s. A double tap while a meeting records says "Already recording" in the pill.
//        Deliberate: while a quick recording runs, the key stops it and does not dictate (during
//        a meeting the key dictates).
//        Voice assistant (user request 2026-10-13, replaces the one-shot mini task): the selection
//        is captured when Claude starts listening; after the request is sent the capsule steps
//        aside and the run continues in the background (one at a time). PASTE goes to the cursor
//        (and the clipboard) when a text field has focus, otherwise into an answer card; DONE
//        shows a result card; ASK shows a question card whose answer (typed, or dictated with
//        the key, which then fills the card instead of pasting) resumes the same Claude session.

import AppKit
import Foundation

@MainActor
final class QuickDictationController {

    private enum Mode {
        case idle
        /// Hold key is down, waiting out `holdDelay` before dictation starts.
        case pressPending
        case dictating
        /// Hold key + Control is down, the selection is being captured before listening starts.
        case claudePending
        case claudeListening
        case claudeWorking
    }

    /// Shorter presses are taps, not dictation.
    private static let holdDelay: Duration = .milliseconds(200)
    /// The two taps of a double tap end at most this far apart.
    private static let doubleTapGap: TimeInterval = 0.5
    /// Presses this soon after a quick recording started do not stop it.
    private static let quickRecordingGrace: TimeInterval = 1.0

    private let dictation = QuickDictationService()

    private weak var viewModel: AppViewModel?
    private var mode: Mode = .idle
    private var isFinishing = false
    /// Set when the key was released while dictation or Claude was still starting up.
    private var stopWhenStarted = false
    private var holdTask: Task<Void, Never>?
    private var tapTimes: [Date] = []
    /// The press that stopped a quick recording must not also count as a tap on release.
    private var swallowNextRelease = false
    /// The app that was frontmost when listening started, for the history.
    private var targetAppName: String?
    /// Selection, app and window captured when Claude starts listening.
    private var assistantContext = ClaudeAssistantContext()
    /// The running assistant request, cancellable.
    private var assistantTask: Task<Void, Never>?
    /// The Claude session a question belongs to, resumed with the answer.
    private var assistantSession: String?
    /// The request that started the session, for the history.
    private var assistantRequest = ""

    func configure(viewModel: AppViewModel) {
        self.viewModel = viewModel
        viewModel.meetingPill.onOpenClaudeChat = { [weak self] in self?.openClaudeChat() }
        viewModel.meetingPill.onCancelClaudeTask = { [weak self] in self?.cancelClaudeTask() }
        let model = viewModel.meetingPill.model
        model.assistantDismiss = { [weak self] in self?.viewModel?.meetingPill.clearAssistant() }
        model.assistantCopy = { [weak self] in
            if case .answer(let text) = model.assistant { Self.copyToClipboard(text) }
            self?.viewModel?.meetingPill.clearAssistant()
        }
        model.assistantInsert = { [weak self] in
            guard case .answer(let text) = model.assistant else { return }
            self?.viewModel?.meetingPill.clearAssistant()
            Self.copyToClipboard(text)
            Task { try? await TextInsertionService.insertAtCursor(text) }
        }
        model.assistantSend = { [weak self] in self?.answerAssistantQuestion() }
        model.assistantCancel = { [weak self] in self?.cancelAssistant() }
        // The first press should start as fast as every later one.
        if viewModel.automationSettings.quickDictationEnabled {
            dictation.prewarm(parakeet: viewModel.parakeetServiceForDictation)
        }
    }

    var isListening: Bool { dictation.isRunning }

    // MARK: - Entry points

    /// Toggle mode: first press starts, second press inserts.
    func toggle() {
        switch mode {
        case .idle: Task { await begin(claude: false) }
        case .dictating: Task { await finishDictation() }
        default: break
        }
    }

    /// Push-to-talk: called when the hotkey goes down, `withControl` when Control is held too.
    func pressBegan(withControl: Bool) {
        switch mode {
        case .idle where viewModel?.isQuickRecordingActive == true:
            swallowNextRelease = true
            tapTimes = []
            let started = viewModel?.currentSession?.createdAt ?? .distantPast
            guard Date().timeIntervalSince(started) >= Self.quickRecordingGrace else { return }
            Task { await viewModel?.stopRecording() }
        case .idle where withControl:
            beginClaude()
        case .idle:
            mode = .pressPending
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: Self.holdDelay)
                guard let self, !Task.isCancelled, self.mode == .pressPending else { return }
                await self.begin(claude: false)
            }
        default:
            break
        }
    }

    /// Push-to-talk: Control went down while the hotkey is held. Before dictation has started
    /// the press becomes a Claude task; once it listens it stays a dictation.
    func controlPressed() {
        guard mode == .pressPending else { return }
        beginClaude()
    }

    /// Push-to-talk: called when the hotkey is released.
    func pressEnded() {
        if swallowNextRelease {
            swallowNextRelease = false
            return
        }
        switch mode {
        case .pressPending:
            holdTask?.cancel()
            mode = .idle
            registerTap()
        case .dictating:
            if dictation.isRunning {
                Task { await finishDictation() }
            } else {
                stopWhenStarted = true
            }
        case .claudePending:
            stopWhenStarted = true
        case .claudeListening:
            if dictation.isRunning {
                Task { await finishClaudeTask() }
            } else {
                stopWhenStarted = true
            }
        default:
            break
        }
    }

    // MARK: - Taps

    private func registerTap() {
        let now = Date()
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) <= Self.doubleTapGap } + [now]
        guard tapTimes.count >= 2 else { return }
        tapTimes = []
        guard viewModel?.automationSettings.quickRecordingEnabled == true else { return }
        startQuickRecording()
    }

    private func startQuickRecording() {
        guard mode == .idle, let viewModel else { return }
        guard !viewModel.isRecording else {
            viewModel.meetingPill.flashRecordingHint("Already recording")
            return
        }
        Task { await viewModel.startQuickRecording() }
    }

    // MARK: - Flow

    /// Hold key + Control: a Claude task instead of a dictation, when switched on.
    private func beginClaude() {
        guard viewModel?.automationSettings.claudeTaskEnabled == true else {
            // Switched off: hold key + Control dictates like the hold key alone.
            if mode == .idle { pressBegan(withControl: false) }
            return
        }
        holdTask?.cancel()
        tapTimes = []
        mode = .claudePending
        // Reset here, not in `begin`: the keys may be released before that task runs.
        stopWhenStarted = false
        Task { await begin(claude: true) }
    }

    private func begin(claude: Bool) async {
        guard let viewModel else { mode = .idle; return }

        // Without Accessibility we could listen but never paste — ask first, do nothing else.
        // A Claude task still works without it: its answer then only reaches the clipboard.
        if !claude, !TextInsertionService.isTrusted {
            mode = .idle
            TextInsertionService.requestPermission()
            viewModel.errorMessage = TextInsertionService.InsertionError.notTrusted.localizedDescription
            return
        }
        if claude, ClaudeCodeService.locate() == nil {
            mode = .idle
            viewModel.meetingPill.dictationStarted(claude: true) { 0 }
            viewModel.meetingPill.claudeFinished(error: "Claude Code is not installed")
            return
        }
        if claude, assistantTask != nil {
            mode = .idle
            viewModel.meetingPill.dictationStarted(claude: true) { 0 }
            viewModel.meetingPill.claudeFinished(error: "Claude is still on the last request")
            return
        }
        if claude {
            // Before the pill shows: the selection belongs to the app the user is in.
            assistantContext = await SelectionCapture.capture()
            viewModel.meetingPill.model.assistantHasSelection = assistantContext.selection != nil
        }

        let language = viewModel.automationSettings.quickDictationLanguage
        // BCP-47, since that is what SFSpeechRecognizer expects ("de-DE", not "de_DE").
        let locale = language == "auto" ? Locale.current.identifier(.bcp47) : language

        mode = claude ? .claudeListening : .dictating
        if !claude { stopWhenStarted = false }
        // The pill never activates MinuteMind, so this is the app the user is working in.
        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        let pill = viewModel.meetingPill
        pill.dictationStarted(
            claude: claude,
            levelProvider: { [weak self] in self?.dictation.currentLevel ?? 0 },
            liveProvider: { [weak self] in self?.dictation.isMicLive ?? false })
        do {
            dictation.onPartialText = { text in
                pill.dictationText(text)
            }
            // Parakeet when its model is installed — same engine as file transcription.
            try await dictation.start(
                localeIdentifier: locale, parakeet: viewModel.parakeetServiceForDictation)
            if stopWhenStarted, mode == .dictating {
                await finishDictation()
            }
            if stopWhenStarted, mode == .claudeListening {
                await finishClaudeTask()
            }
            // Sent, opened or cancelled while the engine was still starting: release the mic.
            if claude, mode != .claudeListening, dictation.isRunning {
                _ = await dictation.stop()
            }
        } catch {
            mode = .idle
            pill.dictationEnded()
            viewModel.errorMessage = error.localizedDescription
            NSLog("QuickDictationController: start failed — \(error.localizedDescription)")
        }
    }

    /// Stops listening and returns the dictated text with the dictionary applied.
    private func stopAndCollect() async -> String {
        // Dictionary terms (e.g. "aus SEO" -> "Auth0") apply to dictated text too.
        let raw = await dictation.stop()
        dictation.onPartialText = nil
        return viewModel.map { VocabularyCorrection.apply(raw, entries: $0.vocabulary.entries).text } ?? raw
    }

    private func finishDictation() async {
        guard !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false; mode = .idle }

        let pill = viewModel?.meetingPill
        pill?.dictationInserting()
        let text = await stopAndCollect()

        guard !text.isEmpty else {
            pill?.dictationEnded()
            NSLog("QuickDictationController: nothing dictated")
            return
        }

        // A question from the assistant is open: the dictation is the answer.
        if let pill, case .ask = pill.model.assistant {
            let draft = pill.model.askDraft
            pill.model.askDraft = draft.isEmpty ? text : draft + " " + text
            pill.dictationEnded()
            return
        }

        do {
            try await TextInsertionService.insertAtCursor(text)
            NSLog("QuickDictationController: inserted \(text.count) characters")
            record(.dictation, text: text, inserted: true)
            pill?.dictationFinished(copied: false)
        } catch {
            // Fall back to leaving the text on the clipboard so the work is not lost.
            Self.copyToClipboard(text)
            viewModel?.errorMessage =
                "\(error.localizedDescription) The dictated text was copied to the clipboard instead."
            NSLog("QuickDictationController: insertion failed — \(error.localizedDescription)")
            record(.dictation, text: text, inserted: false)
            pill?.dictationFinished(copied: true)
        }
    }

    // MARK: - Claude task

    private func finishClaudeTask() async {
        guard mode == .claudeListening, let viewModel else { return }
        mode = .claudeWorking
        let pill = viewModel.meetingPill
        pill.claudeWorking()
        let request = await stopAndCollect()
        mode = .idle

        guard !request.isEmpty else {
            pill.claudeFinished(error: "Didn't catch that")
            return
        }
        // The capsule steps aside; the request runs in the background.
        pill.dictationEnded()
        assistantRequest = request
        assistantSession = nil
        runAssistant(prompt: ClaudeAssistantService.prompt(request: request, context: assistantContext), resume: nil)
    }

    /// One run (a new request, or the answer to a question) and what to do with its outcome.
    private func runAssistant(prompt: String, resume: String?) {
        guard let viewModel else { return }
        let pill = viewModel.meetingPill
        let settings = viewModel.automationSettings
        let allowsTerminal = settings.claudeTaskAllowsTerminal
        let model = settings.claudeTaskModel
        let system = ClaudeAssistantService.systemPrompt(userInstructions: settings.claudeTaskPrompt, allowsTerminal: allowsTerminal)
        let mcpConfig = viewModel.assistantMCPConfig()
        pill.setAssistantWorking(true)
        assistantTask = Task { [weak self] in
            defer {
                pill.setAssistantWorking(false)
                self?.assistantTask = nil
            }
            do {
                let reply = try await ClaudeAssistantService.run(
                    prompt: prompt, systemPrompt: system, model: model, mcpConfig: mcpConfig,
                    allowsTerminal: allowsTerminal, resume: resume)
                guard !Task.isCancelled else { return }
                await self?.handle(reply.outcome, sessionID: reply.sessionID)
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("QuickDictationController: assistant failed: \(error.localizedDescription)")
                pill.showAssistant(.failed("Claude couldn't finish: \(error.localizedDescription)"))
            }
        }
    }

    private func handle(_ outcome: ClaudeAssistantOutcome, sessionID: String?) async {
        guard let pill = viewModel?.meetingPill else { return }
        switch outcome {
        case .paste(let text):
            guard !text.isEmpty else {
                pill.showAssistant(.failed("Claude had nothing to say"))
                return
            }
            Self.copyToClipboard(text)
            // Into the text field the user is in; without one the answer waits in a card.
            if SelectionCapture.focusedTextIsEditable(), (try? await TextInsertionService.insertAtCursor(text)) != nil {
                record(.claudeTask, text: text, request: assistantRequest, inserted: true)
            } else {
                record(.claudeTask, text: text, request: assistantRequest, inserted: false)
                pill.showAssistant(.answer(text))
            }
        case .done(let summary, let details):
            record(.claudeTask, text: details.isEmpty ? summary : summary + "\n" + details, request: assistantRequest, inserted: false)
            pill.showAssistant(.done(summary: summary, details: details))
        case .ask(let question):
            assistantSession = sessionID
            pill.showAssistant(.ask(question))
        }
    }

    /// The question card's Send: resumes the session with the answer.
    private func answerAssistantQuestion() {
        guard let pill = viewModel?.meetingPill else { return }
        let answer = pill.model.askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        pill.clearAssistant()
        runAssistant(prompt: answer, resume: assistantSession)
    }

    private func cancelAssistant() {
        assistantTask?.cancel()
        assistantTask = nil
        viewModel?.meetingPill.setAssistantWorking(false)
        viewModel?.meetingPill.clearAssistant()
    }

    /// Ends listening and opens a Claude chat with what was said so far. The text also goes to
    /// the clipboard, in case the chat opens without it.
    private func openClaudeChat() {
        guard mode == .claudeListening else { return }
        mode = .claudeWorking
        Task {
            let text = await stopAndCollect()
            mode = .idle
            viewModel?.meetingPill.dictationEnded()
            if !text.isEmpty {
                Self.copyToClipboard(text)
                record(.dictation, text: text, inserted: false)
            }
            if let url = ClaudeTaskService.chatURL(
                for: text, claudeAppInstalled: ClaudeTaskService.isClaudeAppInstalled) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func cancelClaudeTask() {
        guard mode == .claudeListening else { return }
        mode = .claudeWorking
        Task {
            _ = await dictation.stop()
            dictation.onPartialText = nil
            mode = .idle
            viewModel?.meetingPill.dictationEnded()
        }
    }

    private func record(
        _ kind: DictationHistoryEntry.Kind, text: String, request: String? = nil, inserted: Bool
    ) {
        viewModel?.dictationHistory.add(DictationHistoryEntry(
            kind: kind, text: text, request: request, appName: targetAppName, inserted: inserted))
    }

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
