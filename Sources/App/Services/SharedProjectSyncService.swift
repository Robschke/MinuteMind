// Purpose: SharedProjectSync, keeps every Shared Project's workspace repo in step with its git
//          remote in the background (commit, fetch, rebase, push), resolves conflicts with a
//          merge commit, replays shared knowledge updates in a clean worktree, and publishes a
//          status per project for the sidebar icon and the workspace branch row. SharedRepoGit
//          holds the blocking git steps.
// Dependencies: Sources/App/Models/SharedProject.swift (SharedSyncStatus),
//               Sources/App/Services/SharedSyncCommit.swift (what gets committed, held back files),
//               Sources/App/Services/SharedSyncMerge.swift (in-memory merge and its rules),
//               Sources/App/Services/WorkspaceGitService.swift (repo state),
//               Sources/App/Services/GitAvailability.swift (no git calls while git is missing),
//               Sources/App/Services/KnowledgeCurationService.swift (the replayed agent step and
//               the cleanup of emptied knowledge files)
// RBAC: None (membership is enforced by the git host).
// Dependents: Sources/App/ViewModels/AppViewModel.swift (sharedSync),
//             Sources/App/ViewModels/AppViewModel+SharedSync.swift (wiring, shared replay),
//             Sources/App/Views/ProjectsSidebarView.swift, WorkspaceGitBranchBar (status),
//             Tests/SharedProjectBackendTests.swift, Tests/SharedProjectSyncMergeTests.swift
// Notes: Never force-pushes.
//        Syncs only on main or master with no merge or rebase running, because the app commits
//        and rebases on the checked-out branch; anywhere else the status asks to switch back.
//        Every change that is not gitignored is committed before the pull (SharedSyncCommit).
//        A rebase conflict is aborted at once; the conflict is then resolved in memory and
//        pushed as a merge commit (SharedSyncMerge), and the next rebase only fast-forwards.
//        What the rules and Claude cannot resolve is reported with the first conflicting file.
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
    /// How often one sync resolves conflicts before it reports them (the remote kept changing).
    @ObservationIgnored var maxMergeRounds = 3
    /// The size limits of the commit step.
    @ObservationIgnored var largeFileLimits = SharedLargeFiles.Limits.standard
    /// Merges one conflicted text file (Claude by default; the app passes the chosen model).
    @ObservationIgnored var mergeText: @MainActor (SharedTextMerge) async throws -> String = { merge in
        try await SharedTextMerger.mergeWithClaude(merge, model: "sonnet")
    }
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
        let limits = largeFileLimits
        var outcome = await Self.offMain { SharedRepoGit.sync(repo: repo, limits: limits) }
        var rounds = 0
        while case .conflicts(let plan) = outcome {
            rounds += 1
            guard rounds <= maxMergeRounds else {
                outcome = .problem("Sync conflict in \(plan.firstPath)")
                break
            }
            outcome = await resolveConflicts(plan, repo: repo)
        }
        let heldBack = await Self.offMain { SharedLargeFiles.heldBack(in: repo, limits: limits) }
        finish(projectID, repo: repo, outcome, heldBack: heldBack)
        return outcome
    }

    /// Resolves a conflict by the rules and Claude, pushes the merge commit and syncs again
    /// (which then fast-forwards). A conflict nothing resolves is reported by its file.
    private func resolveConflicts(_ plan: SharedMergePlan, repo: URL) async -> SharedRepoGit.SyncOutcome {
        guard plan.unsupported.isEmpty else { return .problem("Sync conflict in \(plan.firstPath)") }
        let resolutions = await Self.offMain {
            plan.conflicts.map { conflict in
                (path: conflict.path, resolution: SharedMergeRules.resolve(conflict) { SharedRepoGit.blobText($0, in: repo) })
            }
        }
        if let stuck = resolutions.first(where: { $0.resolution == .unresolvable }) {
            NSLog("SharedSync: \(stuck.path) cannot be merged automatically (\(repo.lastPathComponent))")
            return .problem("Sync conflict in \(stuck.path)")
        }
        var merged: [String: String] = [:]
        for item in resolutions {
            guard case .text(let merge, _) = item.resolution else { continue }
            do {
                merged[item.path] = try await mergeText(merge)
            } catch {
                NSLog("SharedSync: merging \(item.path) failed: \(error.localizedDescription) (\(repo.lastPathComponent))")
                return .problem("Sync conflict in \(item.path)")
            }
        }
        let message = SharedMergeRules.commitMessage(for: resolutions)
        let limits = largeFileLimits
        let mergedFiles = merged
        return await Self.offMain {
            guard case .success(let branch) = SharedRepoGit.syncBranch(of: repo) else {
                return .problem(SharedRepoGit.switchBackMessage)
            }
            switch SharedRepoGit.commitAndPushMerge(repo: repo, branch: branch, plan: plan, resolutions: resolutions,
                                                     merged: mergedFiles, message: message) {
            case .pushed:
                NSLog("SharedSync: pushed a merge of \(resolutions.map(\.path).joined(separator: ", ")) (\(repo.lastPathComponent))")
                return SharedRepoGit.sync(repo: repo, limits: limits)
            case .rejected:
                return SharedRepoGit.sync(repo: repo, limits: limits)
            case .failed(let text):
                return .problem(text)
            }
        }
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

    private func finish(_ projectID: UUID, repo: URL, _ outcome: SharedRepoGit.SyncOutcome, heldBack: [SharedHeldBackFile]) {
        switch outcome {
        case .synced(let pulled):
            statuses[projectID] = SharedSyncStatus(state: .idle, lastSynced: Date(), heldBack: heldBack)
            if pulled { onPulled(projectID, repo) }
        case .problem(let message):
            markProblem(projectID, message)
            statuses[projectID]?.heldBack = heldBack
        case .conflicts(let plan):
            markProblem(projectID, "Sync conflict in \(plan.firstPath)")
            statuses[projectID]?.heldBack = heldBack
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
        /// The rebase conflicted (and was aborted); the plan holds the in-memory merge to resolve.
        case conflicts(SharedMergePlan)
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

    /// Commit everything not gitignored (held back files aside), fetch, rebase onto the remote
    /// branch (what is left uncommitted is stashed and restored), push. Retries when the push is
    /// rejected because someone pushed in between. A conflict comes back as the in-memory merge
    /// to resolve. Never forces.
    static func sync(repo: URL, attempts: Int = 3, limits: SharedLargeFiles.Limits = .standard) -> SyncOutcome {
        let branch: String
        switch syncBranch(of: repo) {
        case .success(let name): branch = name
        case .failure(let problem): return .problem(problem.text)
        }
        guard run(["remote", "get-url", remote], in: repo).succeeded else { return .problem("This workspace has no remote to sync with") }
        if let failure = commitWorkspaceChanges(repo: repo, limits: limits) {
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
                    if let plan = mergePlan(repo: repo, upstream: upstream) { return .conflicts(plan) }
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

    /// git without a terminal: no credential prompt, no editor, English messages. `environment`
    /// adds variables (e.g. GIT_INDEX_FILE).
    static func run(_ arguments: [String], in directory: URL, environment: [String: String] = [:]) -> WorkspaceGit.Output {
        let output = runData(arguments, in: directory, environment: environment)
        return WorkspaceGit.Output(status: output.status,
                                   stdout: String(decoding: output.data, as: UTF8.self),
                                   stderr: output.stderr)
    }

    /// Like `run`, with stdout as raw bytes (blob contents that may be binary).
    static func runData(
        _ arguments: [String], in directory: URL, environment extra: [String: String] = [:]
    ) -> (status: Int32, data: Data, stderr: String, succeeded: Bool) {
        guard GitAvailability.isInstalled else {
            return (-1, Data(), GitAvailability.missingMessage, false)
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
        environment.merge(extra) { _, new in new }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, Data(), error.localizedDescription, false) }
        // Read before waiting, so a full pipe never blocks git.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, String(decoding: stderr, as: UTF8.self), process.terminationStatus == 0)
    }
}
