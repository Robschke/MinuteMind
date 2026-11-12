// Purpose: WorkspaceCodeEditor, the workspace's text editor: an NSTextView with syntax colours
//          (highlight.js through SyntaxHighlighter), a line-number gutter and the app theme's
//          colours, bound to the open document's text.
// Dependencies: Sources/App/Supporting/SyntaxHighlighter.swift (colour runs, size cap),
//               Sources/App/Supporting/ThemeStore.swift + Sources/App/Config/AppTheme.swift
//               (editor colours, theme change notification), AppKit (TextKit 1)
// Used by: Sources/App/Views/WorkspaceEditorPane.swift, Tests/WorkspaceFileKindTests.swift (gutter)
// Notes: Decisions (2026-10-13):
//        - TextKit 1, built by hand (NSTextView(usingTextLayoutManager: false)), because the
//          gutter walks the layout manager's line fragments; non-contiguous layout keeps 10 MB
//          read-only files responsive.
//        - Colours: background is the theme's card colour (Studio: the same white or near-black
//          as before), text the theme's primary text colour, caret the accent. The highlight.js
//          palette (Xcode or Xcode Dark) follows the card colour's luminance, like the terminal
//          does with its background. Theme and appearance changes recolour at once.
//        - Highlighting runs off the main thread 250 ms after the last keystroke, one pass at
//          a time per editor (edits during a pass start one more pass after it), and is applied
//          as foreground-colour attributes on the text storage: no undo entries, the caret and
//          selection stay put, and a result is dropped if the text changed meanwhile or while
//          an input method has marked text. New characters take the plain text colour until
//          the next pass. Files over the SyntaxHighlighter cap show plain.
//        - Gutter: line numbers (VS Code style, no separator line) in tertiary text, the caret's
//          line in secondary text; wrapped lines are numbered once. Soft wrap stays on, since the
//          editor is often narrow beside or above Claude.
//        - The gutter clips to its bounds (macOS 14 stopped clipping by default; unclipped, its
//          background covered the tree, the header and the text of every non-Markdown file).
//        - No text substitutions (quotes, dashes, spelling), so code and Markdown survive typing.

import AppKit
import SwiftUI

struct WorkspaceCodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// highlight.js language; nil shows plain text.
    let language: String?
    let isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, language: language) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        let contentSize = scrollView.contentSize

        let textView = CodeTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 12)
        scrollView.documentView = textView

        let ruler = LineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.attach(scrollView: scrollView, textView: textView, ruler: ruler)
        context.coordinator.replaceText(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        (scrollView.documentView as? NSTextView)?.isEditable = isEditable
        // Compared with the last synced text, not textView.string: bridging a large buffer on
        // every update would cost a copy and a full comparison.
        if text != context.coordinator.lastText { context.coordinator.replaceText(text) }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// The text the view shows, as last synced with the binding.
        private(set) var lastText = ""
        private let language: String?
        private weak var scrollView: NSScrollView?
        private weak var textView: CodeTextView?
        private weak var ruler: LineNumberRuler?
        private var highlightTask: Task<Void, Never>?
        private var generation = 0
        /// A pass is running in the background; edits meanwhile wait for it.
        private var isHighlighting = false
        private var needsAnotherPass = false
        /// Whether colour runs are applied, so plain text is reset once when colouring stops.
        private var isColoured = false
        private var themeObserver: NSObjectProtocol?

        init(text: Binding<String>, language: String?) {
            self.text = text
            self.language = language
        }

        func attach(scrollView: NSScrollView, textView: CodeTextView, ruler: LineNumberRuler) {
            self.scrollView = scrollView
            self.textView = textView
            self.ruler = ruler
            textView.onAppearanceChange = { [weak self] in self?.themeChanged() }
            themeObserver = NotificationCenter.default.addObserver(
                forName: .minuteMindThemeChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.themeChanged() }
            }
            applyThemeColors()
        }

        func tearDown() {
            highlightTask?.cancel()
            if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
            themeObserver = nil
        }

        /// Text replaced from outside (file reloaded or first shown): keep the caret in range.
        func replaceText(_ newText: String) {
            guard let textView else { return }
            let selection = textView.selectedRange()
            textView.string = newText
            lastText = newText
            let length = (newText as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            // The new text took the typing attributes, which may hold a syntax colour.
            textView.textColor = ThemeStore.shared.theme.textPrimary.nsColor
            isColoured = false
            ruler?.textDidChange()
            scheduleHighlight(after: nil)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let string = textView.string
            lastText = string
            text.wrappedValue = string
            ruler?.textDidChange()
            scheduleHighlight(after: .milliseconds(250))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            ruler?.needsDisplay = true
        }

        // MARK: Colours

        private var isDarkBackground: Bool {
            let appearance = textView?.effectiveAppearance ?? NSApp.effectiveAppearance
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return ThemeColor.luminance(ThemeStore.shared.theme.card.resolved(dark: isDark)) <= 0.4
        }

        private func themeChanged() {
            applyThemeColors()
            isColoured = false
            scheduleHighlight(after: nil)
        }

        private func applyThemeColors() {
            guard let textView else { return }
            let theme = ThemeStore.shared.theme
            textView.backgroundColor = theme.card.nsColor
            scrollView?.backgroundColor = theme.card.nsColor
            textView.insertionPointColor = theme.accent.nsColor
            // Sets the colour of all text; highlighting is applied again right after.
            textView.textColor = theme.textPrimary.nsColor
            textView.typingAttributes[.foregroundColor] = theme.textPrimary.nsColor
            ruler?.colors = .init(
                background: theme.card.nsColor, number: theme.textTertiary.nsColor,
                currentNumber: theme.textSecondary.nsColor)
        }

        // MARK: Highlighting

        private func scheduleHighlight(after delay: Duration?) {
            highlightTask?.cancel()
            generation += 1
            guard let language, let textView, SyntaxHighlighter.isAvailable,
                  SyntaxHighlighter.shouldHighlight(length: textView.textStorage?.length ?? 0, lines: ruler?.lineCount ?? 0)
            else {
                if isColoured { apply([]) }
                return
            }
            let generation = generation
            highlightTask = Task { [weak self] in
                if let delay {
                    try? await Task.sleep(for: delay)
                    if Task.isCancelled { return }
                }
                self?.runPass(generation: generation, language: language)
            }
        }

        private func runPass(generation: Int, language: String) {
            guard !isHighlighting else {
                needsAnotherPass = true
                return
            }
            isHighlighting = true
            let snapshot = lastText
            let dark = isDarkBackground
            Task { [weak self] in
                let runs = await SyntaxHighlighter.shared.highlight(snapshot, language: language, dark: dark)
                guard let self else { return }
                self.isHighlighting = false
                if self.needsAnotherPass {
                    // Edits arrived while this pass ran; colour their text instead.
                    self.needsAnotherPass = false
                    self.runPass(generation: self.generation, language: language)
                    return
                }
                // A newer schedule is still waiting out its delay, or colouring was switched off.
                guard generation == self.generation, let runs else { return }
                if self.textView?.hasMarkedText() == true {
                    // An input method is composing; colouring now would disturb it.
                    self.scheduleHighlight(after: .milliseconds(250))
                    return
                }
                self.apply(runs)
            }
        }

        /// Sets the plain text colour on everything, then the runs' colours.
        private func apply(_ runs: [SyntaxHighlighter.Run]) {
            guard let storage = textView?.textStorage else { return }
            let base = ThemeStore.shared.theme.textPrimary.nsColor
            let length = storage.length
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: base, range: NSRange(location: 0, length: length))
            for run in runs where NSMaxRange(run.range) <= length {
                storage.addAttribute(.foregroundColor, value: run.color, range: run.range)
            }
            storage.endEditing()
            isColoured = !runs.isEmpty
        }
    }
}

