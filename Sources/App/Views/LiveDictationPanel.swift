// Purpose: Full-screen overlay panel for live dictation — manages NSPanel lifecycle, dimming, and
//          transcription engine dispatch based on the user's default pipeline model.
// Dependencies: AppKit, Sources/App/ViewModels/AppViewModel.swift,
//               Sources/App/Config/AutomationSettings.swift, LiveDictationView
// Used by: Sources/App/MinuteMindApp.swift (AppDelegate hotkey handler)
// Notes: Always streams through Apple Speech, which shows real-time text while you speak.

import AppKit
import SwiftUI

@MainActor
final class LiveDictationController {

    private var panel: LiveDictationNSPanel?
    private weak var viewModel: AppViewModel?
    private var dictationState: LiveDictationState?

    var isVisible: Bool { panel?.isVisible ?? false }

    func configure(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    func toggle() {
        if isVisible {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        guard let viewModel else { return }

        NSApp.activate(ignoringOtherApps: true)

        let state = LiveDictationState()
        state.language = viewModel.automationSettings.liveDictationLanguage
        self.dictationState = state

        if panel == nil {
            createPanel()
        }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let panel, let screen else { return }

        // Full-screen overlay
        panel.setFrame(screen.frame, display: true)

        let contentView = LiveDictationView(
            state: state,
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.dismiss() }
        )

        if let hosting = panel.contentView?.subviews.compactMap({ $0 as? NSHostingView<AnyView> }).first {
            hosting.rootView = AnyView(contentView)
        } else {
            let hosting = NSHostingView(rootView: AnyView(contentView))
            hosting.translatesAutoresizingMaskIntoConstraints = false

            if let container = panel.contentView {
                // Remove old hosting views
                container.subviews.forEach { $0.removeFromSuperview() }
                container.addSubview(hosting)
                NSLayoutConstraint.activate([
                    hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    hosting.topAnchor.constraint(equalTo: container.topAnchor),
                    hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
            }
        }

        // Wire Return key: stop transcription when in transcribing phase; editing phase
        // passes Return through to the TextEditor via super.keyDown (see NSPanel subclass).
        panel.onReturn = { [weak self] in
            guard let self, let state = self.dictationState,
                  state.phase == .transcribing else { return }
            Task { @MainActor in
                await self.stopTranscription(state: state)
            }
        }

        panel.orderFrontRegardless()
        panel.makeKey()

        // Start transcription
        Task { @MainActor in
            await startTranscription(state: state, viewModel: viewModel)
        }
    }

    func dismiss() {
        Task { @MainActor in
            if let state = dictationState, state.phase == .transcribing {
                await stopTranscription(state: state)
            }
        }
        panel?.orderOut(nil)
        dictationState = nil
    }

    // MARK: - Panel Setup

    private func createPanel() {
        let panel = LiveDictationNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow

        panel.onCancel = { [weak self] in
            self?.dismiss()
        }

        let container = NSView()
        container.wantsLayer = true
        panel.contentView = container

        self.panel = panel
    }

    // MARK: - Transcription Engine Dispatch

    private func startTranscription(state: LiveDictationState, viewModel: AppViewModel) async {
        // Apply the dictation language setting to viewModel so engines pick it up
        let langOption = AppViewModel.LanguageOption(rawValue: state.language) ?? .auto
        viewModel.selectedLanguage = langOption

        state.phase = .transcribing
        state.statusMessage = "Listening..."

        do {
            _ = try await viewModel.startLiveTranscription()

            // Observe live transcript updates
            state.observeTranscript(from: viewModel)
        } catch {
            state.statusMessage = "Error: \(error.localizedDescription)"
            state.phase = .editing
        }
    }

    /// Restart transcription with a new language (for mid-session language switching).
    func restartWithLanguage(_ language: String, state: LiveDictationState) async {
        guard let viewModel else { return }
        // Stop current engine
        await stopTranscriptionEngine(state: state, viewModel: viewModel)
        // Reset live words but keep any already-captured text as a prefix
        let captured = state.liveWords.map(\.text).joined(separator: " ")
        state.liveWords.removeAll()
        state.language = language
        state.phase = .transcribing
        // Restart with new language
        await startTranscription(state: state, viewModel: viewModel)
        // Re-insert captured words so previous text is not lost
        if !captured.isEmpty {
            let now = Date()
            let words = captured.split(separator: " ").map { LiveDictationState.AnimatedWord(text: String($0), arrivedAt: now) }
            state.liveWords.insert(contentsOf: words, at: 0)
        }
    }

    func stopTranscription(state: LiveDictationState) async {
        guard let viewModel else { return }
        await stopTranscriptionEngine(state: state, viewModel: viewModel)
        state.phase = .editing
        state.statusMessage = ""
    }

    /// Stops the active transcription engine and captures final text, but does NOT change phase.
    private func stopTranscriptionEngine(state: LiveDictationState, viewModel: AppViewModel) async {
        await viewModel.stopLiveTranscription()
        let fullText = viewModel.liveTranscriptText
        if !fullText.isEmpty {
            state.finalText = fullText
        }
    }
}

// MARK: - NSPanel Subclass

private class LiveDictationNSPanel: NSPanel {
    var onReturn: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / numpad Enter
            // When a text view is first responder (editing phase), let it handle the key normally.
            // Otherwise (transcribing phase) fire the Return callback.
            if firstResponder is NSTextView {
                super.keyDown(with: event)
            } else {
                onReturn?()
            }
        case 53: // Escape — always dismiss
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Dictation State

enum DictationPhase {
    case transcribing
    case editing
}

@MainActor
class LiveDictationState: ObservableObject {
    @Published var phase: DictationPhase = .transcribing
    @Published var statusMessage: String = "Listening..."
    @Published var finalText: String = ""
    /// Current language selection — initialized from AutomationSettings, changeable mid-session.
    @Published var language: String = "auto"

    // For real-time Apple Speech display
    @Published var liveWords: [AnimatedWord] = []
    @Published var currentPartial: String = ""

    private var lastWordCount = 0
    private var transcriptObservationTask: Task<Void, Never>?

    struct AnimatedWord: Identifiable {
        let id = UUID()
        let text: String
        let arrivedAt: Date
    }

    func observeTranscript(from viewModel: AppViewModel) {
        transcriptObservationTask?.cancel()
        transcriptObservationTask = Task { @MainActor [weak self] in
            var lastPreview = ""
            while !Task.isCancelled {
                let preview = viewModel.liveTranscriptPreview
                if preview != lastPreview {
                    lastPreview = preview
                    self?.updateLiveWords(from: preview)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func updateLiveWords(from text: String) {
        // Extract just the spoken words (strip timestamps/speaker labels)
        let cleaned = text
            .replacingOccurrences(of: #"\[\d{2}:\d{2}\] (You|Other): "#, with: "", options: .regularExpression)

        let words = cleaned.split(separator: " ").map(String.init)
        let now = Date()

        // Add new words with animation timestamp
        if words.count > lastWordCount {
            let newWords = words[lastWordCount...]
            for word in newWords {
                liveWords.append(AnimatedWord(text: word, arrivedAt: now))
            }
        } else if words.count < lastWordCount {
            // Partial result replaced — rebuild
            liveWords = words.map { AnimatedWord(text: $0, arrivedAt: now) }
        }
        lastWordCount = words.count
        currentPartial = cleaned
    }

    func cancelObservation() {
        transcriptObservationTask?.cancel()
    }
}
