// Purpose: WorkspaceGit, the small slice of git the workspace shows and does: which branch is
//          checked out, how many files changed, whether a merge or rebase is in progress, the
//          local branches, and switching or creating a branch without ever losing a change.
// Dependencies: Foundation (Process, /usr/bin/git), Sources/App/Services/GitAvailability.swift (git missing)
// Used by: Sources/App/Views/WorkspaceGitBranchBar.swift, Sources/App/Services/ProjectRepositoryService.swift
//          (acceptsAppCommits), Tests/WorkspaceGitTests.swift
// Notes: Everything here blocks on a git process, so callers run it off the main actor.
//        git runs with LC_ALL=C (its messages are parsed) and without a terminal prompt.
//        Switching is plain `git switch`: git itself refuses when an uncommitted change would be
//        overwritten, and nothing here ever forces a checkout. "Leave changes on a branch" is a
//        stash (untracked files included) whose message names the branch; switching back to that
//        branch restores it when the working tree is clean, otherwise the stash is kept.

import Foundation

struct WorkspaceGitState: Equatable, Sendable {
    enum Head: Equatable, Sendable {
        case branch(String)
        /// Detached HEAD: the short commit id.
        case detached(String)
    }

    /// A git operation that has to be finished in the terminal before switching.
    enum Operation: String, Equatable, Sendable {
        case merging, rebasing, cherryPicking = "cherry-picking", reverting

        var noun: String {
            switch self {
            case .merging: return "merge"
            case .rebasing: return "rebase"
            case .cherryPicking: return "cherry-pick"
            case .reverting: return "revert"
            }
        }
    }

    var head: Head
    /// Changed, staged, untracked and conflicted files, as VS Code counts them.
    var changedFiles: Int
    /// False on a fresh repo whose branch has no commit yet.
    var hasCommits: Bool
    var operation: Operation?
    /// Local branches, most recent commit first.
    var branches: [String]

    var branchName: String? {
        if case .branch(let name) = head { return name }
        return nil
    }
}

