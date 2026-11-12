// Purpose: SwiftUI view for the full-screen live dictation overlay — animated word display during
//          transcription, editable text after stop, clipboard copy on dismiss.
// Dependencies: Sources/App/Components/DesignSystem.swift, LiveDictationPanel (LiveDictationState)
// Used by: Sources/App/Views/LiveDictationPanel.swift (hosted inside NSPanel)
// Notes: During transcription, words animate in with a scale/opacity spring. The most recent words
//        are displayed larger and shrink to normal size over ~0.6s, creating a wave-like rhythm.
//        Enter stops transcription and enters edit mode. Escape or double-Enter copies text and closes.

import SwiftUI
import AppKit

struct LiveDictationView: View {
    @ObservedObject var state: LiveDictationState
    var viewModel: AppViewModel
    let onDismiss: () -> Void

    @State private var editableText: String = ""
    @State private var lastEnterTime: Date? = nil
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            // Glass card
            VStack(spacing: 0) {
                switch state.phase {
                case .transcribing:
                    transcribingContent
                case .editing:
                    editingContent
                }
            }
            .frame(maxWidth: 700, maxHeight: 500)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.02),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.25),
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.04),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 40, y: 10)
            .padding(60)
        }
        .onKeyPress(.return) {
            handleEnter()
            return .handled
        }
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
    }

    // MARK: - Transcribing Content

    private var transcribingContent: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingL) {
            // Header with recording indicator
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                PulsingDot()
                Text(state.statusMessage)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                languagePicker
                engineBadge
            }
            .padding(.horizontal, DesignSystem.Dimensions.spacingXXL)
            .padding(.top, DesignSystem.Dimensions.spacingXXL)

            // Animated word display
            ScrollViewReader { proxy in
                ScrollView {
                    AnimatedWordsView(words: state.liveWords)
                        .id("words-bottom")
                }
                .onChange(of: state.liveWords.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("words-bottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, DesignSystem.Dimensions.spacingXXL)

            // Hint
            Text("Press **Return** to stop")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
                .padding(.bottom, DesignSystem.Dimensions.spacingL)
        }
    }

    // MARK: - Editing Content

    private var editingContent: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingL) {
            // Header
            HStack {
                Text("Edit Transcript")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button {
                    copyAndDismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                        Text("Copy & Close")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(.white.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DesignSystem.Dimensions.spacingXXL)
            .padding(.top, DesignSystem.Dimensions.spacingXXL)

            // Error / empty state
            if editableText.isEmpty && !state.statusMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(state.statusMessage)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, DesignSystem.Dimensions.spacingXXL)
            }

            // Editable text area
            TextEditor(text: $editableText)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .focused($isEditorFocused)
                .padding(DesignSystem.Dimensions.spacingM)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.05))
                )
                .padding(.horizontal, DesignSystem.Dimensions.spacingXXL)

            // Hints
            HStack(spacing: DesignSystem.Dimensions.spacingL) {
                hintLabel("Return Return", description: "Copy & close")
                hintLabel("Esc", description: "Copy & close")
            }
            .padding(.bottom, DesignSystem.Dimensions.spacingL)
        }
        .onAppear {
            editableText = state.finalText
            isEditorFocused = editableText.isEmpty ? false : true
        }
        .onChange(of: state.finalText) { _, newText in
            if editableText.isEmpty {
                editableText = newText
                if !newText.isEmpty { isEditorFocused = true }
            }
        }
    }

    // MARK: - Language Picker

    private var languagePicker: some View {
        Menu {
            Button {
                switchLanguage("auto")
            } label: {
                HStack {
                    Text("Auto-detect")
                    if state.language == "auto" { Image(systemName: "checkmark") }
                }
            }
            Button {
                switchLanguage("en-US")
            } label: {
                HStack {
                    Text("English (US)")
                    if state.language == "en-US" { Image(systemName: "checkmark") }
                }
            }
            Button {
                switchLanguage("de-DE")
            } label: {
                HStack {
                    Text("Deutsch")
                    if state.language == "de-DE" { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                Text(languageLabel)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var languageLabel: String {
        switch state.language {
        case "en-US": return "EN"
        case "de-DE": return "DE"
        default: return "Auto"
        }
    }

    private func switchLanguage(_ language: String) {
        guard language != state.language, state.phase == .transcribing else { return }
        Task { @MainActor in
            if let controller = findController() {
                await controller.restartWithLanguage(language, state: state)
            }
        }
    }

    // MARK: - Engine Badge

    private var engineBadge: some View {
        Text("Apple Speech")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.08)))
    }

    // MARK: - Hint Label

    private func hintLabel(_ key: String, description: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
            Text(description)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    // MARK: - Actions

    private func handleEnter() {
        switch state.phase {
        case .transcribing:
            // Stop transcription, enter edit mode
            Task { @MainActor in
                if let controller = findController() {
                    await controller.stopTranscription(state: state)
                }
            }

        case .editing:
            // Double-Enter detection
            let now = Date()
            if let last = lastEnterTime, now.timeIntervalSince(last) < 0.5 {
                copyAndDismiss()
            } else {
                lastEnterTime = now
                // Allow normal text editing (newline) in the text editor
            }
        }
    }

    private func handleEscape() {
        if state.phase == .editing {
            copyAndDismiss()
        } else {
            // Cancel during transcription
            Task { @MainActor in
                await viewModel.stopLiveTranscription()
            }
            onDismiss()
        }
    }

    private func copyAndDismiss() {
        let text = state.phase == .editing ? editableText : state.finalText
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        state.cancelObservation()
        onDismiss()
    }

    /// Walk the responder chain to find the controller — a simple approach since the panel is our own.
    private func findController() -> LiveDictationController? {
        // The controller is accessible through the AppDelegate
        (NSApp.delegate as? AppDelegate)?.liveDictationControllerRef
    }
}

// MARK: - Animated Words View

private struct AnimatedWordsView: View {
    let words: [LiveDictationState.AnimatedWord]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(words) { word in
                AnimatedWordView(word: word)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnimatedWordView: View {
    let word: LiveDictationState.AnimatedWord

    @State private var scale: CGFloat = 1.3
    @State private var opacity: Double = 0.0

    private var age: TimeInterval {
        Date().timeIntervalSince(word.arrivedAt)
    }

    var body: some View {
        Text(word.text)
            .font(.system(size: 22, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    scale = 1.0
                    opacity = 1.0
                }
            }
    }
}

// MARK: - Flow Layout (wrapping text)

private struct FlowLayout: Layout {
    var spacing: CGFloat

    struct LayoutCache {
        var size: CGSize
        var positions: [CGPoint]
    }

    func makeCache(subviews: Subviews) -> LayoutCache? {
        nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout LayoutCache?) -> CGSize {
        let result = computeLayout(in: proposal.width ?? .infinity, subviews: subviews)
        cache = result
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout LayoutCache?) {
        let result = cache ?? computeLayout(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
        cache = nil
    }

    private func computeLayout(in width: CGFloat, subviews: Subviews) -> LayoutCache {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxWidth = max(maxWidth, x)
        }

        return LayoutCache(size: CGSize(width: maxWidth, height: y + rowHeight), positions: positions)
    }
}

// MARK: - Pulsing Recording Dot

private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .shadow(color: .red.opacity(0.6), radius: isPulsing ? 8 : 2)
            .scaleEffect(isPulsing ? 1.2 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
