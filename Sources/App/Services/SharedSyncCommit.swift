// Purpose: The commit step of a Shared Project's sync: everything that is not gitignored is
//          committed before the pull, except files over the size limit that the user has not
//          allowed (held back, listed in the branch row), and git repositories nested in the
//          workspace. Also keeps this Mac's list of large files the user allowed.
// Dependencies: Sources/App/Services/SharedProjectSyncService.swift (SharedRepoGit.run, the sync
//               that calls this), Sources/App/Services/WorkspaceGitService.swift (branch check)
// RBAC: None (membership is enforced by the git host).
// Dependents: Sources/App/Services/SharedProjectSyncService.swift (sync, status),
//             Sources/App/Views/SharedProjectStatusViews.swift (held back popover),
//             Sources/App/ViewModels/AppViewModel+SharedSync.swift (Sync anyway),
//             Tests/SharedProjectSyncMergeTests.swift
// Notes: Above 100 MB a file is held back even when allowed: GitHub refuses such a push, and a
//        local commit holding one would block every later push of the project.
//        The allowed list lives in .git/info/, so it stays on this Mac and is never pushed.
//        Nested git repositories are skipped silently: committing one would push only a gitlink
//        nobody can check out; code repos belong in the gitignored code/.

import Foundation

/// A file the sync keeps on this Mac because it is too large.
struct SharedHeldBackFile: Equatable, Sendable, Identifiable {
    let path: String
    let size: Int64

    var id: String { path }
    /// Sync anyway can lift the hold up to the host's limit, not beyond.
    var canSyncAnyway: Bool { size <= SharedLargeFiles.Limits.standard.hard }
}

enum SharedLargeFiles {
    struct Limits: Equatable, Sendable {
        /// Larger files are held back until the user allows them.
        var soft: Int64
        /// Larger files are always held back.
        var hard: Int64

        static let standard = Limits(soft: 50 * 1024 * 1024, hard: 100 * 1024 * 1024)
    }

    private static func listURL(in repo: URL) -> URL {
        repo.appendingPathComponent(".git/info/minutemind-large-files")
    }

    /// Paths the user allowed with Sync anyway on this Mac.
    static func allowed(in repo: URL) -> Set<String> {
        guard let text = try? String(contentsOf: listURL(in: repo), encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    static func allow(_ path: String, in repo: URL) {
        var paths = allowed(in: repo)
        paths.insert(path)
        let url = listURL(in: repo)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (paths.sorted().joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Changed or new files (not gitignored) the sync would not commit because of their size.
    static func heldBack(in repo: URL, limits: Limits = .standard) -> [SharedHeldBackFile] {
        let allowedPaths = allowed(in: repo)
        return changedFiles(in: repo).compactMap { path in
            let url = repo.appendingPathComponent(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
            if size > limits.hard || (size > limits.soft && !allowedPaths.contains(path)) {
                return SharedHeldBackFile(path: path, size: size)
            }
            return nil
        }
    }

    /// Paths with a change git would commit: modified, added or untracked files (each file of an
    /// untracked folder), not deletions.
    private static func changedFiles(in repo: URL) -> [String] {
        let status = SharedRepoGit.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: repo).stdout
        var paths: [String] = []
        var entries = status.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            let path = String(entry.dropFirst(3))
            // A rename or copy is followed by its source path.
            if code.contains("R") || code.contains("C") { _ = entries.popFirst() }
            if code.contains("D") { continue }
            paths.append(path)
        }
        return paths
    }
}

extension SharedRepoGit {
    /// Commits every change that is not gitignored, without held back files and nested
    /// repositories. Returns git's reason when the commit failed, nil otherwise (also when there
    /// was nothing to commit).
    static func commitWorkspaceChanges(repo: URL, limits: SharedLargeFiles.Limits = .standard) -> String? {
        guard WorkspaceGit.isOnBranchWithoutOperation(repo) else { return nil }
        let held = SharedLargeFiles.heldBack(in: repo, limits: limits).map(\.path)
        let add = run(["add", "-A"], in: repo)
        guard add.succeeded else { return firstLine(add.stderr) }
        let gitlinks = run(["diff", "--cached", "--raw", "-z", "--diff-filter=AM"], in: repo).stdout
            .split(separator: "\0").map(String.init)
            .chunkedPairs()
            .filter { $0.meta.split(separator: " ").dropFirst().first == "160000" }
            .map(\.path)
        let skipped = held + gitlinks
        if !skipped.isEmpty { _ = run(["reset", "-q", "--"] + skipped, in: repo) }
        guard !run(["diff", "--cached", "--quiet"], in: repo).succeeded else { return nil }
        let commit = run(["commit", "-q", "-m", "Workspace changes"], in: repo)
        return commit.succeeded ? nil : firstLine(commit.stderr + commit.stdout)
    }
}

private extension Array where Element == String {
    /// `git diff --raw -z` alternates a metadata field (":old new oldsha newsha status") and a path.
    func chunkedPairs() -> [(meta: String, path: String)] {
        stride(from: 0, to: count - 1, by: 2).map { (self[$0], self[$0 + 1]) }
    }
}
