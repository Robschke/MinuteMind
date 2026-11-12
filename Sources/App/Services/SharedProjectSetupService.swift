// Purpose: SharedProjectSetup, the git and file work behind becoming or joining a Shared Project:
//          local git excludes, cloning a Shared Project's workspace and registering the user as a
//          member, cloning its listed code repos, checking that the migration skill really pushed
//          a fresh shared main, and reading which of the user's sessions the skill published.
// Dependencies: Sources/App/Services/WorkspaceGitService.swift (WorkspaceGit.run: git without a
//               terminal prompt), Sources/App/Models/SharedProject.swift (manifest, layout),
//               Sources/App/ViewModels/AppViewModel+SharedSetup.swift (SharedProjectSetupError)
// RBAC: None in the app. Who may clone or push is decided by the git host (members are the repo's
//       collaborators); the manifest's admin is whoever shared the project first.
// Dependents: Sources/App/ViewModels/AppViewModel+SharedSetup.swift, SharedProjectSkill.swift,
//             Tests/SharedProjectSetupTests.swift
// Notes: Everything here blocks on git (clones and ls-remote go over the network), so callers run
//        it off the main actor. Nothing takes the app's model as input: the view model passes in
//        folders and ids, which keeps this testable against temp folders.
//        A join clones into a hidden temporary folder inside Workspaces/ (same volume, so the
//        final move is a rename) and only moves it to Workspaces/<project id> after the manifest
//        was read and the member commit made; on any failure the temporary folder is removed.
//        The member commit is not pushed here: the background sync pushes it.
//        code/ is excluded locally in joined workspaces (.git/info/exclude), so code clones can
//        never be committed even when the shared .gitignore lacks the line.
//        Completion accepts a local main that is ahead of origin/main (the app may have committed
//        a mirror update after the push; the sync pushes it), but not a remote main the local
//        branch does not contain, which would mean the push did not happen or went elsewhere.
//        The privacy checks look at the whole pushed history and at every ref on origin, because
//        content that was ever pushed stays readable there even after a later commit removes it.

import Foundation

enum SharedProjectSetup {
    /// Prefix of the temporary clone folders inside Workspaces/ (not a UUID, so the app never
    /// mistakes one for a workspace).
    static let joinFolderPrefix = ".join-"

    // MARK: - Local excludes

