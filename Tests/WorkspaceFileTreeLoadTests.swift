// Purpose: Tests for how the workspace file tree reads the repo: the top level is always
//          complete, closed folders stay unread however large, open folders are read, dotfiles
//          stay out, meetings are listed newest first.
// Dependencies: FileNode (Sources/App/Views/WorkspaceFileTreeView.swift),
//               WorkspaceTreeExpansion.key (Sources/App/Views/WorkspaceFileOutlineView.swift)

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("Workspace file tree loading")
struct WorkspaceFileTreeLoadTests {
    /// A repo with a large cloned project in code/, then folders that sort after it.
    private func makeRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        let fm = FileManager.default
        let big = repo.appendingPathComponent("code/big-repo/src")
        try fm.createDirectory(at: big, withIntermediateDirectories: true)
        for index in 0..<4000 {
            try Data().write(to: big.appendingPathComponent("file\(index).ts"))
        }
        for folder in ["knowledge", "meetings/2026-10-01-a", "meetings/2026-10-14-b", "notes", ".git"] {
            try fm.createDirectory(at: repo.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: repo.appendingPathComponent("CLAUDE.md"))
        try Data().write(to: repo.appendingPathComponent(".DS_Store"))
        return repo
    }

    @Test func theTopLevelIsCompleteAndClosedFoldersAreNotRead() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let tree = FileNode.load(repo, open: [])
        #expect(tree.map(\.name) == ["code", "knowledge", "meetings", "notes", "CLAUDE.md"])
        let code = try #require(tree.first)
        #expect(code.isDirectory)
        #expect(!code.isLoaded)
        #expect(code.children.isEmpty)
    }

    @Test func openFoldersAreReadAndMeetingsListNewestFirst() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let open: Set<String> = [
            WorkspaceTreeExpansion.key(repo.appendingPathComponent("code")),
            WorkspaceTreeExpansion.key(repo.appendingPathComponent("code/big-repo")),
            WorkspaceTreeExpansion.key(repo.appendingPathComponent("code/big-repo/src")),
            WorkspaceTreeExpansion.key(repo.appendingPathComponent("meetings")),
        ]
        let tree = FileNode.load(repo, open: open)
        let src = try #require(tree.first?.children.first?.children.first)
        #expect(src.name == "src")
        #expect(src.isLoaded)
        #expect(src.children.count == 4000)
        // Everything after the large folder is still there.
        #expect(tree.map(\.name) == ["code", "knowledge", "meetings", "notes", "CLAUDE.md"])
        let meetings = try #require(tree.first { $0.name == "meetings" })
        #expect(meetings.children.map(\.name) == ["2026-10-14-b", "2026-10-01-a"])
    }
}
