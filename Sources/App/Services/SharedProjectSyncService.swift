// Purpose: SharedProjectSync, keeps every Shared Project's workspace repo in step with its git
//          remote in the background (fetch, rebase, push), replays shared knowledge updates in a
//          clean worktree, and publishes a status per project for the sidebar icon and the
//          workspace branch row. SharedRepoGit holds the blocking git steps.
// Dependencies: Sources/App/Models/SharedProject.swift (SharedSyncStatus),
//               Sources/App/Services/WorkspaceGitService.swift (repo state, app-managed commits),
//               Sources/App/Services/GitAvailability.swift (no git calls while git is missing),
//               Sources/App/Services/KnowledgeCurationService.swift (the replayed agent step and
//               the cleanup of emptied knowledge files)
// RBAC: None (membership is enforced by the git host).
// Dependents: Sources/App/ViewModels/AppViewModel.swift (sharedSync),
//             Sources/App/ViewModels/AppViewModel+SharedSync.swift (wiring, shared replay),
//             Sources/App/Views/ProjectsSidebarView.swift, WorkspaceGitBranchBar (status),
//             Tests/SharedProjectBackendTests.swift
// Notes: Never force-pushes.
//        Syncs only on main or master with no merge or rebase running, because the app commits
//        and rebases on the checked-out branch; anywhere else the status asks to switch back.
//        A rebase conflict is aborted at once and reported with the first conflicting file;
//        hand-edited files are not merged automatically.
//        Shared knowledge is replayed, not merged: the agent step runs in a detached worktree at
//        the remote's state (only tracked files, so private/ does not exist there), the result
//        is committed and pushed, and a rejected push starts over on the new remote state. The
//        worktree lives outside the workspace (worktreeDirectory), so no path inside the
//        workspace leads to private/ from it.
//        Work per project is serialized (one sync or replay at a time); git runs on a global
//        dispatch queue, never on the main thread, with GIT_TERMINAL_PROMPT=0 so a missing
//        credential fails instead of hanging.

import Foundation

@MainActor
@Observable
final class SharedProjectSync {
    /// Status per project id; a project without an entry is idle and never synced.
    private(set) var statuses: [UUID: SharedSyncStatus] = [:]

    /// Where a project's clean worktree for shared knowledge lives (set by the app to a folder
    /// under Application Support).
    @ObservationIgnored var worktreeDirectory: (UUID) -> URL = { projectID in
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MinuteMind-SharedCuration", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
    }
    /// Called after a sync brought commits from the remote (the app reindexes knowledge).
    @ObservationIgnored var onPulled: (UUID, URL) -> Void = { _, _ in }
    /// How often a replay starts over after its push was rejected.
    @ObservationIgnored var maxReplayAttempts = 3
    static let periodicInterval: Duration = .seconds(180)

    @ObservationIgnored private var tails: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var queuedSyncs: Set<UUID> = []
    @ObservationIgnored private var loop: Task<Void, Never>?

    func status(for projectID: UUID) -> SharedSyncStatus {
        statuses[projectID] ?? SharedSyncStatus()
    }

    /// Updates a project's status (used by the sync loop and the publishing flow).
    func setStatus(_ status: SharedSyncStatus, for projectID: UUID) {
        statuses[projectID] = status
    }

    // MARK: - Periodic sync

