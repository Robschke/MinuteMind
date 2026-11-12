// Purpose: Tests for what the workspace editor opens and how: file kinds by name, extension and
//          content sniffing, size limits (editable, read-only, refused), images and PDFs, and
//          syntax highlighting through Highlightr.
// Dependencies: Sources/App/Supporting/WorkspaceFileKinds.swift,
//               Sources/App/Supporting/WorkspaceEditorStore.swift,
//               Sources/App/Supporting/SyntaxHighlighter.swift

import AppKit
import Foundation
import Testing

@testable import MinuteMindApp

@Suite("WorkspaceFileKind Tests")
struct WorkspaceFileKindTests {
    private func makeFile(_ name: String, _ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeFile(_ name: String, _ text: String) throws -> URL {
        try makeFile(name, Data(text.utf8))
    }

    private func kind(_ name: String) -> WorkspaceFileKind? {
        WorkspaceFileKind.detectByName(URL(fileURLWithPath: "/x/\(name)"))
    }

    @Test func knowsLanguagesByExtensionAndName() {
        #expect(kind("main.swift") == .text(language: "swift"))
        #expect(kind("config.YAML") == .text(language: "yaml"))
        #expect(kind("pyproject.toml") == .text(language: "ini"))
        #expect(kind("Info.plist") == .text(language: "xml"))
        #expect(kind("index.html") == .text(language: "xml"))
        #expect(kind("app.tsx") == .text(language: "typescript"))
        #expect(kind("schema.sql") == .text(language: "sql"))
        #expect(kind("notes.md") == .text(language: "markdown"))
        #expect(kind("Dockerfile") == .text(language: "dockerfile"))
        #expect(kind("Dockerfile.dev") == .text(language: "dockerfile"))
        #expect(kind("Makefile") == .text(language: "makefile"))
        #expect(kind(".env") == .text(language: "properties"))
        #expect(kind(".env.local") == .text(language: "properties"))
        #expect(kind(".gitignore") == .text(language: nil))
        #expect(kind("server.log") == .text(language: nil))
        #expect(kind("data.csv") == .text(language: nil))
        #expect(kind("slides.pdf") == .pdf)
        #expect(kind("photo.png") == nil)  // needs the disk check
    }

    @Test func everyMappedLanguageExistsInHighlightJS() async throws {
        try #require(SyntaxHighlighter.isAvailable)
        var languages = Set(WorkspaceFileKind.languageByExtension.values)
        languages.formUnion(WorkspaceFileKind.languageByFileName.values)
        languages.insert("properties")
        for language in languages.sorted() {
            // An unknown language makes Highlightr fall back to auto-detection; a known one
            // returns runs (possibly empty) for this neutral snippet.
            let runs = await SyntaxHighlighter.shared.highlight("x", language: language, dark: false)
            #expect(runs != nil, "\(language) is not a highlight.js language")
        }
    }

    @Test func sniffsUnknownFiles() throws {
        let script = try makeFile("deploy", "#!/usr/bin/env python3\nprint('hi')\n")
        #expect(WorkspaceFileKind.detect(script) == .text(language: "python"))
        let notes = try makeFile("notes.weird", "plain words, äöü\n")
        #expect(WorkspaceFileKind.detect(notes) == .text(language: nil))
        let binary = try makeFile("blob.weird", Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]))
        #expect(WorkspaceFileKind.detect(binary) == nil)
        let latin1 = try makeFile("old.weird", Data([0x61, 0xE4, 0x62]))
        #expect(WorkspaceFileKind.detect(latin1) == nil)
        // A multi-byte character cut at the sniff boundary still counts as UTF-8.
        var cut = Data(repeating: 0x61, count: WorkspaceFileKind.sniffBytes - 1)
        cut.append(contentsOf: Array("ä".utf8))
        let long = try makeFile("long.weird", cut)
        #expect(WorkspaceFileKind.detect(long) == .text(language: nil))
        #expect(WorkspaceFileKind.detect(long.deletingLastPathComponent()) == nil)
        let rtf = try makeFile("letter.rtf", "{\\rtf1 hello}")
        #expect(WorkspaceFileKind.detect(rtf) == nil)
    }

    @Test func opensImagesAndPDFsInline() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = try makeFile("chart.png", png)
        #expect(WorkspaceFileKind.detect(url) == .image)
        let opened = try #require(WorkspaceEditorStore.open(url))
        #expect(opened.isReadOnly)

        let broken = try makeFile("broken.png", "not an image")
        #expect(WorkspaceFileKind.detect(broken) == nil)
        let pdf = try makeFile("paper.pdf", "%PDF-1.4")
        #expect(WorkspaceFileKind.detect(pdf) == .pdf)
        let audio = try makeFile("call.m4a", Data([0, 0, 0, 0x20]))
        #expect(WorkspaceFileKind.detect(audio) == nil)
    }

    @Test func largeTextOpensReadOnly() throws {
        let line = String(repeating: "a", count: 1023) + "\n"
        let big = try makeFile("big.log", String(repeating: line, count: 3 * 1024))  // 3 MB
        let opened = try #require(WorkspaceEditorStore.open(big))
        #expect(opened.isReadOnly)
        #expect(opened.kind == .text(language: nil))
        let small = try makeFile("small.json", "{\"a\": 1}")
        #expect(WorkspaceEditorStore.open(small)?.isReadOnly == false)
    }

    @MainActor
    @Test func readOnlyDocumentsNeverWrite() throws {
        let line = String(repeating: "b", count: 1023) + "\n"
        let url = try makeFile("huge.txt", String(repeating: line, count: 3 * 1024))
        let state = WorkspaceEditorState()
        #expect(state.open(url))
        state.document?.text = "replaced"
        state.document?.keepMine()
        #expect(try Data(contentsOf: url).count == 3 * 1024 * 1024)
    }

    @MainActor
    @Test func gutterCountsLines() {
        let scrollView = NSScrollView()
        let textView = CodeTextView(usingTextLayoutManager: false)
        scrollView.documentView = textView
        let ruler = LineNumberRuler(scrollView: scrollView, textView: textView)
        textView.string = "one\ntwo\n\nfour\n"
        ruler.textDidChange()
        #expect(ruler.lineCount == 5)
        textView.string = ""
        ruler.textDidChange()
        #expect(ruler.lineCount == 1)
    }

    @Test func highlightsTheLargestColouredFileInTime() async throws {
        try #require(SyntaxHighlighter.isAvailable)
        let entry = "  {\"id\": 12345, \"name\": \"Meeting notes\", \"done\": false, \"tags\": [\"a\", \"b\"]},\n"
        let json = "[\n" + String(repeating: entry, count: (SyntaxHighlighter.maxLength - 10) / entry.utf8.count) + "]\n"
        #expect(SyntaxHighlighter.shouldHighlight(length: json.utf16.count, lines: 4000))
        let start = Date()
        let runs = await SyntaxHighlighter.shared.highlight(json, language: "json", dark: true)
        let seconds = Date().timeIntervalSince(start)
        #expect(runs != nil)
        #expect(seconds < 10)
    }

    @Test func highlightsSwift() async throws {
        try #require(SyntaxHighlighter.isAvailable)
        let code = "let answer = \"42\" // note"
        let runs = try #require(await SyntaxHighlighter.shared.highlight(code, language: "swift", dark: false))
        let ns = code as NSString
        let coloured = Set(runs.map { ns.substring(with: $0.range) })
        #expect(coloured.contains("let"))
        #expect(coloured.contains("\"42\""))
        #expect(coloured.contains("// note"))
        #expect(!coloured.contains(" answer = "))
        #expect(SyntaxHighlighter.shouldHighlight(length: 10, lines: 1))
        #expect(!SyntaxHighlighter.shouldHighlight(length: 2_000_000, lines: 1))
        #expect(!SyntaxHighlighter.shouldHighlight(length: 100, lines: 30_000))
    }
}
