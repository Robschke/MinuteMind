// Purpose: Tests for becoming and joining a Shared Project: the share-project skill is written
//          and excluded from git, joining clones a Shared Project (manifest present, missing,
//          duplicate id) and commits the member, and complete_shared_project_setup only accepts a
//          workspace whose origin, manifest and pushed main are right.
// Dependencies: Sources/App/Services/SharedProjectSetupService.swift,
//               Sources/App/Services/SharedProjectSkill.swift, Sources/App/Models/SharedProject.swift,
//               /usr/bin/git
// Notes: Every test builds its own repos (a bare "remote" plus working copies) in the temp
//        directory; nothing touches the real App Support folder or the network.

import Foundation
import Testing
@testable import MinuteMindApp

@Suite("Shared Project Setup Tests")
struct SharedProjectSetupTests {

    // MARK: - Fixtures

    private func tempFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-setup-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func git(_ arguments: [String], _ repo: URL) -> WorkspaceGit.Output {
        WorkspaceGit.run(arguments, in: repo)
    }

    /// A working repo on main with a README, committed.
    private func makeWorkspace() throws -> URL {
        let repo = try tempFolder("workspace")
        git(["init", "-q", "-b", "main"], repo)
        git(["config", "user.email", "test@example.com"], repo)
        git(["config", "user.name", "Test"], repo)
        try "shared".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        git(["add", "-A"], repo)
        git(["commit", "-q", "-m", "base"], repo)
        return repo
    }

    private func makeBareRemote() throws -> URL {
        let bare = try tempFolder("remote.git")
        git(["init", "-q", "--bare", "-b", "main"], bare)
        return bare
    }

    private func manifest(_ id: UUID = UUID()) -> SharedProjectManifest {
        SharedProjectManifest(
            projectID: id, name: "Acme", colorHex: "#FF9500", admin: "Robin",
            members: [.init(name: "Robin", joinedAt: Date(timeIntervalSince1970: 1_700_000_000))], codeRepos: [])
    }

    /// A bare remote whose main holds a workspace, with the manifest when given.
    private func makeSharedRemote(manifest: SharedProjectManifest?) throws -> URL {
        let work = try makeWorkspace()
        if let manifest {
            try manifest.save(to: work)
            git(["add", "-A"], work)
            git(["commit", "-q", "-m", "Shared Project: Acme"], work)
        }
        let bare = try makeBareRemote()
        git(["push", "-q", bare.path, "main"], work)
        return bare
    }

