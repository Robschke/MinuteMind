// Purpose: Tests for the workspace file tree's file operations: move into folders, rename, new
//          file and folder, duplicate, name clashes, refusing a folder into itself, the managed
//          parts of the repo, and the editor following a moved file.
// Dependencies: Sources/App/Supporting/WorkspaceFileOperations.swift,
//               Sources/App/Supporting/WorkspaceEditorStore.swift (documentMoved)

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("WorkspaceFileOperations Tests")
struct WorkspaceFileOperationsTests {
    typealias Ops = WorkspaceFileOperations

    /// A fresh repo-like folder: notes/a.md, notes/sub/b.md, plans/, c.txt.
    private func makeRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-tree-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: repo.appendingPathComponent("notes/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("plans"), withIntermediateDirectories: true)
        try "a".write(to: repo.appendingPathComponent("notes/a.md"), atomically: true, encoding: .utf8)
        try "b".write(to: repo.appendingPathComponent("notes/sub/b.md"), atomically: true, encoding: .utf8)
        try "c".write(to: repo.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        return repo
    }

    private func exists(_ repo: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(path).path)
    }

    private func text(_ repo: URL, _ path: String) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// Replace in tests deletes instead of trashing, so the user's Trash stays clean.
    private func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }

    @Test func movesFilesAndFoldersIntoAFolder() throws {
        let repo = try makeRepo()
        let outcome = try Ops.transfer(
            [repo.appendingPathComponent("c.txt"), repo.appendingPathComponent("notes/sub")],
            into: repo.appendingPathComponent("plans"), copy: false, resolution: .keepBoth, discard: remove)
        #expect(outcome.failure == nil)
        #expect(outcome.moves.count == 2)
        #expect(exists(repo, "plans/c.txt"))
        #expect(exists(repo, "plans/sub/b.md"))
        #expect(!exists(repo, "c.txt"))
        #expect(!exists(repo, "notes/sub"))
    }

    @Test func movesToTheRootAndSkipsItemsAlreadyThere() throws {
        let repo = try makeRepo()
        let outcome = try Ops.transfer(
            [repo.appendingPathComponent("notes/a.md"), repo.appendingPathComponent("c.txt")],
            into: repo, copy: false, resolution: .keepBoth, discard: remove)
        #expect(outcome.moves.map(\.to.lastPathComponent) == ["a.md"])
        #expect(exists(repo, "a.md"))
        #expect(exists(repo, "c.txt"))
    }

    @Test func movingAFolderTakesSelectedChildrenAlong() throws {
        let repo = try makeRepo()
        let outcome = try Ops.transfer(
            [repo.appendingPathComponent("notes/sub/b.md"), repo.appendingPathComponent("notes")],
            into: repo.appendingPathComponent("plans"), copy: false, resolution: .keepBoth, discard: remove)
        #expect(outcome.moves.count == 1)
        #expect(exists(repo, "plans/notes/sub/b.md"))
    }

    @Test func refusesAFolderIntoItselfOrItsDescendant() throws {
        let repo = try makeRepo()
        let notes = repo.appendingPathComponent("notes")
        #expect(throws: Ops.Failure.intoItself("notes")) {
            try Ops.transfer([notes], into: notes, copy: false, resolution: .keepBoth, discard: remove)
        }
        #expect(throws: Ops.Failure.intoItself("notes")) {
            try Ops.transfer([repo.appendingPathComponent("c.txt"), notes], into: notes.appendingPathComponent("sub"),
                             copy: false, resolution: .keepBoth, discard: remove)
        }
        // Nothing moved, not even the file that could have.
        #expect(exists(repo, "c.txt"))
        #expect(exists(repo, "notes/sub/b.md"))
    }

    @Test func nameClashKeepsBothOrReplaces() throws {
        let repo = try makeRepo()
        try "other".write(to: repo.appendingPathComponent("plans/c.txt"), atomically: true, encoding: .utf8)
        let source = repo.appendingPathComponent("c.txt")
        let plans = repo.appendingPathComponent("plans")
        #expect(Ops.clashes([source], into: plans, copy: false).map(\.lastPathComponent) == ["c.txt"])

        let kept = try Ops.transfer([source], into: plans, copy: false, resolution: .keepBoth, discard: remove)
        #expect(kept.moves.first?.to.lastPathComponent == "c 2.txt")
        #expect(text(repo, "plans/c.txt") == "other")
        #expect(text(repo, "plans/c 2.txt") == "c")

        try "new".write(to: source, atomically: true, encoding: .utf8)
        let replaced = try Ops.transfer([source], into: plans, copy: false, resolution: .replace, discard: remove)
        #expect(replaced.moves.first?.to.lastPathComponent == "c.txt")
        #expect(text(repo, "plans/c.txt") == "new")
    }

    @Test func neverReplacesAFolderHoldingTheMovedItem() throws {
        let repo = try makeRepo()
        // notes/sub/notes clashes with the repo's notes/ when moved to the root; replacing would
        // trash the item's own ancestor.
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("notes/sub/notes"), withIntermediateDirectories: true)
        let outcome = try Ops.transfer([repo.appendingPathComponent("notes/sub/notes")], into: repo,
                                       copy: false, resolution: .replace, discard: remove)
        #expect(outcome.moves.first?.to.lastPathComponent == "notes 2")
        #expect(exists(repo, "notes/a.md"))
    }

    @Test func copyLeavesTheSourceAndNumbersACopyInItsOwnFolder() throws {
        let repo = try makeRepo()
        let source = repo.appendingPathComponent("notes/a.md")
        let out = try Ops.transfer([source], into: repo, copy: true, resolution: .keepBoth, discard: remove)
        #expect(out.moves.first?.to.lastPathComponent == "a.md")
        #expect(exists(repo, "notes/a.md"))
        let same = try Ops.transfer([source], into: repo.appendingPathComponent("notes"), copy: true, resolution: .replace, discard: remove)
        #expect(same.moves.first?.to.lastPathComponent == "a 2.md")
        #expect(text(repo, "notes/a.md") == "a")
    }

    @Test func renamesAndValidatesNames() throws {
        let repo = try makeRepo()
        let renamed = try Ops.rename(repo.appendingPathComponent("notes/a.md"), to: "  plan.md ")
        #expect(renamed.lastPathComponent == "plan.md")
        #expect(exists(repo, "notes/plan.md"))

        #expect(throws: Ops.Failure.nameTaken("sub")) { try Ops.rename(renamed, to: "sub") }
        #expect(throws: Ops.Failure.emptyName) { try Ops.rename(renamed, to: "   ") }
        #expect(throws: Ops.Failure.invalidName("a/b")) { try Ops.rename(renamed, to: "a/b") }
        #expect(try Ops.validatedName(".env") == ".env")
        #expect(try Ops.rename(renamed, to: "plan.md") == renamed)

        // A change of case only (case-insensitive volumes report the target as existing).
        let upper = try Ops.rename(renamed, to: "Plan.md")
        #expect(upper.lastPathComponent == "Plan.md")
        let names = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("notes").path)
        #expect(names.contains("Plan.md"))
        #expect(!names.contains("plan.md"))
    }

    @Test func createsNewFilesFoldersAndDuplicates() throws {
        let repo = try makeRepo()
        let folder = try Ops.createFolder(in: repo)
        let second = try Ops.createFolder(in: repo)
        #expect(folder.lastPathComponent == "untitled folder")
        #expect(second.lastPathComponent == "untitled folder 2")
        #expect(Ops.isDirectory(second))

        let file = try Ops.createFile(in: folder)
        #expect(file.lastPathComponent == "untitled.md")
        #expect(try Ops.createFile(in: folder).lastPathComponent == "untitled 2.md")

        let copy = try Ops.duplicate(repo.appendingPathComponent("c.txt"))
        #expect(copy.lastPathComponent == "c copy.txt")
        #expect(try Ops.duplicate(repo.appendingPathComponent("c.txt")).lastPathComponent == "c copy 2.txt")
        let folderCopy = try Ops.duplicate(repo.appendingPathComponent("notes"))
        #expect(folderCopy.lastPathComponent == "notes copy")
        #expect(exists(repo, "notes copy/sub/b.md"))
    }

    @Test func importNumbersTakenNames() throws {
        let repo = try makeRepo()
        let outside = try makeRepo()
        let outcome = Ops.importItems([outside.appendingPathComponent("c.txt"), outside.appendingPathComponent("notes")], into: repo)
        #expect(outcome.moves.map(\.to.lastPathComponent) == ["c 2.txt", "notes 2"])
        #expect(exists(outside, "c.txt"))
    }

    @Test func protectsTheManagedPartsOfTheRepo() throws {
        let repo = try makeRepo()
        func url(_ path: String) -> URL { repo.appendingPathComponent(path) }
        #expect(Ops.lockReason(for: url("meetings"), in: repo) != nil)
        #expect(Ops.lockReason(for: url("meetings/2026-10-01-sync"), in: repo) != nil)
        #expect(Ops.lockReason(for: url("recordings/2026-10-01-0930-x/transcript.md"), in: repo) != nil)
        #expect(Ops.lockReason(for: url("knowledge"), in: repo) != nil)
        #expect(Ops.lockReason(for: url("CLAUDE.md"), in: repo) != nil)
        #expect(Ops.lockReason(for: repo, in: repo) != nil)
        #expect(Ops.lockReason(for: url("knowledge/pricing.md"), in: repo) == nil)
        #expect(Ops.lockReason(for: url("notes/CLAUDE.md"), in: repo) == nil)
        #expect(Ops.lockReason(for: url("notes/meetings"), in: repo) == nil)
        #expect(Ops.lockReason(for: url(".minutemind"), in: repo) != nil)
        #expect(Ops.lockReason(for: url(".git/config"), in: repo) != nil)
        #expect(Ops.lockReason(for: url(".gitignore"), in: repo) == nil)
        #expect(Ops.lockReason(for: url(".claude"), in: repo) == nil)

        #expect(Ops.dropRefusal(into: url("meetings"), in: repo) != nil)
        #expect(Ops.dropRefusal(into: url("recordings/2026-10-01-0930-x"), in: repo) != nil)
        #expect(Ops.dropRefusal(into: url(".minutemind"), in: repo) != nil)
        #expect(Ops.dropRefusal(into: url(".claude"), in: repo) == nil)
        #expect(Ops.dropRefusal(into: repo, in: repo) == nil)
        #expect(Ops.dropRefusal(into: url("knowledge"), in: repo) == nil)
    }

    @Test func pathsAndRelocation() {
        let repo = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
        let file = URL(fileURLWithPath: "/tmp/repo/notes/sub/b.md")
        #expect(Ops.relativePath(file, in: repo) == "notes/sub/b.md")
        // Trailing slashes do not matter.
        #expect(Ops.isSameOrInside(file, URL(fileURLWithPath: "/tmp/repo/notes/", isDirectory: true)))
        #expect(!Ops.isSameOrInside(URL(fileURLWithPath: "/tmp/repo/notes-old/x"), URL(fileURLWithPath: "/tmp/repo/notes")))
        let move = Ops.Move(from: URL(fileURLWithPath: "/tmp/repo/notes"), to: URL(fileURLWithPath: "/tmp/repo/plans/notes"))
        #expect(Ops.relocated(file, by: [move])?.path == "/tmp/repo/plans/notes/sub/b.md")
        #expect(Ops.relocated(URL(fileURLWithPath: "/tmp/repo/c.txt"), by: [move]) == nil)
    }

    @MainActor
    @Test func editorFollowsAMovedFileOrFolder() throws {
        let repo = try makeRepo()
        let state = WorkspaceEditorState()
        #expect(state.open(repo.appendingPathComponent("notes/sub/b.md")))
        state.document?.text = "b edited"

        // The folder holding the open file moves; the unsaved edit goes to the new place.
        let outcome = try Ops.transfer([repo.appendingPathComponent("notes")], into: repo.appendingPathComponent("plans"),
                                       copy: false, resolution: .keepBoth, discard: remove)
        for move in outcome.moves { state.documentMoved(from: move.from, to: move.to) }
        #expect(state.document?.url.path == repo.appendingPathComponent("plans/notes/sub/b.md").path)
        state.refreshFromDisk()
        #expect(state.document != nil)
        #expect(state.document?.conflict == nil)
        state.save()
        #expect(text(repo, "plans/notes/sub/b.md") == "b edited")
        #expect(!exists(repo, "notes"))

        // A rename of the file itself; an unrelated move leaves it alone.
        let open = try #require(state.document?.url)
        let renamed = try Ops.rename(open, to: "brief.md")
        state.documentMoved(from: open, to: renamed)
        state.documentMoved(from: repo.appendingPathComponent("c.txt"), to: repo.appendingPathComponent("plans/c.txt"))
        #expect(state.document?.url.lastPathComponent == "brief.md")
        state.refreshFromDisk()
        #expect(state.document?.conflict == nil)
    }
}