/// The text view, reporting appearance changes (light and dark) so colours can follow.
final class CodeTextView: NSTextView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// Line numbers beside a TextKit 1 text view; a wrapped line is numbered on its first fragment.
final class LineNumberRuler: NSRulerView {
    struct Colors {
        var background: NSColor = .textBackgroundColor
        var number: NSColor = .tertiaryLabelColor
        var currentNumber: NSColor = .secondaryLabelColor
    }

    var colors = Colors() { didSet { needsDisplay = true } }
    var lineCount: Int { lineStarts.count }

    private weak var textView: NSTextView?
    /// UTF-16 offset where each line starts; always begins with 0.
    private var lineStarts: [Int] = [0]
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // Since macOS 14 views do not clip to their bounds by default, and the dirty rect handed
        // to the ruler can reach far beyond it: filling that painted over the file tree, the
        // header and the text itself, leaving only the line numbers.
        clipsToBounds = true
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = 32
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw), name: NSView.frameDidChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override var requiredThickness: CGFloat { ruleThickness }

    @objc private func redraw() { needsDisplay = true }

    /// Recounts the lines (one pass over the text) and widens the gutter for more digits.
    func textDidChange() {
        guard let storage = textView?.textStorage else { return }
        let string = storage.mutableString
        let length = string.length
        var starts = [0]
        var buffer = [unichar](repeating: 0, count: 8192)
        var location = 0
        while location < length {
            let count = min(buffer.count, length - location)
            buffer.withUnsafeMutableBufferPointer { pointer in
                string.getCharacters(pointer.baseAddress!, range: NSRange(location: location, length: count))
                for index in 0..<count where pointer[index] == 0x0A { starts.append(location + index + 1) }
            }
            location += count
        }
        lineStarts = starts
        let digits = max(2, String(starts.count).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth) + 18
        if thickness != ruleThickness {
            ruleThickness = thickness
            scrollView?.tile()
        }
        needsDisplay = true
    }

    /// Index of the line that holds the character offset.
    private func lineIndex(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        colors.background.setFill()
        bounds.intersection(rect).fill()
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let storage = textView.textStorage else { return }
        let length = storage.length
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let currentLine = lineIndex(containing: textView.selectedRange().location)
        let lineHeight = font.ascender - font.descender

        var line = lineIndex(containing: characters.location)
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(characters) { break }
            let fragment: NSRect
            if start >= length {
                // The empty last line after a final newline (or an empty file).
                fragment = layoutManager.extraLineFragmentRect
                if fragment.height == 0, length > 0 { break }
            } else {
                fragment = layoutManager.lineFragmentRect(
                    forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            let label = "\(line + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: line == currentLine ? colors.currentNumber : colors.number,
            ]
            let width = label.size(withAttributes: attributes).width
            let height = fragment.height > 0 ? fragment.height : lineHeight
            label.draw(
                at: NSPoint(x: ruleThickness - 10 - width, y: top + (height - lineHeight) / 2),
                withAttributes: attributes)
            line += 1
        }
    }
}