    /// Adds a pattern to the repo's .git/info/exclude (local only, never shared) unless present.
    static func addLocalExclude(_ pattern: String, in repo: URL) throws {
        let info = repo.appendingPathComponent(".git/info", isDirectory: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let url = info.appendingPathComponent("exclude")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(pattern) else { return }
        var text = existing
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += pattern + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Join

    struct JoinedWorkspace: Sendable {
        let manifest: SharedProjectManifest
        let repo: URL
    }

    /// Clones a Shared Project's workspace repo into `root/<project id>` and commits the user as a
    /// member ("Join: <display name>"). Blocking. Throws SharedProjectSetupError; nothing is left
    /// behind on failure.
    static func cloneWorkspace(
        remoteURL: String, into root: URL, displayName: String, existingProjectIDs: Set<UUID>
    ) throws -> JoinedWorkspace {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !url.hasPrefix("-") else { throw SharedProjectSetupError.invalidRemoteURL }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent(joinFolderPrefix + UUID().uuidString, isDirectory: true)
        var moved = false
        defer { if !moved { try? fileManager.removeItem(at: temporary) } }

        let clone = WorkspaceGit.run(["clone", "--quiet", "--", url, temporary.path], in: root)
        guard clone.succeeded else { throw SharedProjectSetupError.cloneFailed(firstLine(clone.stderr)) }
        guard var manifest = SharedProjectManifest.load(from: temporary) else {
            throw SharedProjectSetupError.notSharedProject
        }
        if existingProjectIDs.contains(manifest.projectID) {
            throw SharedProjectSetupError.alreadyJoined(manifest.name)
        }
        let target = root.appendingPathComponent(manifest.projectID.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) {
            throw SharedProjectSetupError.workspaceFolderExists(manifest.name)
        }

        if manifest.addMember(displayName) {
            do { try manifest.save(to: temporary) } catch {
                throw SharedProjectSetupError.gitFailed(error.localizedDescription)
            }
            let add = WorkspaceGit.run(["add", "--", SharedProjectManifest.relativePath], in: temporary)
            let commit = add.succeeded
                ? WorkspaceGit.run(["commit", "--quiet", "-m", "Join: \(displayName)"], in: temporary)
                : add
            guard commit.succeeded else { throw SharedProjectSetupError.gitFailed(firstLine(commit.stderr)) }
        }
        do {
            try addLocalExclude("/code/", in: temporary)
            try fileManager.moveItem(at: temporary, to: target)
        } catch {
            throw SharedProjectSetupError.gitFailed(error.localizedDescription)
        }
        moved = true
        return JoinedWorkspace(manifest: manifest, repo: target)
    }

    /// Clones the manifest's code repos into `<workspace>/code/<folder>`, skipping folders that
    /// exist already. Blocking. Returns one line per repo that failed (empty: all fine).
    static func cloneCodeRepos(_ repos: [SharedProjectManifest.CodeRepo], into workspace: URL) -> [String] {
        guard !repos.isEmpty else { return [] }
        let code = workspace.appendingPathComponent("code", isDirectory: true)
        try? FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
        var failures: [String] = []
        for repo in repos {
            let folder = repo.folder.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = repo.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPlainFolderName(folder), !url.isEmpty, !url.hasPrefix("-") else {
                failures.append("\(repo.folder): not a valid folder name or URL")
                continue
            }
            let target = code.appendingPathComponent(folder, isDirectory: true)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            let result = WorkspaceGit.run(["clone", "--quiet", "--", url, target.path], in: code)
            if !result.succeeded { failures.append("\(folder): \(firstLine(result.stderr))") }
        }
        return failures
    }

    /// One path component that cannot climb out of code/ or hide as a dotfile.
    static func isPlainFolderName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") && !name.hasPrefix("-")
    }

    // MARK: - Completion of the migration skill

    /// Checks what the share-project skill must have done before the project may turn Shared:
    /// origin is `remoteURL`, the manifest names this project, main is the only ref on origin and
    /// is pushed (origin's main is the local main or an ancestor of it), its history starts fresh
    /// (one root commit that holds the manifest) and no commit in it touches private/ or jobs/.
    /// Blocking. Returns origin's URL as git has it.
    static func validateSetup(repo: URL, projectID: UUID, remoteURL: String) throws -> String {
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) else {
            throw SharedProjectSetupError.workspaceMissing
        }
        let origin = WorkspaceGit.run(["remote", "get-url", "origin"], in: repo)
        guard origin.succeeded else { throw SharedProjectSetupError.noOrigin }
        let actual = origin.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedRemote(actual) == normalizedRemote(remoteURL) else {
            throw SharedProjectSetupError.originMismatch(expected: remoteURL, actual: actual)
        }

        guard let manifest = SharedProjectManifest.load(from: repo) else { throw SharedProjectSetupError.manifestMissing }
        guard manifest.projectID == projectID else {
            throw SharedProjectSetupError.manifestMismatch(manifest.projectID)
        }

        let local = WorkspaceGit.run(["rev-parse", "--verify", "--quiet", "refs/heads/main"], in: repo)
        guard local.succeeded else { throw SharedProjectSetupError.mainMissing }
        let localHash = local.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let remote = WorkspaceGit.run(["ls-remote", "origin"], in: repo)
        guard remote.succeeded else { throw SharedProjectSetupError.remoteUnreachable(firstLine(remote.stderr)) }
        // "<hash>\t<ref>" per line; HEAD is the remote's pointer to main, not a branch of its own.
        var remoteRefs: [String: String] = [:]
        for line in remote.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 2, parts[1] != "HEAD" { remoteRefs[parts[1]] = parts[0] }
        }
        guard let remoteHash = remoteRefs["refs/heads/main"], !remoteHash.isEmpty else {
            throw SharedProjectSetupError.notPushed
        }
        let extraRefs = remoteRefs.keys.filter { $0 != "refs/heads/main" }.sorted()
        guard extraRefs.isEmpty else { throw SharedProjectSetupError.extraRefsPushed(extraRefs) }
        if remoteHash != localHash {
            let contained = WorkspaceGit.run(["merge-base", "--is-ancestor", remoteHash, localHash], in: repo)
            guard contained.succeeded else { throw SharedProjectSetupError.notPushed }
        }
        let manifestPushed = WorkspaceGit.run(["cat-file", "-e", "\(remoteHash):\(SharedProjectManifest.relativePath)"], in: repo)
        guard manifestPushed.succeeded else { throw SharedProjectSetupError.manifestNotPushed }
        // The shared history must be the fresh one: a single root commit that already carries the
        // manifest. The workspace's old history starts at a commit without it and holds every
        // meeting that is private now.
        let roots = WorkspaceGit.run(["rev-list", "--max-parents=0", remoteHash], in: repo).stdout
            .split(separator: "\n").map(String.init)
        guard roots.count == 1,
              WorkspaceGit.run(["cat-file", "-e", "\(roots[0]):\(SharedProjectManifest.relativePath)"], in: repo).succeeded
        else { throw SharedProjectSetupError.historyNotFresh }
        // Nothing local may ever have been part of the pushed history, not only of its latest state.
        guard !historyTouches(SharedProjectLayout.privateFolder, upTo: remoteHash, in: repo) else {
            throw SharedProjectSetupError.privateContentPushed
        }
        guard !historyTouches(SharedProjectLayout.jobsFolder, upTo: remoteHash, in: repo) else {
            throw SharedProjectSetupError.jobsPushed
        }
        return actual
    }

    /// True when any commit reachable from `commit` added, changed or removed something under `path`.
    private static func historyTouches(_ path: String, upTo commit: String, in repo: URL) -> Bool {
        let found = WorkspaceGit.run(["rev-list", "-1", commit, "--", path], in: repo)
        return !found.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Remote URLs compared without surrounding whitespace, a trailing slash or ".git".
    static func normalizedRemote(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix(".git") { value.removeLast(4) }
        return value
    }

    /// The publish choice of each session the local indexes know, from where the skill left its
    /// folder: `meetings/<folder>` is published, `private/meetings/<folder>` is private (recordings
    /// alike). Entries whose folder is in neither place are left out.
    static func publications(in repo: URL) -> [UUID: MeetingPublication] {
        struct Entry: Decodable { let folder: String }
        let fileManager = FileManager.default
        var result: [UUID: MeetingPublication] = [:]
        for isQuickRecording in [false, true] {
            let published = SharedProjectLayout.areaFolder(
                isQuickRecording: isQuickRecording, isSharedProject: true, publication: .published)
            let kept = SharedProjectLayout.areaFolder(
                isQuickRecording: isQuickRecording, isSharedProject: true, publication: .keptPrivate)
            let index = repo.appendingPathComponent(".minutemind/\(published).json")
            guard let data = try? Data(contentsOf: index),
                  let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { continue }
            for (key, entry) in entries {
                guard let id = UUID(uuidString: key), !entry.folder.isEmpty else { continue }
                if fileManager.fileExists(atPath: repo.appendingPathComponent("\(published)/\(entry.folder)").path) {
                    result[id] = .published
                } else if fileManager.fileExists(atPath: repo.appendingPathComponent("\(kept)/\(entry.folder)").path) {
                    result[id] = .keptPrivate
                }
            }
        }
        return result
    }

    // MARK: - Helpers

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? "git did not say why." : line
    }
}
