// Purpose: SyntaxHighlighter, colours source text for the workspace editor with highlight.js
//          (through Highlightr) on a background queue and hands back colour runs.
// Dependencies: Highlightr (Swift package; highlight.js 11 in JavaScriptCore, themes as CSS),
//               AppKit (NSColor)
// Used by: Sources/App/Views/WorkspaceCodeEditor.swift (debounced re-highlight while editing),
//          Tests/WorkspaceFileKindTests.swift
// Notes: Decisions (2026-10-13):
//        - Themes: highlight.js "xcode" on light backgrounds and "xcode-dark" on dark ones, so
//          code looks like it does in Xcode and fits the stock macOS look of the Studio theme.
//          The caller picks by the editor background's luminance, not by the system
//          appearance, so a custom theme with a dark background in light mode still gets the
//          dark palette. Only foreground colours are taken: the theme's background, fonts
//          (Courier), bold and italic are dropped, so the editor keeps the app's surface colour
//          and its monospaced font, and colouring never changes line heights or wrapping.
//          Runs in the theme's base text colour are left out; the editor draws those in the
//          app's own text colour.
//        - Threading: one Highlightr (one JSContext) lives on a private serial queue and is
//          only touched there, created on first use (evaluating highlight.js takes about
//          0.1 s). JavaScriptCore is not tied to the main thread, so typing stays smooth while
//          a pass runs.
//        - Size cap: files over 262,144 UTF-16 units (256 KB of ASCII) or 10,000 lines are not
//          coloured (`shouldHighlight`); they show as plain text. Measured: a 1 MB JSON file
//          takes about 6 s per pass in a debug build (most of it Highlightr turning the HTML
//          into attributes), so a 1 MB cap would leave colours seconds behind the typing;
//          256 KB takes about a second.
//        - Resources: Highlightr loads highlight.js through SwiftPM's Bundle.module, which
//          stops the app (fatalError) when its resource bundle is missing. That bundle is found
//          next to the executable (swift run, tests) or in the package's .build folder (the
//          packaged app; package_app.sh copies no resource bundles, and the app root cannot hold
//          one without breaking the code signature). `isAvailable` checks the same two places
//          first, so a copy of the app on another Mac shows plain text instead of crashing.

import AppKit
import Foundation
import Highlightr

final class SyntaxHighlighter: @unchecked Sendable {
    /// A stretch of text and its colour.
    struct Run: @unchecked Sendable, Equatable {
        let range: NSRange
        let color: NSColor
    }

    static let shared = SyntaxHighlighter()

    static let maxLength = 262_144
    static let maxLines = 10_000

    static let lightTheme = "xcode"
    static let darkTheme = "xcode-dark"

    /// Whether the text is small enough to colour.
    static func shouldHighlight(length: Int, lines: Int) -> Bool {
        length <= maxLength && lines <= maxLines
    }

    /// Whether Highlightr's resource bundle can be found (see Notes); without it Highlightr
    /// would stop the app.
    static let isAvailable: Bool = {
        let name = "Highlightr_Highlightr.bundle"
        let besideExecutable = Bundle.main.bundleURL.appendingPathComponent(name)
        // SwiftPM's generated accessor falls back to <package>/.build/<triple>/<config>/.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Supporting
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()
        #if arch(arm64)
        let triple = "arm64-apple-macosx"
        #else
        let triple = "x86_64-apple-macosx"
        #endif
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let buildFolder = packageRoot.appendingPathComponent(".build/\(triple)/\(configuration)/\(name)")
        return [besideExecutable, buildFolder].contains { FileManager.default.fileExists(atPath: $0.path) }
    }()

    private let queue = DispatchQueue(label: "app.minutemind.syntax-highlighter", qos: .userInitiated)
    // Only touched on `queue`.
    private var highlightr: Highlightr?
    private var didLoad = false
    private var languages: Set<String> = []
    private var theme: String?
    private var baseColor: NSColor?

    /// Colour runs for the text, or nil when the language is unknown, highlighting is not
    /// available or the result does not line up with the text.
    func highlight(_ text: String, language: String, dark: Bool) async -> [Run]? {
        guard Self.isAvailable else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.runs(text, language: language, dark: dark))
            }
        }
    }

    private func runs(_ text: String, language: String, dark: Bool) -> [Run]? {
        if !didLoad {
            didLoad = true
            highlightr = Highlightr()
            languages = Set(highlightr?.supportedLanguages() ?? [])
        }
        guard let highlightr, languages.contains(language) else { return nil }
        let themeName = dark ? Self.darkTheme : Self.lightTheme
        if theme != themeName {
            guard highlightr.setTheme(to: themeName) else { return nil }
            theme = themeName
            baseColor = highlightr.highlight("x", as: "plaintext")?
                .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        guard let result = highlightr.highlight(text, as: language),
              result.length == (text as NSString).length else { return nil }
        var runs: [Run] = []
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let color = value as? NSColor, color != baseColor else { return }
            runs.append(Run(range: range, color: color))
        }
        return runs
    }
}
