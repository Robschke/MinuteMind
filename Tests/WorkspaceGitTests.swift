// Purpose: Tests for WorkspaceGit: status parsing, and that switching, leaving changes on a
//          branch and restoring them never lose an uncommitted change.
// Dependencies: Sources/App/Services/WorkspaceGitService.swift, /usr/bin/git
// Notes: Each test builds its own throwaway repo in the temp directory.

import Foundation
import Testing
@testable import MinuteMindApp

@Suite("WorkspaceGit Tests")
struct WorkspaceGitTests {

    /// A repo on `main` with one committed file, notes.md = "base".
    private func makeRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], repo)
        git(["config", "user.email", "test@example.com"], repo)
        git(["config", "user.name", "Test"], repo)
        try write("base", "notes.md", repo)
        git(["add", "-A"], repo)
        git(["commit", "-q", "-m", "base"], repo)
        return repo
    }

    @discardableResult
    private func git(_ arguments: [String], _ repo: URL) -> WorkspaceGit.Output {
        WorkspaceGit.run(arguments, in: repo)
    }

    private func write(_ text: String, _ name: String, _ repo: URL) throws {
        try text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, _ repo: URL) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("parses branch, detached head, fresh repo and changed files")
    func parsesStatus() {
        let onBranch = WorkspaceGit.parseStatus("""
            # branch.oid 0123456789abcdef
            # branch.head feature/x
            1 .M N... 100644 100644 100644 a b notes.md
            ? new.md
            """)
        #expect(onBranch?.head == .branch("feature/x"))
        #expect(onBranch?.changedFiles == 2)
        #expect(onBranch?.hasCommits == true)

        let detached = WorkspaceGit.parseStatus("# branch.oid 0123456789abcdef\n# branch.head (detached)\n")
        #expect(detached?.head == .detached("0123456"))

        let fresh = WorkspaceGit.parseStatus("# branch.oid (initial)\n# branch.head main\n")
        #expect(fresh?.hasCommits == false)
        #expect(WorkspaceGit.parseStatus("") == nil)
    }

    @Test("reads branches and the uncommitted count of a real repo")
    func readsState() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        git(["branch", "side"], repo)
        try write("changed", "notes.md", repo)

        let state = try #require(WorkspaceGit.state(of: repo))
        #expect(state.head == .branch("main"))
        #expect(state.changedFiles == 1)
        #expect(Set(state.branches) == ["main", "side"])
        #expect(state.operation == nil)
        #expect(WorkspaceGit.state(of: FileManager.default.temporaryDirectory) == nil)
    }

    @Test("a change that does not clash comes along to the other branch")
    func takesChangesAlong() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        git(["branch", "side"], repo)
        try write("draft", "draft.md", repo)

        #expect(WorkspaceGit.switchBranch(to: "side", in: repo) == .switched)
        #expect(WorkspaceGit.state(of: repo)?.head == .branch("side"))
        #expect(read("draft.md", repo) == "draft")
    }

    @Test("git refuses a clashing switch, names the file and keeps the change")
    func refusesClashingSwitch() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        git(["switch", "-q", "-c", "side"], repo)
        try write("side version", "notes.md", repo)
        git(["commit", "-q", "-am", "side"], repo)
        git(["switch", "-q", "main"], repo)
        try write("unsaved work", "notes.md", repo)

        #expect(WorkspaceGit.switchBranch(to: "side", in: repo) == .conflicts(["notes.md"]))
        #expect(WorkspaceGit.state(of: repo)?.head == .branch("main"))
        #expect(read("notes.md", repo) == "unsaved work")
    }

    @Test("changes left on a branch come back when switching back to it")
    func leavesAndRestoresChanges() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        git(["switch", "-q", "-c", "side"], repo)
        try write("side version", "notes.md", repo)
        git(["commit", "-q", "-am", "side"], repo)
        git(["switch", "-q", "main"], repo)
        try write("unsaved work", "notes.md", repo)
        try write("new file", "untracked.md", repo)

        #expect(WorkspaceGit.leaveChangesAndSwitch(from: "main", to: "side", in: repo) == .switched)
        #expect(read("notes.md", repo) == "side version")
        #expect(read("untracked.md", repo) == nil)
        #expect(WorkspaceGit.restoreLeftChanges(on: "side", in: repo) == .nothing)

        #expect(WorkspaceGit.switchBranch(to: "main", in: repo) == .switched)
        #expect(WorkspaceGit.restoreLeftChanges(on: "main", in: repo) == .restored)
        #expect(read("notes.md", repo) == "unsaved work")
        #expect(read("untracked.md", repo) == "new file")
        #expect(WorkspaceGit.stashRef(for: "main", in: repo) == nil)
    }

    @Test("left changes stay stashed when the branch already has uncommitted changes")
    func keepsStashOnDirtyTree() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        git(["branch", "side"], repo)
        try write("unsaved work", "notes.md", repo)
        #expect(WorkspaceGit.leaveChangesAndSwitch(from: "main", to: "side", in: repo) == .switched)
        #expect(WorkspaceGit.switchBranch(to: "main", in: repo) == .switched)
        try write("other work", "other.md", repo)

        guard case .kept = WorkspaceGit.restoreLeftChanges(on: "main", in: repo) else {
            Issue.record("expected the stash to be kept")
            return
        }
        #expect(WorkspaceGit.stashRef(for: "main", in: repo) != nil)
        #expect(read("notes.md", repo) == "base")
    }

    @Test("new branch names are validated and the branch starts at the current commit")
    func createsBranch() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("draft", "draft.md", repo)

        #expect(WorkspaceGit.problem(withNewBranchName: "", existing: ["main"], in: repo) != nil)
        #expect(WorkspaceGit.problem(withNewBranchName: "main", existing: ["main"], in: repo) != nil)
        #expect(WorkspaceGit.problem(withNewBranchName: "has space", existing: ["main"], in: repo) != nil)
        #expect(WorkspaceGit.problem(withNewBranchName: "feature/plan", existing: ["main"], in: repo) == nil)

        #expect(WorkspaceGit.createBranch("feature/plan", in: repo) == .switched)
        #expect(WorkspaceGit.state(of: repo)?.head == .branch("feature/plan"))
        #expect(read("draft.md", repo) == "draft")
    }

    @Test("the app's own commits pause on a detached HEAD and while a switch runs")
    @MainActor
    func appCommitsPause() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(ProjectRepositoryService.acceptsAppCommits(repo))

        ProjectRepositoryService.switchingRepos.insert(repo.standardizedFileURL.path)
        #expect(!ProjectRepositoryService.acceptsAppCommits(repo))
        try write("during switch", "notes.md", repo)
        #expect(!ProjectRepositoryService.git(["commit", "-qam", "app"], in: repo))
        ProjectRepositoryService.switchingRepos.remove(repo.standardizedFileURL.path)

        git(["switch", "-q", "--detach"], repo)
        #expect(!WorkspaceGit.isOnBranchWithoutOperation(repo))
        #expect(!ProjectRepositoryService.git(["commit", "-qam", "app"], in: repo))
        git(["switch", "-q", "main"], repo)
        #expect(ProjectRepositoryService.git(["commit", "-qam", "app"], in: repo))
    }

    @Test("before a switch the app commits only its own folders, the user's work stays uncommitted")
    func commitsAppManagedChanges() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("knowledge"), withIntermediateDirectories: true)
        try write("fact", "knowledge/topic.md", repo)
        try write("user work", "notes.md", repo)

        WorkspaceGit.commitAppManagedChanges(in: repo)

        #expect(WorkspaceGit.state(of: repo)?.changedFiles == 1)
        #expect(git(["log", "-1", "--format=%s"], repo).stdout.contains("MinuteMind: workspace updates"))
        WorkspaceGit.commitAppManagedChanges(in: repo)
        #expect(git(["rev-list", "--count", "HEAD"], repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("counts commits made on a detached HEAD that no branch holds")
    func countsCommitsOnNoBranch() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        git(["switch", "-q", "--detach"], repo)
        #expect(WorkspaceGit.commitsOnNoBranch(in: repo) == 0)
        try write("detached", "notes.md", repo)
        git(["commit", "-qam", "detached"], repo)
        #expect(WorkspaceGit.commitsOnNoBranch(in: repo) == 1)
    }
}
