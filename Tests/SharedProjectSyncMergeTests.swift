// Purpose: Tests for what a Shared Project's sync commits (everything not gitignored, large files
//          held back until allowed) and how it resolves conflicts (an edit wins over a deletion,
//          text clashes are merged and pushed as a merge commit, the rest is reported), against a
//          local bare repo with two member clones. No Claude runs: the text merge is a closure.
// Dependencies: Sources/App/Services/SharedProjectSyncService.swift (SharedProjectSync, SharedRepoGit),
//               Sources/App/Services/SharedSyncCommit.swift, Sources/App/Services/SharedSyncMerge.swift,
//               Sources/App/Views/SharedProjectStatusViews.swift (SharedSyncText)

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("Shared Project sync commit and merge Tests")
struct SharedProjectSyncMergeTests {
    // MARK: - Helpers

    private struct MergeFailed: Error {}

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) -> WorkspaceGit.Output {
        SharedRepoGit.run(arguments, in: directory)
    }

    private func write(_ text: String, to path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String, in repo: URL) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    private func exists(_ path: String, in repo: URL) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(path).path)
    }

    private func delete(_ path: String, in repo: URL) throws {
        try FileManager.default.removeItem(at: repo.appendingPathComponent(path))
    }

    /// A bare origin on main and two member clones sharing decisions.md and notes.md.
    private func makeRemote() throws -> (origin: URL, robin: URL, anna: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-merge-\(UUID().uuidString)", isDirectory: true)
        let origin = root.appendingPathComponent("origin.git", isDirectory: true)
        let robin = root.appendingPathComponent("robin", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: robin, withIntermediateDirectories: true)
        git(["init", "-q", "--bare", "-b", "main"], in: origin)
        git(["init", "-q", "-b", "main"], in: robin)
        git(["config", "user.name", "Robin"], in: robin)
        git(["config", "user.email", "robin@example.com"], in: robin)
        try write("/private/\n/jobs/\n", to: ".gitignore", in: robin)
        try write("# Decisions\n\n- Start.\n", to: "knowledge/decisions.md", in: robin)
        try write("# Notes\n\n- First.\n", to: "knowledge/notes.md", in: robin)
        git(["add", "-A"], in: robin)
        git(["commit", "-q", "-m", "Start"], in: robin)
        git(["remote", "add", "origin", origin.path], in: robin)
        #expect(git(["push", "-q", "origin", "main"], in: robin).succeeded)
        git(["clone", "-q", origin.path, "anna"], in: root)
        let anna = root.appendingPathComponent("anna", isDirectory: true)
        git(["config", "user.name", "Anna"], in: anna)
        git(["config", "user.email", "anna@example.com"], in: anna)
        return (origin, robin, anna)
    }

    private func makeSync(merge: @escaping @MainActor (SharedTextMerge) async throws -> String) -> SharedProjectSync {
        let sync = SharedProjectSync()
        sync.mergeText = merge
        return sync
    }

    // MARK: - Commit step

    @Test("Sync commits every change that is not gitignored, deletions included")
    func commitsEverything() throws {
        let (origin, robin, anna) = try makeRemote()
        try write("# Roadmap\n", to: "plans/roadmap.md", in: robin)
        try delete("knowledge/decisions.md", in: robin)
        try write("mine only\n", to: "private/files/idea.md", in: robin)
        try write("my job\n", to: "jobs/weekly.md", in: robin)

        #expect(SharedRepoGit.sync(repo: robin) == .synced(pulled: false))
        #expect(git(["status", "--porcelain"], in: robin).stdout.isEmpty)
        #expect(git(["show", "main:plans/roadmap.md"], in: origin).succeeded)
        #expect(SharedRepoGit.sync(repo: anna) == .synced(pulled: true))
        #expect(exists("plans/roadmap.md", in: anna))
        #expect(!exists("knowledge/decisions.md", in: anna))
        #expect(!exists("private", in: anna))
        #expect(!exists("jobs", in: anna))
    }

    @Test("Large files are held back until allowed, and always above the hard limit")
    func largeFiles() throws {
        let (origin, robin, _) = try makeRemote()
        let limits = SharedLargeFiles.Limits(soft: 1_000, hard: 5_000)
        try write(String(repeating: "a", count: 2_000), to: "files/medium.txt", in: robin)
        try write(String(repeating: "b", count: 6_000), to: "files/huge.txt", in: robin)
        try write("small\n", to: "files/small.txt", in: robin)

        #expect(SharedRepoGit.sync(repo: robin, limits: limits) == .synced(pulled: false))
        #expect(git(["show", "main:files/small.txt"], in: origin).succeeded)
        #expect(!git(["show", "main:files/medium.txt"], in: origin).succeeded)
        #expect(!git(["show", "main:files/huge.txt"], in: origin).succeeded)
        #expect(SharedLargeFiles.heldBack(in: robin, limits: limits).map(\.path).sorted() == ["files/huge.txt", "files/medium.txt"])
        #expect(SharedLargeFiles.heldBack(in: robin, limits: limits).first { $0.path == "files/medium.txt" }?.size == 2_000)

        SharedLargeFiles.allow("files/medium.txt", in: robin)
        SharedLargeFiles.allow("files/huge.txt", in: robin)
        #expect(SharedLargeFiles.allowed(in: robin) == ["files/medium.txt", "files/huge.txt"])
        #expect(SharedRepoGit.sync(repo: robin, limits: limits) == .synced(pulled: false))
        #expect(git(["show", "main:files/medium.txt"], in: origin).succeeded)
        #expect(!git(["show", "main:files/huge.txt"], in: origin).succeeded)
        #expect(SharedLargeFiles.heldBack(in: robin, limits: limits).map(\.path) == ["files/huge.txt"])
        // The allowed list stays on this Mac.
        #expect(!git(["ls-files", "--", ".git"], in: robin).stdout.contains("minutemind-large-files"))
    }

    @Test("A sync status carries the held back files")
    func statusCarriesHeldBack() async throws {
        let (_, robin, _) = try makeRemote()
        try write(String(repeating: "a", count: 2_000), to: "files/medium.txt", in: robin)
        let sync = makeSync { _ in throw MergeFailed() }
        sync.largeFileLimits = SharedLargeFiles.Limits(soft: 1_000, hard: 5_000)
        let projectID = UUID()
        #expect(await sync.syncNow(projectID, repo: robin) == .synced(pulled: false))
        #expect(sync.status(for: projectID).heldBack == [SharedHeldBackFile(path: "files/medium.txt", size: 2_000)])
        #expect(!sync.status(for: projectID).hasProblem)
    }

    // MARK: - Conflicts

    @Test("An edit wins over a deletion, whichever member deleted")
    func editWinsOverDeletion() async throws {
        let (origin, robin, anna) = try makeRemote()
        // Robin deletes decisions.md while Anna edits it; Robin edits notes.md while Anna deletes it.
        try delete("knowledge/decisions.md", in: robin)
        try write("# Notes\n\n- First.\n- Robin's addition.\n", to: "knowledge/notes.md", in: robin)
        try write("# Decisions\n\n- Start.\n- Anna's addition.\n", to: "knowledge/decisions.md", in: anna)
        try delete("knowledge/notes.md", in: anna)

        var merges = 0
        let sync = makeSync { _ in merges += 1; throw MergeFailed() }
        #expect(await sync.syncNow(UUID(), repo: robin) == .synced(pulled: false))
        #expect(await sync.syncNow(UUID(), repo: anna) == .synced(pulled: true))
        #expect(merges == 0)
        #expect(read("knowledge/decisions.md", in: anna) == "# Decisions\n\n- Start.\n- Anna's addition.\n")
        #expect(read("knowledge/notes.md", in: anna) == "# Notes\n\n- First.\n- Robin's addition.\n")
        #expect(git(["show", "main:knowledge/decisions.md"], in: origin).stdout.contains("Anna's addition"))
        #expect(git(["show", "main:knowledge/notes.md"], in: origin).stdout.contains("Robin's addition"))
        #expect(git(["status", "--porcelain"], in: anna).stdout.isEmpty)
        #expect(WorkspaceGit.operation(in: anna) == nil)

        #expect(await sync.syncNow(UUID(), repo: robin) == .synced(pulled: true))
        #expect(read("knowledge/decisions.md", in: robin) == read("knowledge/decisions.md", in: anna))
    }

    @Test("A text clash is merged, pushed as a merge commit, and both members end up equal")
    func textClashMerged() async throws {
        let (origin, robin, anna) = try makeRemote()
        try write("# Decisions\n\n- Robin's version.\n", to: "knowledge/decisions.md", in: robin)
        try write("# Decisions\n\n- Anna's version.\n", to: "knowledge/decisions.md", in: anna)

        var received: [SharedTextMerge] = []
        let sync = makeSync { merge in
            received.append(merge)
            return "# Decisions\n\n- Robin's version.\n- Anna's version.\n"
        }
        #expect(await sync.syncNow(UUID(), repo: robin) == .synced(pulled: false))
        let projectID = UUID()
        #expect(await sync.syncNow(projectID, repo: anna) == .synced(pulled: true))

        #expect(received == [SharedTextMerge(path: "knowledge/decisions.md", base: "# Decisions\n\n- Start.\n",
                                             mine: "# Decisions\n\n- Anna's version.\n",
                                             theirs: "# Decisions\n\n- Robin's version.\n")])
        let merged = "# Decisions\n\n- Robin's version.\n- Anna's version.\n"
        #expect(read("knowledge/decisions.md", in: anna) == merged)
        #expect(git(["show", "main:knowledge/decisions.md"], in: origin).stdout == merged)
        #expect(git(["log", "-1", "--format=%P", "main"], in: origin).stdout.split(separator: " ").count == 2)
        #expect(git(["log", "-1", "--format=%B", "main"], in: origin).stdout.contains("Merged by Claude: knowledge/decisions.md"))
        #expect(git(["status", "--porcelain"], in: anna).stdout.isEmpty)
        #expect(WorkspaceGit.operation(in: anna) == nil)
        #expect(sync.status(for: projectID).state == .idle)

        #expect(await sync.syncNow(UUID(), repo: robin) == .synced(pulled: true))
        #expect(read("knowledge/decisions.md", in: robin) == merged)
    }

    @Test("A failed merge reports the file and leaves the folder as it was")
    func failedMergeReported() async throws {
        let (_, robin, anna) = try makeRemote()
        try write("# Decisions\n\n- Robin's version.\n", to: "knowledge/decisions.md", in: robin)
        try write("# Decisions\n\n- Anna's version.\n", to: "knowledge/decisions.md", in: anna)
        let sync = makeSync { _ in throw MergeFailed() }
        #expect(await sync.syncNow(UUID(), repo: robin) == .synced(pulled: false))
        let projectID = UUID()
        #expect(await sync.syncNow(projectID, repo: anna) == .problem("Sync conflict in knowledge/decisions.md"))
        #expect(sync.status(for: projectID).state == .problem("Sync conflict in knowledge/decisions.md"))
        #expect(read("knowledge/decisions.md", in: anna) == "# Decisions\n\n- Anna's version.\n")
        #expect(WorkspaceGit.operation(in: anna) == nil)
        #expect(WorkspaceGit.state(of: anna)?.branchName == "main")
    }

    @Test("A binary clash is reported, never sent to Claude")
    func binaryClashReported() async throws {
        let (_, robin, anna) = try makeRemote()
        try Data([0, 1, 2, 3]).write(to: robin.appendingPathComponent("files/logo.bin").creatingParent())
        #expect(SharedRepoGit.sync(repo: robin) == .synced(pulled: false))
        #expect(SharedRepoGit.sync(repo: anna) == .synced(pulled: true))
        try Data([0, 9, 9, 9]).write(to: robin.appendingPathComponent("files/logo.bin"))
        try Data([0, 7, 7, 7]).write(to: anna.appendingPathComponent("files/logo.bin"))

        var merges = 0
        let sync = makeSync { _ in merges += 1; return "" }
        #expect(await sync.syncNow(UUID(), repo: robin) == .synced(pulled: false))
        #expect(await sync.syncNow(UUID(), repo: anna) == .problem("Sync conflict in files/logo.bin"))
        #expect(merges == 0)
    }

    // MARK: - Pure parts

    @Test("Claude's answer: the file between the tags, refused with conflict markers or without tags")
    func mergedFileParsing() throws {
        #expect(try SharedTextMerger.mergedFile(in: "Here it is:\n<merged>\n# A\n\n- b\n</merged>\n") == "# A\n\n- b\n")
        #expect(throws: SharedTextMerger.MergeError.conflictMarkers) {
            try SharedTextMerger.mergedFile(in: "<merged>\n<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n</merged>")
        }
        #expect(throws: SharedTextMerger.MergeError.noMergedFile) { try SharedTextMerger.mergedFile(in: "# A\n") }
    }

    @Test("Held back texts")
    func heldBackTexts() {
        #expect(SharedSyncText.heldBackLabel(count: 1) == "1 file not synced")
        #expect(SharedSyncText.heldBackLabel(count: 3) == "3 files not synced")
        #expect(SharedSyncText.size(72 * 1_048_576) == "72 MB")
        #expect(SharedHeldBackFile(path: "a", size: 72 * 1_048_576).canSyncAnyway)
        #expect(!SharedHeldBackFile(path: "a", size: 130 * 1_048_576).canSyncAnyway)
    }
}

private extension URL {
    /// Creates the parent folder and returns the URL, for writing data to a new path.
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
