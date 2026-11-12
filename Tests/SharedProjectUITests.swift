// Purpose: Tests for the Shared Project UI rules: which folders of the workspace file tree can be
//          published, how private/ is protected in a Shared Project (and not in a Private one),
//          private meetings listed newest first, and the sync texts of the branch row and sidebar.
// Dependencies: Sources/App/Supporting/WorkspaceFileOperations.swift (publishablePath,
//               lockReason, dropRefusal), FileNode (Sources/App/Views/WorkspaceFileTreeView.swift),
//               Sources/App/Views/SharedProjectStatusViews.swift (SharedSyncText),
//               Sources/App/Models/SharedProject.swift (SharedSyncStatus)

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("Shared Project UI")
struct SharedProjectUITests {
    typealias Ops = WorkspaceFileOperations

    /// A Shared Project's workspace: published and private meetings and recordings.
    private func makeRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-shared-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        for folder in ["meetings/2026-11-10-weekly-robin", "private/meetings/2026-11-01-a", "private/meetings/2026-11-12-b",
                       "private/recordings/2026-11-12-0930-idea", "private/knowledge", "notes"] {
            try fm.createDirectory(at: repo.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "t".write(to: repo.appendingPathComponent("private/meetings/2026-11-12-b/transcript.md"), atomically: true, encoding: .utf8)
        try "k".write(to: repo.appendingPathComponent("private/knowledge/pricing.md"), atomically: true, encoding: .utf8)
        return repo
    }

    @Test func onlyFoldersDirectlyInPrivateMeetingsAndRecordingsArePublishable() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        func path(_ relative: String) -> String? { Ops.publishablePath(repo.appendingPathComponent(relative), in: repo) }
        #expect(path("private/meetings/2026-11-12-b") == "private/meetings/2026-11-12-b")
        #expect(path("private/recordings/2026-11-12-0930-idea") == "private/recordings/2026-11-12-0930-idea")
        #expect(path("private/meetings") == nil)
        #expect(path("private") == nil)
        #expect(path("private/meetings/2026-11-12-b/transcript.md") == nil)
        #expect(path("private/knowledge/pricing.md") == nil)
        #expect(path("meetings/2026-11-10-weekly-robin") == nil)
        #expect(path("notes") == nil)
    }

    @Test func protectsPrivateInASharedProject() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        func url(_ path: String) -> URL { repo.appendingPathComponent(path) }
        func locked(_ path: String) -> Bool { Ops.lockReason(for: url(path), in: repo, isShared: true) != nil }
        func refused(_ path: String) -> Bool { Ops.dropRefusal(into: url(path), in: repo, isShared: true) != nil }

        #expect(locked("private"))
        #expect(locked("private/meetings"))
        #expect(locked("private/recordings"))
        #expect(locked("private/knowledge"))
        #expect(locked("private/meetings/2026-11-12-b"))
        #expect(locked("private/meetings/2026-11-12-b/transcript.md"))
        #expect(locked("private/recordings/2026-11-12-0930-idea"))
        #expect(!locked("private/knowledge/pricing.md"))
        #expect(locked("meetings/2026-11-10-weekly-robin"))
        #expect(!locked("notes"))

        #expect(refused("private"))
        #expect(refused("private/meetings"))
        #expect(refused("private/meetings/2026-11-12-b"))
        #expect(refused("private/recordings"))
        #expect(!refused("private/knowledge"))
        #expect(!refused("notes"))
    }

    @Test func nothingLeavesPrivateByDragInASharedProject() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        func url(_ path: String) -> URL { repo.appendingPathComponent(path) }
        let knowledge = [url("private/knowledge/pricing.md")]
        #expect(Ops.privateLeakRefusal(knowledge, into: url("notes"), in: repo, isShared: true) != nil)
        #expect(Ops.privateLeakRefusal(knowledge, into: repo, in: repo, isShared: true) != nil)
        #expect(Ops.privateLeakRefusal(knowledge, into: url("private/knowledge"), in: repo, isShared: true) == nil)
        #expect(Ops.privateLeakRefusal([url("notes")], into: url("meetings"), in: repo, isShared: true) == nil)
        #expect(Ops.privateLeakRefusal(knowledge, into: url("notes"), in: repo, isShared: false) == nil)
    }

    @Test func aPrivateProjectsOwnPrivateFolderStaysTheUsers() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        func url(_ path: String) -> URL { repo.appendingPathComponent(path) }
        #expect(Ops.lockReason(for: url("private"), in: repo) == nil)
        #expect(Ops.lockReason(for: url("private/meetings/2026-11-12-b"), in: repo) == nil)
        #expect(Ops.dropRefusal(into: url("private/meetings"), in: repo) == nil)
    }

    @Test func privateMeetingsAreListedNewestFirst() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let open: Set<String> = [WorkspaceTreeExpansion.key(repo.appendingPathComponent("private")),
                                 WorkspaceTreeExpansion.key(repo.appendingPathComponent("private/meetings"))]
        let tree = FileNode.load(repo, open: open)
        let privateFolder = try #require(tree.first { $0.name == "private" })
        let meetings = try #require(privateFolder.children.first { $0.name == "meetings" })
        #expect(meetings.children.map(\.name) == ["2026-11-12-b", "2026-11-01-a"])
        #expect(privateFolder.children.map(\.name) == ["knowledge", "meetings", "recordings"])
    }

    @Test func syncLabels() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func synced(_ secondsAgo: TimeInterval) -> String {
            SharedSyncText.label(for: SharedSyncStatus(state: .idle, lastSynced: now.addingTimeInterval(-secondsAgo)), now: now)
        }
        #expect(synced(10) == "Synced just now")
        #expect(synced(-30) == "Synced just now")
        #expect(synced(60) == "Synced 1 min ago")
        #expect(synced(150) == "Synced 2 min ago")
        #expect(synced(59 * 60) == "Synced 59 min ago")
        #expect(synced(3 * 3600 + 5) == "Synced 3 h ago")
        #expect(synced(50 * 3600) == "Synced 2 d ago")
        #expect(SharedSyncText.label(for: SharedSyncStatus(), now: now) == "Not synced yet")
        #expect(SharedSyncText.label(for: SharedSyncStatus(state: .syncing, lastSynced: now), now: now) == "Syncing…")
        #expect(SharedSyncText.label(for: SharedSyncStatus(state: .problem("No network"), lastSynced: now), now: now) == "No network")
    }

    @Test func markTooltipNamesTheProblem() {
        #expect(SharedSyncText.markTooltip(for: SharedSyncStatus()) == "Shared Project")
        #expect(SharedSyncText.markTooltip(for: SharedSyncStatus(state: .problem("Sign in to GitHub again"))) == "Sign in to GitHub again")
    }
}