enum WorkspaceGit {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { status == 0 }
    }

    enum SwitchOutcome: Equatable, Sendable {
        case switched
        /// git refused because these uncommitted files would be overwritten by the target branch.
        case conflicts([String])
        case failed(String)
    }

    enum RestoreOutcome: Equatable, Sendable {
        /// No changes were left on this branch.
        case nothing
        case restored
        /// Changes are left on this branch but could not be restored; the stash is kept.
        case kept(String)
    }

    // MARK: - Reading

    /// The repo's state, or nil when the folder is not a git repo.
    static func state(of repo: URL) -> WorkspaceGitState? {
        let status = run(["status", "--porcelain=v2", "--branch"], in: repo)
        guard status.succeeded, var state = parseStatus(status.stdout) else { return nil }
        state.operation = operation(in: repo)
        let refs = run(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads/"], in: repo)
        state.branches = refs.stdout.split(separator: "\n").map(String.init)
        return state
    }

    /// Parses `git status --porcelain=v2 --branch`; branches and operation stay empty.
    static func parseStatus(_ output: String) -> WorkspaceGitState? {
        var oid: String?
        var headName: String?
        var changed = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.oid ") {
                oid = String(line.dropFirst("# branch.oid ".count))
            } else if line.hasPrefix("# branch.head ") {
                headName = String(line.dropFirst("# branch.head ".count))
            } else if let first = line.first, "12u?".contains(first), line.dropFirst().first == " " {
                changed += 1
            }
        }
        guard let headName else { return nil }
        let hasCommits = oid != nil && oid != "(initial)"
        let head: WorkspaceGitState.Head = headName == "(detached)"
            ? .detached(String((oid ?? "").prefix(7)))
            : .branch(headName)
        return WorkspaceGitState(head: head, changedFiles: changed, hasCommits: hasCommits, operation: nil, branches: [])
    }

    /// HEAD names a branch and no merge, rebase, cherry-pick or revert runs. Reads files only, so
    /// it is cheap enough to ask before every commit the app makes.
    static func isOnBranchWithoutOperation(_ repo: URL) -> Bool {
        let head = repo.appendingPathComponent(".git/HEAD")
        guard let text = try? String(contentsOf: head, encoding: .utf8) else { return true }
        return text.hasPrefix("ref: ") && operation(in: repo) == nil
    }

    static func operation(in repo: URL) -> WorkspaceGitState.Operation? {
        let gitDir = repo.appendingPathComponent(".git", isDirectory: true)
        let exists = { (name: String) in FileManager.default.fileExists(atPath: gitDir.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebasing }
        if exists("MERGE_HEAD") { return .merging }
        if exists("CHERRY_PICK_HEAD") { return .cherryPicking }
        if exists("REVERT_HEAD") { return .reverting }
        return nil
    }

    // MARK: - Switching

    /// Plain `git switch`: uncommitted changes come along unless one would be overwritten.
    static func switchBranch(to target: String, in repo: URL) -> SwitchOutcome {
        let result = run(["switch", target], in: repo)
        if result.succeeded { return .switched }
        let files = conflictingFiles(in: result.stderr)
        return files.isEmpty ? .failed(firstLine(of: result.stderr)) : .conflicts(files)
    }

    /// Stashes every uncommitted change (untracked files too) under `current`'s name, then switches.
    static func leaveChangesAndSwitch(from current: String, to target: String, in repo: URL) -> SwitchOutcome {
        let stash = run(["stash", "push", "--include-untracked", "-m", stashMessage(for: current)], in: repo)
        guard stash.succeeded else { return .failed(firstLine(of: stash.stderr)) }
        let outcome = switchBranch(to: target, in: repo)
        if outcome != .switched {
            // Back to where the user was: the changes return to the branch they were made on.
            let pop = run(["stash", "pop"], in: repo)
            if !pop.succeeded {
                return .failed("Could not switch to \(target). Your changes are still saved in git stash as \"\(stashMessage(for: current))\".")
            }
        }
        return outcome
    }

    /// Restores the changes once left on `branch`, newest first, when the working tree is clean.
    static func restoreLeftChanges(on branch: String, in repo: URL) -> RestoreOutcome {
        guard let ref = stashRef(for: branch, in: repo) else { return .nothing }
        guard state(of: repo)?.changedFiles == 0 else {
            return .kept("Your changes from \(branch) are still saved. They come back when \(branch) has no other changes.")
        }
        let apply = run(["stash", "apply", ref], in: repo)
        guard apply.succeeded else {
            return .kept("Your changes from \(branch) could not be restored automatically. They are kept in git stash as \"\(stashMessage(for: branch))\".")
        }
        _ = run(["stash", "drop", ref], in: repo)
        return .restored
    }

    /// The stash ref (stash@{n}) holding changes left on `branch`, newest first.
    static func stashRef(for branch: String, in repo: URL) -> String? {
        let list = run(["stash", "list", "--format=%gd%x09%gs"], in: repo)
        let suffix = ": " + stashMessage(for: branch)
        for line in list.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[1].hasSuffix(suffix) { return parts[0] }
        }
        return nil
    }

    static func stashMessage(for branch: String) -> String { "MinuteMind: changes left on \(branch)" }

    /// Commits on a detached HEAD that no branch contains; switching away leaves them behind.
    static func commitsOnNoBranch(in repo: URL) -> Int {
        Int(run(["rev-list", "--count", "HEAD", "--not", "--branches"], in: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The folders MinuteMind writes itself (meeting and recording mirrors, knowledge, indexes).
    static let appManagedPaths = ["meetings", "recordings", "knowledge", ".minutemind"]

    /// Commits what MinuteMind wrote but has not committed yet (its commits pause on a detached
    /// HEAD or during a merge), so a switch neither counts nor stashes it as the user's changes.
    /// Other staged work stays staged. Does nothing off a branch or during an operation.
    /// Returns git's reason when the commit failed, nil otherwise.
    /// Only folders with staged changes go to `git commit`: a folder git knows no file in (an
    /// empty or all-ignored `meetings/`) fails the whole commit as an unmatched pathspec.
    @discardableResult
    static func commitAppManagedChanges(in repo: URL) -> String? {
        guard isOnBranchWithoutOperation(repo) else { return nil }
        let paths = appManagedPaths.filter { FileManager.default.fileExists(atPath: repo.appendingPathComponent($0).path) }
        guard !paths.isEmpty else { return nil }
        _ = run(["add", "-A", "--"] + paths, in: repo)
        let changed = paths.filter { !run(["diff", "--cached", "--quiet", "--", $0], in: repo).succeeded }
        guard !changed.isEmpty else { return nil }
        let commit = run(["commit", "-q", "-m", "MinuteMind: workspace updates", "--"] + changed, in: repo)
        return commit.succeeded ? nil : firstLine(of: commit.stderr + commit.stdout)
    }

    /// The files git lists (tab-indented) when it refuses to switch.
    static func conflictingFiles(in stderr: String) -> [String] {
        guard stderr.contains("would be overwritten") else { return [] }
        return stderr.split(separator: "\n")
            .filter { $0.hasPrefix("\t") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Creating

    /// Why `name` cannot be a new branch, or nil when it can.
    static func problem(withNewBranchName name: String, existing: [String], in repo: URL) -> String? {
        if name.isEmpty { return "Enter a name." }
        if existing.contains(name) { return "A branch named \(name) already exists." }
        guard run(["check-ref-format", "--branch", name], in: repo).succeeded else {
            return "\(name) is not a valid branch name. Use letters, numbers, - and /, without spaces."
        }
        return nil
    }

    /// Creates `name` at the current commit and switches to it; uncommitted changes come along.
    static func createBranch(_ name: String, in repo: URL) -> SwitchOutcome {
        let result = run(["switch", "-c", name], in: repo)
        return result.succeeded ? .switched : .failed(firstLine(of: result.stderr))
    }

    // MARK: - Process

    static func run(_ arguments: [String], in repo: URL) -> Output {
        // Without the Command Line Tools /usr/bin/git only opens Apple's install dialog.
        guard GitAvailability.isInstalled else {
            return Output(status: -1, stdout: "", stderr: GitAvailability.missingMessage)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repo
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return Output(status: -1, stdout: "", stderr: error.localizedDescription) }
        // Read before waiting, so a full pipe never blocks git.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: stdout, as: UTF8.self),
                      stderr: String(decoding: stderr, as: UTF8.self))
    }

    private static func firstLine(of text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "git did not say why." : line.replacingOccurrences(of: "error: ", with: "")
    }
}