    /// Syncs every Shared Project now and then every three minutes while the app runs.
    func start(repositories: @escaping @MainActor () -> [(projectID: UUID, repo: URL)]) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                for (projectID, repo) in repositories() { self?.requestSync(projectID, repo: repo) }
                try? await Task.sleep(for: Self.periodicInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Queues a sync of one project; a sync already waiting for it covers this request too.
    func requestSync(_ projectID: UUID, repo: URL) {
        guard !queuedSyncs.contains(projectID) else { return }
        queuedSyncs.insert(projectID)
        Task { _ = await self.syncNow(projectID, repo: repo) }
    }

    /// Fetches, rebases and pushes one project, after any sync or replay already running for it.
    @discardableResult
    func syncNow(_ projectID: UUID, repo: URL) async -> SharedRepoGit.SyncOutcome {
        await serialized(projectID) {
            self.queuedSyncs.remove(projectID)
            return await self.performSync(projectID, repo: repo)
        }
    }

    private func performSync(_ projectID: UUID, repo: URL) async -> SharedRepoGit.SyncOutcome {
        markSyncing(projectID)
        let outcome = await Self.offMain { SharedRepoGit.sync(repo: repo) }
        finish(projectID, repo: repo, outcome)
        return outcome
    }

    // MARK: - Shared knowledge replay

    /// Runs one shared knowledge update the replay way: push the main checkout (so the item's
    /// folder is on the remote), reset the clean worktree to the remote's state, run `step` there,
    /// commit knowledge/ and push; a rejected push starts over on the new state. Afterwards the
    /// main checkout is brought up to date. Returns true when the remote has the result.
    @discardableResult
    func replayKnowledge(
        _ projectID: UUID, repo: URL, message: String,
        step: @escaping @MainActor (URL) async throws -> Void
    ) async -> Bool {
        await serialized(projectID) {
            self.queuedSyncs.remove(projectID)
            let first = await self.performSync(projectID, repo: repo)
            guard case .synced = first else { return false }
            self.markSyncing(projectID)
            let worktree = self.worktreeDirectory(projectID)
            for _ in 0..<max(1, self.maxReplayAttempts) {
                let prepared = await Self.offMain { SharedRepoGit.prepareCleanWorktree(repo: repo, at: worktree) }
                guard case .ready(let branch) = prepared else {
                    if case .problem(let text) = prepared { self.markProblem(projectID, text) }
                    return false
                }
                do {
                    try await step(worktree)
                } catch {
                    self.markProblem(projectID, "Shared knowledge update failed: \(error.localizedDescription)")
                    return false
                }
                let pushed = await Self.offMain {
                    SharedRepoGit.commitAndPushKnowledge(worktree: worktree, branch: branch, message: message)
                }
                switch pushed {
                case .pushed, .nothingToCommit:
                    _ = await self.performSync(projectID, repo: repo)
                    return true
                case .rejected:
                    continue
                case .failed(let text):
                    self.markProblem(projectID, text)
                    return false
                }
            }
            self.markProblem(projectID, "Shared knowledge was not updated: the remote kept changing. It is retried with the next update.")
            return false
        }
    }

    // MARK: - Status

    private func markSyncing(_ projectID: UUID) {
        var status = self.status(for: projectID)
        status.state = .syncing
        statuses[projectID] = status
    }

    private func markProblem(_ projectID: UUID, _ message: String) {
        var status = self.status(for: projectID)
        status.state = .problem(message)
        statuses[projectID] = status
    }

    private func finish(_ projectID: UUID, repo: URL, _ outcome: SharedRepoGit.SyncOutcome) {
        switch outcome {
        case .synced(let pulled):
            statuses[projectID] = SharedSyncStatus(state: .idle, lastSynced: Date())
            if pulled { onPulled(projectID, repo) }
        case .problem(let message):
            markProblem(projectID, message)
        }
    }

    // MARK: - Helpers

    /// Runs `work` after everything queued for the project before it.
    private func serialized<T: Sendable>(_ projectID: UUID, _ work: @escaping @MainActor () async -> T) async -> T {
        let previous = tails[projectID]
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        tails[projectID] = Task { _ = await task.value }
        return await task.value
    }

    /// Blocking git work on a global queue, so neither the main thread nor the concurrency
    /// pool waits on a network round trip.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}

/// The blocking git steps of a Shared Project's sync. Every function waits for git processes, so
/// callers run them off the main actor (SharedProjectSync.offMain).
enum SharedRepoGit {
    static let remote = "origin"
    static let syncBranches: Set<String> = ["main", "master"]
    static let switchBackMessage = "Switch back to main to sync"

    enum SyncOutcome: Equatable, Sendable {
        /// `pulled`: commits from the remote arrived (files may have changed).
        case synced(pulled: Bool)
        case problem(String)
    }

    enum WorktreeOutcome: Equatable, Sendable {
        /// Reset to the remote's state of this branch.
        case ready(branch: String)
        case problem(String)
    }

    enum PushOutcome: Equatable, Sendable {
        case pushed
        case nothingToCommit
        /// Someone pushed first; start over on the new state.
        case rejected
        case failed(String)
    }

    /// The branch to sync, or the reason not to: main or master, checked out, no git operation.
    static func syncBranch(of repo: URL) -> Result<String, ProblemText> {
        guard let state = WorkspaceGit.state(of: repo) else { return .failure(ProblemText("This workspace is not a git repository")) }
        guard let branch = state.branchName, syncBranches.contains(branch), state.operation == nil else {
            return .failure(ProblemText(switchBackMessage))
        }
        return .success(branch)
    }

    /// Fetch, rebase onto the remote branch (uncommitted changes stashed and restored), push.
    /// Retries when the push is rejected because someone pushed in between. Never forces.
    static func sync(repo: URL, attempts: Int = 3) -> SyncOutcome {
        let branch: String
        switch syncBranch(of: repo) {
        case .success(let name): branch = name
        case .failure(let problem): return .problem(problem.text)
        }
        guard run(["remote", "get-url", remote], in: repo).succeeded else { return .problem("This workspace has no remote to sync with") }
        // What the app wrote while its commits paused belongs in this sync.
        if let failure = WorkspaceGit.commitAppManagedChanges(in: repo) {
            return .problem("Could not commit the workspace's changes: \(failure)")
        }
        let upstream = "\(remote)/\(branch)"
        var pulled = false
        for _ in 0..<max(1, attempts) {
            let fetch = run(["fetch", "--quiet", remote], in: repo)
            guard fetch.succeeded else { return .problem("Could not reach the remote: \(firstLine(fetch.stderr))") }
            let hasUpstream = refExists(upstream, in: repo)
            if hasUpstream {
                let before = head(of: repo)
                let rebase = run(["rebase", "--autostash", upstream], in: repo)
                if !rebase.succeeded {
                    let conflicted = run(["diff", "--name-only", "--diff-filter=U"], in: repo).stdout
                        .split(separator: "\n").map(String.init)
                    if WorkspaceGit.operation(in: repo) == .rebasing { _ = run(["rebase", "--abort"], in: repo) }
                    if let file = conflicted.first { return .problem("Sync conflict in \(file)") }
                    return .problem("Could not bring in the remote's changes: \(firstLine(rebase.stderr))")
                }
                if head(of: repo) != before { pulled = true }
            }
            let ahead = hasUpstream
                ? Int(run(["rev-list", "--count", "\(upstream)..HEAD"], in: repo).stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                : (head(of: repo).isEmpty ? 0 : 1)
            guard ahead > 0 else { return .synced(pulled: pulled) }
            let push = run(["push", "--quiet", remote, "HEAD:refs/heads/\(branch)"], in: repo)
            // A successful push also moves the remote-tracking branch.
            if push.succeeded { return .synced(pulled: pulled) }
            guard isRejection(push.stderr) else { return .problem("Could not push: \(firstLine(push.stderr))") }
        }
        return .problem("The remote kept changing during the sync. It is retried in a few minutes.")
    }

    /// Fetches and makes `worktree` a detached checkout of the remote branch with nothing else
    /// in it: created on first use (or when broken), otherwise reset hard and cleaned.
    static func prepareCleanWorktree(repo: URL, at worktree: URL) -> WorktreeOutcome {
        let branch: String
        switch syncBranch(of: repo) {
        case .success(let name): branch = name
        case .failure(let problem): return .problem(problem.text)
        }
        let fetch = run(["fetch", "--quiet", remote], in: repo)
        guard fetch.succeeded else { return .problem("Could not reach the remote: \(firstLine(fetch.stderr))") }
        let upstream = "\(remote)/\(branch)"
        guard refExists(upstream, in: repo) else { return .problem("The remote has no \(branch) branch yet") }

        let fileManager = FileManager.default
        let usable = fileManager.fileExists(atPath: worktree.appendingPathComponent(".git").path)
            && run(["rev-parse", "--is-inside-work-tree"], in: worktree).succeeded
        if !usable {
            try? fileManager.removeItem(at: worktree)
            _ = run(["worktree", "prune"], in: repo)
            try? fileManager.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
            let add = run(["worktree", "add", "--detach", "--force", worktree.path, upstream], in: repo)
            guard add.succeeded else { return .problem("Could not prepare the shared knowledge checkout: \(firstLine(add.stderr))") }
        }
        let reset = run(["reset", "--quiet", "--hard", upstream], in: worktree)
        guard reset.succeeded else { return .problem("Could not prepare the shared knowledge checkout: \(firstLine(reset.stderr))") }
        _ = run(["clean", "-fdq"], in: worktree)
        return .ready(branch: branch)
    }

    /// Commits knowledge/ in the worktree (emptied files removed) and pushes it to the branch.
    static func commitAndPushKnowledge(worktree: URL, branch: String, message: String) -> PushOutcome {
        _ = run(["add", "-A", "--", "knowledge"], in: worktree)
        if run(["diff", "--cached", "--quiet", "--", "knowledge"], in: worktree).succeeded { return .nothingToCommit }
        let commit = run(["commit", "-q", "-m", message], in: worktree)
        guard commit.succeeded else { return .failed("Could not commit shared knowledge: \(firstLine(commit.stderr + commit.stdout))") }
        let push = run(["push", "--quiet", remote, "HEAD:refs/heads/\(branch)"], in: worktree)
        if push.succeeded { return .pushed }
        return isRejection(push.stderr) ? .rejected : .failed("Could not push shared knowledge: \(firstLine(push.stderr))")
    }

    // MARK: - Helpers

    struct ProblemText: Error, Equatable {
        let text: String
        init(_ text: String) { self.text = text }
    }

    static func head(of repo: URL) -> String {
        run(["rev-parse", "--verify", "--quiet", "HEAD"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func refExists(_ ref: String, in repo: URL) -> Bool {
        run(["rev-parse", "--verify", "--quiet", ref], in: repo).succeeded
    }

    /// git's wording when the remote moved on since the last fetch.
    static func isRejection(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("[rejected]") || text.contains("non-fast-forward") || text.contains("fetch first")
            || text.contains("cannot lock ref")
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let cleaned = line.replacingOccurrences(of: "error: ", with: "").replacingOccurrences(of: "fatal: ", with: "")
        return cleaned.isEmpty ? "git did not say why." : cleaned
    }

    /// git without a terminal: no credential prompt, no editor, English messages.
    static func run(_ arguments: [String], in directory: URL) -> WorkspaceGit.Output {
        guard GitAvailability.isInstalled else {
            return WorkspaceGit.Output(status: -1, stdout: "", stderr: GitAvailability.missingMessage)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return WorkspaceGit.Output(status: -1, stdout: "", stderr: error.localizedDescription) }
        // Read before waiting, so a full pipe never blocks git.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return WorkspaceGit.Output(status: process.terminationStatus,
                                   stdout: String(decoding: stdout, as: UTF8.self),
                                   stderr: String(decoding: stderr, as: UTF8.self))
    }
}
