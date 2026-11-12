// Purpose: Tests for the workspace editor's file handling: which files open, frontmatter split,
//          saving, and following changes Claude makes on disk (reload when clean, conflict when
//          edited, close when a clean file is deleted).
// Dependencies: Sources/App/Supporting/WorkspaceEditorStore.swift

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("WorkspaceEditorStore Tests")
struct WorkspaceEditorStoreTests {
    private func makeFile(_ name: String, _ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes new content with a later modification date, as an edit by Claude would.
    private func writeLater(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
    }

    @Test func opensTextAndMarkdownOnly() throws {
        #expect(WorkspaceEditorStore.isEditable(URL(fileURLWithPath: "/x/summary.md")))
        #expect(WorkspaceEditorStore.isEditable(URL(fileURLWithPath: "/x/notes.txt")))
        #expect(!WorkspaceEditorStore.isEditable(URL(fileURLWithPath: "/x/slides.pdf")))
        #expect(!WorkspaceEditorStore.isEditable(URL(fileURLWithPath: "/x/audio.m4a")))

        let state = WorkspaceEditorState()
        let binary = try makeFile("data.txt", "")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)
        #expect(!state.open(binary))
        #expect(state.document == nil)
    }

    @Test func splitsFrontmatter() {
        let text = "---\ntitle: \"Weekly sync\"\ndate: 2026-10-05\n---\n# Summary\nBody"
        let parts = WorkspaceEditorStore.splitFrontmatter(text)
        #expect(parts.fields.map(\.key) == ["title", "date"])
        #expect(parts.fields.first?.value == "Weekly sync")
        #expect(parts.body == "# Summary\nBody")
        #expect(WorkspaceEditorStore.splitFrontmatter("# Plain").body == "# Plain")
    }

    @Test func savesEditsAndReplacesOnOpen() throws {
        let first = try makeFile("a.md", "one")
        let second = first.deletingLastPathComponent().appendingPathComponent("b.txt")
        try "two".write(to: second, atomically: true, encoding: .utf8)
        let state = WorkspaceEditorState()
        #expect(state.open(first))
        state.document?.text = "one edited"
        #expect(state.document?.isDirty == true)
        #expect(state.open(second))
        #expect(try String(contentsOf: first, encoding: .utf8) == "one edited")
        #expect(state.document?.url == second)
        #expect(state.document?.isMarkdown == false)
    }

    @Test func followsDiskChanges() throws {
        let url = try makeFile("knowledge.md", "v1")
        let state = WorkspaceEditorState()
        state.open(url)

        try writeLater("v2", to: url)
        state.refreshFromDisk()
        #expect(state.document?.text == "v2")
        #expect(state.document?.conflict == nil)

        state.document?.text = "mine"
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        state.refreshFromDisk()
        #expect(state.document?.conflict == .changedOnDisk)
        state.document?.keepMine()
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
        #expect(state.document?.conflict == nil)

        try FileManager.default.removeItem(at: url)
        state.refreshFromDisk()
        #expect(state.document == nil)
    }

    @Test func keepsEditsWhenFileIsDeleted() throws {
        let url = try makeFile("draft.txt", "start")
        let state = WorkspaceEditorState()
        state.open(url)
        state.document?.text = "unsaved"
        try FileManager.default.removeItem(at: url)
        state.refreshFromDisk()
        #expect(state.document?.conflict == .deletedOnDisk)
        state.document?.keepMine()
        #expect(try String(contentsOf: url, encoding: .utf8) == "unsaved")
    }
}