    private func leftovers(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix(SharedProjectSetup.joinFolderPrefix) }
    }

    // MARK: - Skill

    @Test("the skill is written into .claude/skills and excluded from git once")
    func installsSkill() throws {
        let repo = try makeWorkspace()
        let file = try SharedProjectSkill.install(in: repo)
        try SharedProjectSkill.install(in: repo)

        #expect(file.path.hasSuffix(".claude/skills/share-project/SKILL.md"))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("---\nname: share-project\ndescription: "))
        #expect(text.contains("complete_shared_project_setup"))
        #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))

        let exclude = try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.components(separatedBy: "\n").filter { $0 == SharedProjectSkill.excludeEntry }.count == 1)
        let status = git(["status", "--porcelain", "--untracked-files=all"], repo).stdout
        #expect(!status.contains(".claude"))
    }

    @Test("the first prompt names project, display name and folder suffix")
    func initialPrompt() {
        let id = UUID()
        let prompt = SharedProjectSkill.initialPrompt(
            projectID: id, projectName: "Acme", colorHex: "#FF9500", displayName: "Robin S.", folderSuffix: "robin-s")
        #expect(prompt.contains("share-project"))
        #expect(prompt.contains(id.uuidString))
        #expect(prompt.contains("Project name: Acme"))
        #expect(prompt.contains("Display name: Robin S."))
        #expect(prompt.contains("Folder suffix: robin-s"))
    }

    // MARK: - Join

    @Test("joining clones into Workspaces/<id>, adds the member and commits it")
    func joinsSharedProject() throws {
        let shared = manifest()
        let remote = try makeSharedRemote(manifest: shared)
        let root = try tempFolder("Workspaces")

        let joined = try SharedProjectSetup.cloneWorkspace(
            remoteURL: remote.path, into: root, displayName: "Alex", existingProjectIDs: [])

        #expect(joined.repo.lastPathComponent == shared.projectID.uuidString)
        #expect(joined.manifest.members.map(\.name) == ["Robin", "Alex"])
        #expect(SharedProjectManifest.load(from: joined.repo)?.members.map(\.name) == ["Robin", "Alex"])
        #expect(git(["log", "-1", "--format=%s"], joined.repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "Join: Alex")
        #expect(git(["status", "--porcelain"], joined.repo).stdout.isEmpty)
        let exclude = try String(contentsOf: joined.repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.contains("/code/"))
        #expect(leftovers(in: root).isEmpty)
    }

    @Test("a repo without a manifest is refused and leaves nothing behind")
    func refusesRepoWithoutManifest() throws {
        let remote = try makeSharedRemote(manifest: nil)
        let root = try tempFolder("Workspaces")

        #expect(throws: SharedProjectSetupError.notSharedProject) {
            try SharedProjectSetup.cloneWorkspace(remoteURL: remote.path, into: root, displayName: "Alex", existingProjectIDs: [])
        }
        #expect(SharedProjectSetupError.notSharedProject.errorDescription == "This repo is not a MinuteMind Shared Project.")
        #expect(leftovers(in: root).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty)
    }

    @Test("a project id that exists locally is refused")
    func refusesDuplicateProject() throws {
        let shared = manifest()
        let remote = try makeSharedRemote(manifest: shared)
        let root = try tempFolder("Workspaces")

        #expect(throws: SharedProjectSetupError.alreadyJoined("Acme")) {
            try SharedProjectSetup.cloneWorkspace(
                remoteURL: remote.path, into: root, displayName: "Alex", existingProjectIDs: [shared.projectID])
        }
        #expect(leftovers(in: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(shared.projectID.uuidString).path))
    }

    @Test("an existing workspace folder for the id is never overwritten")
    func refusesExistingFolder() throws {
        let shared = manifest()
        let remote = try makeSharedRemote(manifest: shared)
        let root = try tempFolder("Workspaces")
        let folder = root.appendingPathComponent(shared.projectID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(throws: SharedProjectSetupError.workspaceFolderExists("Acme")) {
            try SharedProjectSetup.cloneWorkspace(remoteURL: remote.path, into: root, displayName: "Alex", existingProjectIDs: [])
        }
        #expect(leftovers(in: root).isEmpty)
    }

    @Test("an unreachable URL or one starting with a dash fails cleanly")
    func refusesBadURL() throws {
        let root = try tempFolder("Workspaces")
        #expect(throws: SharedProjectSetupError.invalidRemoteURL) {
            try SharedProjectSetup.cloneWorkspace(remoteURL: "--upload-pack=x", into: root, displayName: "A", existingProjectIDs: [])
        }
        #expect(throws: (any Error).self) {
            try SharedProjectSetup.cloneWorkspace(
                remoteURL: root.appendingPathComponent("missing.git").path, into: root, displayName: "A", existingProjectIDs: [])
        }
        #expect(leftovers(in: root).isEmpty)
    }

    @Test("listed code repos are cloned into code/<folder>; unsafe folders are skipped")
    func clonesCodeRepos() throws {
        let code = try makeBareRemote()
        let codeWork = try makeWorkspace()
        git(["push", "-q", code.path, "main"], codeWork)
        let workspace = try tempFolder("joined")

        let failures = SharedProjectSetup.cloneCodeRepos(
            [.init(url: code.path, folder: "app"), .init(url: code.path, folder: "../escape")], into: workspace)

        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("code/app/README.md").path))
        #expect(failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escape").path))
    }

    // MARK: - complete_shared_project_setup

    /// A workspace as the skill leaves it: main is one fresh root commit that holds the manifest,
    /// `origin` points to a bare remote.
    private func makeMigratedWorkspace() throws -> (repo: URL, remote: URL, id: UUID) {
        let repo = try tempFolder("workspace")
        git(["init", "-q", "-b", "main"], repo)
        git(["config", "user.email", "test@example.com"], repo)
        git(["config", "user.name", "Test"], repo)
        try "shared".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let id = UUID()
        try manifest(id).save(to: repo)
        git(["add", "-A"], repo)
        git(["commit", "-q", "-m", "Shared Project: Acme"], repo)
        let remote = try makeBareRemote()
        git(["remote", "add", "origin", remote.path], repo)
        return (repo, remote, id)
    }

    @Test("setup is complete once origin, manifest and the pushed main match")
    func acceptsCompletedSetup() throws {
        let (repo, remote, id) = try makeMigratedWorkspace()
        git(["push", "-q", "-u", "origin", "main"], repo)

        let origin = try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: remote.path + "/")
        #expect(origin == remote.path)

        // A mirror commit after the push is fine: the sync pushes it.
        try "more".write(to: repo.appendingPathComponent("later.md"), atomically: true, encoding: .utf8)
        git(["add", "-A"], repo)
        git(["commit", "-q", "-m", "later"], repo)
        _ = try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: remote.path)
    }

    @Test("a different origin is refused")
    func refusesOriginMismatch() throws {
        let (repo, remote, id) = try makeMigratedWorkspace()
        git(["push", "-q", "-u", "origin", "main"], repo)
        #expect(throws: SharedProjectSetupError.originMismatch(expected: "git@example.com:other.git", actual: remote.path)) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: "git@example.com:other.git")
        }
    }

    @Test("a missing or foreign manifest is refused")
    func refusesManifestProblems() throws {
        let (repo, remote, id) = try makeMigratedWorkspace()
        git(["push", "-q", "-u", "origin", "main"], repo)
        #expect(throws: SharedProjectSetupError.manifestMismatch(id)) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: UUID(), remoteURL: remote.path)
        }
        try FileManager.default.removeItem(at: repo.appendingPathComponent(SharedProjectManifest.relativePath))
        #expect(throws: SharedProjectSetupError.manifestMissing) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: remote.path)
        }
    }

    @Test("an unpushed main is refused")
    func refusesUnpushed() throws {
        let (repo, remote, id) = try makeMigratedWorkspace()
        #expect(throws: SharedProjectSetupError.notPushed) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: remote.path)
        }
    }

    @Test("a workspace without origin is refused")
    func refusesMissingOrigin() throws {
        let (repo, remote, id) = try makeMigratedWorkspace()
        git(["remote", "remove", "origin"], repo)
        #expect(throws: SharedProjectSetupError.noOrigin) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: remote.path)
        }
    }

    @Test("pushed files under private/ are refused")
    func refusesPushedPrivateContent() throws {
        let (repo, remote, id) = try makeMigratedWorkspace()
        let leaked = repo.appendingPathComponent("private/meetings/x")
        try FileManager.default.createDirectory(at: leaked, withIntermediateDirectories: true)
        try "secret".write(to: leaked.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        git(["add", "-A"], repo)
        git(["commit", "-q", "-m", "oops"], repo)
        git(["push", "-q", "-u", "origin", "main"], repo)
        #expect(throws: SharedProjectSetupError.privateContentPushed) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: remote.path)
        }
    }

    @Test("the workspace's old history is refused, even when its latest state is clean")
    func refusesOldHistory() throws {
        // The old history: a root commit without the manifest, the manifest added on top.
        let repo = try makeWorkspace()
        let id = UUID()
        try manifest(id).save(to: repo)
        git(["add", "-A"], repo)
        git(["commit", "-q", "-m", "Shared Project: Acme"], repo)
        let remote = try makeBareRemote()
        git(["remote", "add", "origin", remote.path], repo)
        git(["push", "-q", "-u", "origin", "main"], repo)
        #expect(throws: SharedProjectSetupError.historyNotFresh) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: remote.path)
        }
    }

    @Test("private files removed again in a later commit are still refused")
    func refusesPrivateContentInHistory() throws {
        let (repo, remote, id) = try makeMigratedWorkspace()
        let leaked = repo.appendingPathComponent("private/meetings/x")
        try FileManager.default.createDirectory(at: leaked, withIntermediateDirectories: true)
        try "secret".write(to: leaked.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        git(["add", "-A"], repo)
        git(["commit", "-q", "-m", "oops"], repo)
        git(["rm", "-r", "-q", "private"], repo)
        git(["commit", "-q", "-m", "remove"], repo)
        git(["push", "-q", "-u", "origin", "main"], repo)
        #expect(throws: SharedProjectSetupError.privateContentPushed) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: remote.path)
        }
    }

    @Test("a pushed backup branch or tag is refused")
    func refusesExtraRefs() throws {
        let (repo, remote, id) = try makeMigratedWorkspace()
        git(["push", "-q", "-u", "origin", "main"], repo)
        git(["branch", "pre-share-backup"], repo)
        git(["push", "-q", "origin", "pre-share-backup"], repo)
        #expect(throws: SharedProjectSetupError.extraRefsPushed(["refs/heads/pre-share-backup"])) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: remote.path)
        }
    }

    @Test("pushed jobs are refused")
    func refusesPushedJobs() throws {
        let (repo, remote, id) = try makeMigratedWorkspace()
        let jobs = repo.appendingPathComponent("jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try "prompt".write(to: jobs.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
        git(["add", "-A"], repo)
        git(["commit", "-q", "-m", "job"], repo)
        git(["push", "-q", "-u", "origin", "main"], repo)
        #expect(throws: SharedProjectSetupError.jobsPushed) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: id, remoteURL: remote.path)
        }
    }

    // MARK: - Publish choices

    @Test("publish choices are read from where the skill left each indexed folder")
    func readsPublications() throws {
        let repo = try tempFolder("ws")
        let published = UUID(), kept = UUID(), recording = UUID(), gone = UUID()
        let fm = FileManager.default
        for path in ["meetings/2026-11-01-weekly-robin", "private/meetings/2026-11-02-one-on-one",
                     "private/recordings/2026-11-03-0930-idea"] {
            try fm.createDirectory(at: repo.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: repo.appendingPathComponent(".minutemind"), withIntermediateDirectories: true)
        let meetings = """
            { "\(published.uuidString)": { "folder": "2026-11-01-weekly-robin", "hashes": {} },
              "\(kept.uuidString)": { "folder": "2026-11-02-one-on-one", "hashes": {} },
              "\(gone.uuidString)": { "folder": "2026-11-04-nowhere", "hashes": {} } }
            """
        let recordings = """
            { "\(recording.uuidString)": { "folder": "2026-11-03-0930-idea", "hashes": {} } }
            """
        try meetings.write(to: repo.appendingPathComponent(".minutemind/meetings.json"), atomically: true, encoding: .utf8)
        try recordings.write(to: repo.appendingPathComponent(".minutemind/recordings.json"), atomically: true, encoding: .utf8)

        let choices = SharedProjectSetup.publications(in: repo)
        #expect(choices == [published: .published, kept: .keptPrivate, recording: .keptPrivate])
    }
}
