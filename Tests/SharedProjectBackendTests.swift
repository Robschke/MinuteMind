// Purpose: Tests for the backend of Shared Projects: where items are mirrored and how published
//          folders are named, the .gitignore and index untracking of a shared repo, moving an item
//          from private/ to the published area, the CLAUDE.md section, the private knowledge layer
//          in search, the manifest, jobs staying local, and the sync loop and knowledge replay against a
//          local bare repo with two member clones. No Claude runs: the replayed agent step is a
//          closure.
// Dependencies: Sources/App/Services/ProjectRepositoryService.swift,
//               Sources/App/Services/SharedProjectSyncService.swift (SharedProjectSync, SharedRepoGit),
//               Sources/App/Services/KnowledgeCurationService.swift, Sources/App/Services/KnowledgeIndexer.swift,
//               Sources/App/Models/SharedProject.swift, Sources/App/Store/ScheduledJobFiles.swift,
//               Sources/App/Supporting/ScheduledJobStore.swift

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("Shared Project backend Tests")
struct SharedProjectBackendTests {
    // MARK: - Helpers

    private func temporaryDirectory(_ name: String = "shared") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeService() -> ProjectRepositoryService {
        let base = temporaryDirectory()
        let service = ProjectRepositoryService(baseDirectory: base, legacyWorkspaceStore: WorkspaceStore(baseDirectory: base))
        service.contributorName = { "Robin S." }
        return service
    }

    private func sharedProject(_ name: String = "Acme") -> Project {
        var project = Project(name: name)
        project.shared = SharedProjectInfo(remoteURL: "git@example.com:acme.git", sharedAt: Date())
        return project
    }

    private func session(_ title: String, quick: Bool = false, publication: MeetingPublication? = nil) throws -> RecordingSession {
        var components = DateComponents(year: 2026, month: 11, day: 12, hour: 9, minute: 30)
        components.timeZone = .current
        let created = try #require(Calendar.current.date(from: components))
        var session = RecordingSession(title: title, createdAt: created, languageCode: "en-US", status: .completed)
        if quick { session.kind = .quickRecording }
        session.transcript = .init(text: "[00:01] You: hello", languageCode: "en-US", updatedAt: Date())
        session.publication = publication
        return session
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) -> WorkspaceGit.Output {
        SharedRepoGit.run(arguments, in: directory)
    }

    private func identify(_ repo: URL, as name: String = "Test") {
        git(["config", "user.name", name], in: repo)
        git(["config", "user.email", "\(name.lowercased())@example.com"], in: repo)
    }

    private func exists(_ path: String, in repo: URL) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(path).path)
    }

    private func write(_ text: String, to path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Layout and naming

    @Test("Areas: private projects and published items use meetings/, the rest private/")
    func areaRules() {
        #expect(SharedProjectLayout.areaFolder(isQuickRecording: false, isSharedProject: false, publication: nil) == "meetings")
        #expect(SharedProjectLayout.areaFolder(isQuickRecording: true, isSharedProject: false, publication: .keptPrivate) == "recordings")
        #expect(SharedProjectLayout.areaFolder(isQuickRecording: false, isSharedProject: true, publication: nil) == "private/meetings")
        #expect(SharedProjectLayout.areaFolder(isQuickRecording: true, isSharedProject: true, publication: .keptPrivate) == "private/recordings")
        #expect(SharedProjectLayout.areaFolder(isQuickRecording: false, isSharedProject: true, publication: .published) == "meetings")
        #expect(AppViewModel.knowledgeFolder(forItemAt: "private/meetings/x") == "private/knowledge")
        #expect(AppViewModel.knowledgeFolder(forItemAt: "meetings/x-robin") == "knowledge")
    }

    @Test("Published folder names end with the contributor's name, private ones do not")
    func publishedNames() throws {
        let service = makeService()
        let project = sharedProject()
        let meeting = try session("Weekly", publication: .published)
        let recording = try session("Idea", quick: true, publication: .published)
        let kept = try session("Retro", publication: .keptPrivate)
        service.mirror(session: meeting, minutes: "## Summary", project: project)
        service.mirror(session: recording, minutes: nil, project: project)
        service.mirror(session: kept, minutes: "## Summary", project: project)
        #expect(service.mirroredFolder(for: meeting, in: project) == "meetings/2026-11-12-weekly-robin-s")
        #expect(service.mirroredFolder(for: recording, in: project) == "recordings/2026-11-12-0930-idea-robin-s")
        #expect(service.mirroredFolder(for: kept, in: project) == "private/meetings/2026-11-12-retro")

        // A Private project names folders as before.
        let plain = Project(name: "Plain")
        service.mirror(session: meeting, minutes: "## Summary", project: plain)
        #expect(service.mirroredFolder(for: meeting, in: plain) == "meetings/2026-11-12-weekly")
    }

    // MARK: - Repo preparation

    @Test("While the share-project skill runs, mirroring leaves its private and suffixed folders alone")
    func mirrorDuringMigration() throws {
        let service = makeService()
        let project = Project(name: "Acme")
        let repo = service.ensureRepository(for: project)
        identify(repo)
        let kept = try session("Salary Talk")
        let published = try session("Weekly")
        service.mirror(session: kept, minutes: "## Summary", project: project)
        service.mirror(session: published, minutes: "## Summary", project: project)
        let keptFolder = try #require(service.mirroredFolder(for: kept, in: project))
        let publishedFolder = try #require(service.mirroredFolder(for: published, in: project))

        // What the skill does before the project turns Shared: private items move to private/,
        // published ones get the contributor suffix, the index follows.
        let fileManager = FileManager.default
        let keptName = (keptFolder as NSString).lastPathComponent
        try fileManager.createDirectory(at: repo.appendingPathComponent("private/meetings"), withIntermediateDirectories: true)
        try fileManager.moveItem(at: repo.appendingPathComponent(keptFolder),
                                 to: repo.appendingPathComponent("private/meetings/\(keptName)"))
        try fileManager.moveItem(at: repo.appendingPathComponent(publishedFolder),
                                 to: repo.appendingPathComponent(publishedFolder + "-robin-s"))
        let indexURL = repo.appendingPathComponent(".minutemind/meetings.json")
        var index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: [String: Any]])
        index[published.id.uuidString]?["folder"] = (publishedFolder as NSString).lastPathComponent + "-robin-s"
        try JSONSerialization.data(withJSONObject: index).write(to: indexURL)

        // A new Claude tab mirrors every session of the still Private project.
        service.mirror(session: kept, minutes: "## Summary", project: project)
        service.mirror(session: published, minutes: "## Summary", project: project)

        #expect(exists("private/meetings/\(keptName)/transcript.md", in: repo))
        #expect(!exists(keptFolder, in: repo))
        #expect(service.mirroredFolder(for: kept, in: project) == "private/meetings/\(keptName)")
        #expect(exists(publishedFolder + "-robin-s", in: repo))
        #expect(!exists(publishedFolder, in: repo))
        #expect(git(["ls-files", "--", "private"], in: repo).stdout.isEmpty)
    }

    @Test("A shared repo ignores private/, the indexes and jobs/, untracks what was committed, has private/")
    func sharedRepoPreparation() throws {
        let service = makeService()
        var project = Project(name: "Acme")
        let repo = service.ensureRepository(for: project)
        identify(repo)
        service.mirror(session: try session("Weekly"), minutes: "## Summary", project: project)
        #expect(!git(["ls-files", ".minutemind/meetings.json"], in: repo).stdout.isEmpty)
        let run = repo.appendingPathComponent("jobs/brief/runs/2026-11-12-0900.md")
        try FileManager.default.createDirectory(at: run.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "result".write(to: run, atomically: true, encoding: .utf8)
        try "prompt".write(to: repo.appendingPathComponent("jobs/brief.md"), atomically: true, encoding: .utf8)
        git(["add", "--", "jobs"], in: repo)
        git(["commit", "-q", "-m", "Jobs: create Brief"], in: repo)
        var claude = try String(contentsOf: repo.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(!claude.contains("## Shared Project"))

        let manifest = SharedProjectManifest(
            projectID: project.id, name: "Acme", colorHex: nil, admin: "Robin",
            members: [.init(name: "Robin", joinedAt: Date()), .init(name: "Anna", joinedAt: Date())], codeRepos: [])
        try manifest.save(to: repo)
        project.shared = SharedProjectInfo(remoteURL: "git@example.com:acme.git", sharedAt: Date())
        service.ensureRepository(for: project)

        let gitignore = try String(contentsOf: repo.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(gitignore.contains("/private/\n"))
        for entry in SharedProjectLayout.localIndexEntries { #expect(gitignore.contains(entry)) }
        #expect(gitignore.contains("/jobs/\n"))
        #expect(git(["ls-files", ".minutemind/meetings.json"], in: repo).stdout.isEmpty)
        #expect(exists(".minutemind/meetings.json", in: repo))
        #expect(exists("private", in: repo))
        #expect(git(["ls-files", "--", "jobs"], in: repo).stdout.isEmpty)
        #expect(exists("jobs/brief.md", in: repo))
        #expect(exists("jobs/brief/runs/2026-11-12-0900.md", in: repo))
        #expect(git(["status", "--porcelain", "--", "jobs"], in: repo).stdout.isEmpty)
        #expect(git(["status", "--porcelain", "--", ".gitignore", ".minutemind"], in: repo).stdout
            .split(separator: "\n").allSatisfy { $0.hasPrefix("??") && $0.contains("project.json") })

        claude = try String(contentsOf: repo.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(claude.contains("## Shared Project"))
        #expect(claude.contains("private/CLAUDE.private.md"))
        #expect(claude.contains("Robin (admin), Anna"))
        #expect(claude.contains("private/knowledge/"))
        #expect(claude.contains("private/recordings/"))
        #expect(claude.components(separatedBy: "minutemind:end").count == 2)

        // Running it again changes nothing.
        let head = SharedRepoGit.head(of: repo)
        service.ensureRepository(for: project)
        #expect(SharedRepoGit.head(of: repo) == head)
    }

    // MARK: - Moving between areas

    @Test("Publishing a private item moves its folder, adds the name, and commits only the published area")
    func publishMovesFolder() throws {
        let service = makeService()
        let project = sharedProject()
        let repo = service.ensureRepository(for: project)
        identify(repo)
        var item = try session("Weekly")
        service.mirror(session: item, minutes: "## Summary\nShip it.", project: project)
        let privateFolder = try #require(service.mirroredFolder(for: item, in: project))
        #expect(privateFolder == "private/meetings/2026-11-12-weekly")
        #expect(git(["status", "--porcelain"], in: repo).stdout.isEmpty)
        #expect(git(["ls-files", "private"], in: repo).stdout.isEmpty)

        item.publication = .published
        #expect(service.mirror(session: item, minutes: "## Summary\nShip it.", project: project))
        #expect(service.mirroredFolder(for: item, in: project) == "meetings/2026-11-12-weekly-robin-s")
        #expect(!exists(privateFolder, in: repo))
        #expect(git(["ls-files", "meetings/2026-11-12-weekly-robin-s/summary.md"], in: repo).stdout.contains("summary.md"))
        #expect(git(["log", "-1", "--format=%s"], in: repo).stdout.hasPrefix("Publish meeting: Weekly"))
        #expect(git(["status", "--porcelain"], in: repo).stdout.isEmpty)

        // Before the shared knowledge cites it, a rename follows; afterwards the name stays.
        item.title = "Weekly Sync"
        service.mirror(session: item, minutes: "## Summary\nShip it.", project: project)
        #expect(service.mirroredFolder(for: item, in: project) == "meetings/2026-11-12-weekly-sync-robin-s")
        service.markCited(session: item, in: project)
        item.title = "Weekly Planning"
        service.mirror(session: item, minutes: "## Summary\nShip it.", project: project)
        #expect(service.mirroredFolder(for: item, in: project) == "meetings/2026-11-12-weekly-sync-robin-s")

        // Unmirroring a published item removes it from the published area and commits.
        #expect(service.unmirror(session: item, from: project) == "meetings/2026-11-12-weekly-sync-robin-s")
        #expect(git(["ls-files", "meetings"], in: repo).stdout.isEmpty)
    }

    @Test("Private folders are found by index or frontmatter; hand-made ones publish with the suffix")
    func privateFolders() throws {
        let service = makeService()
        let project = sharedProject()
        let repo = service.ensureRepository(for: project)
        identify(repo)
        let item = try session("Idea", quick: true)
        service.mirror(session: item, minutes: nil, project: project)
        let folder = try #require(service.mirroredFolder(for: item, in: project))
        #expect(folder == "private/recordings/2026-11-12-0930-idea")
        #expect(ProjectRepositoryService.privateItem(folder)?.kind == "recordings")
        #expect(ProjectRepositoryService.privateItem("private/meetings") == nil)
        #expect(ProjectRepositoryService.privateItem("meetings/x") == nil)
        #expect(service.sessionID(forMirroredFolder: folder, in: repo) == item.id)

        // Without the index the frontmatter still names the session; adopting it restores the entry.
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".minutemind/recordings.json"))
        #expect(service.mirroredFolder(for: item, in: project) == nil)
        #expect(service.sessionID(forMirroredFolder: folder, in: repo) == item.id)
        service.adoptMirroredFolder(folder, sessionID: item.id, in: repo)
        #expect(service.mirroredFolder(for: item, in: project) == folder)

        try write("# Notes\n", to: "private/meetings/2026-11-01-hallway/transcript.md", in: repo)
        #expect(service.sessionID(forMirroredFolder: "private/meetings/2026-11-01-hallway", in: repo) == nil)
        let published = service.publishFolder("private/meetings/2026-11-01-hallway", in: project)
        #expect(published == "meetings/2026-11-01-hallway-robin-s")
        #expect(git(["ls-files", "meetings"], in: repo).stdout.contains("2026-11-01-hallway-robin-s/transcript.md"))
        #expect(service.publishFolder("private/meetings/2026-11-01-hallway", in: project) == nil)
    }

    @Test("Index entries hold the bare folder name; the area is where the folder lives (migration skill format)")
    func skillWrittenIndex() throws {
        let service = makeService()
        let project = sharedProject()
        let repo = service.ensureRepository(for: project)
        identify(repo)
        var kept = try session("Retro")
        var published = try session("Weekly", publication: .published)
        // What the share-project skill leaves behind: folders moved by hand, one index per kind.
        try write("old\n", to: "private/meetings/2026-11-12-retro/summary.md", in: repo)
        try write("old\n", to: "meetings/2026-11-12-weekly-robin-s/summary.md", in: repo)
        let index = """
            {"\(kept.id.uuidString)": {"folder": "2026-11-12-retro", "hashes": {}},
             "\(published.id.uuidString)": {"folder": "2026-11-12-weekly-robin-s", "hashes": {}}}
            """
        try write(index, to: ".minutemind/meetings.json", in: repo)
        #expect(service.mirroredFolder(for: kept, in: project) == "private/meetings/2026-11-12-retro")
        #expect(service.mirroredFolder(for: published, in: project) == "meetings/2026-11-12-weekly-robin-s")
        #expect(service.sessionID(forMirroredFolder: "private/meetings/2026-11-12-retro", in: repo) == kept.id)

        // Mirroring writes into the existing folders instead of making new ones.
        service.mirror(session: kept, minutes: "## Summary", project: project)
        service.mirror(session: published, minutes: "## Summary", project: project)
        #expect(try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("private/meetings").path) == ["2026-11-12-retro"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("meetings").path) == ["2026-11-12-weekly-robin-s"])
        let data = try Data(contentsOf: repo.appendingPathComponent(".minutemind/meetings.json"))
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        #expect(entries[kept.id.uuidString]?["area"] == nil)
        #expect(entries[kept.id.uuidString]?["folder"] as? String == "2026-11-12-retro")

        // Publishing later moves the private folder and adds the name.
        kept.publication = .published
        service.mirror(session: kept, minutes: "## Summary", project: project)
        #expect(service.mirroredFolder(for: kept, in: project) == "meetings/2026-11-12-retro-robin-s")
        published.title = "Weekly"
        #expect(service.mirroredFolder(for: published, in: project) == "meetings/2026-11-12-weekly-robin-s")
    }

    // MARK: - Knowledge layers

    @Test("Search indexes both knowledge layers under their own paths")
    func privateKnowledgeIsIndexed() async throws {
        let service = makeService()
        let project = sharedProject()
        let repo = service.ensureRepository(for: project)
        try write("# Decisions\n\n- Ship in May. (meetings/2026-11-12-weekly-robin)\n", to: "knowledge/decisions.md", in: repo)
        try write("# Ideas\n\n- Pricing idea. (private/recordings/2026-11-12-0930-idea)\n", to: "private/knowledge/ideas.md", in: repo)
        let files = service.knowledgeFiles(in: repo)
        #expect(files.map(\.lastPathComponent) == ["decisions.md", "ideas.md"])

        let storeDir = temporaryDirectory("store")
        let store = try KnowledgeStore(baseDirectory: storeDir)
        await KnowledgeIndexer.index(repoID: project.id, repo: repo, files: files, projectID: project.id, store: store)
        let sources = Set(try store.fetchAllDocuments(projectID: project.id).map(\.sourceMeetingTitle))
        #expect(sources == [
            KnowledgeIndexer.source(repoID: project.id, relativePath: "knowledge/decisions.md"),
            KnowledgeIndexer.source(repoID: project.id, relativePath: "private/knowledge/ideas.md"),
        ])
        #expect(try store.searchChunks(keyword: "Pricing", projectID: project.id).count == 1)

        try write("", to: "private/knowledge/ideas.md", in: repo)
        #expect(KnowledgeCurator.removeEmptyKnowledgeFiles(in: repo, folder: "private/knowledge") == ["private/knowledge/ideas.md"])
    }

    @Test("The private curator writes only into private/knowledge; the default prompt is unchanged")
    func curatorPrompts() {
        let shared = KnowledgeCurator.systemPrompt()
        #expect(shared.contains("`knowledge/` of the current directory"))
        #expect(shared.contains("(meetings/2026-10-01-api-sync)"))
        #expect(!shared.contains("private"))
        let personal = KnowledgeCurator.systemPrompt(knowledgeFolder: "private/knowledge")
        #expect(personal.contains("`private/knowledge/` of the current directory"))
        #expect(personal.contains("never into `knowledge/`"))
        #expect(personal.contains("(private/meetings/2026-10-01-api-sync)"))
        #expect(KnowledgeCurator.curatePrompt(meetingFolder: "private/meetings/x", knowledgeFolder: "private/knowledge")
            .contains("Update `private/knowledge/`"))
    }

    // MARK: - Manifest

    @Test("The manifest survives a save and load; members are added once")
    func manifestRoundTrip() throws {
        let repo = temporaryDirectory("manifest")
        let joined = Date(timeIntervalSince1970: 1_794_000_000)
        var manifest = SharedProjectManifest(
            projectID: UUID(), name: "Acme", colorHex: "#FF0000", admin: "Robin",
            members: [.init(name: "Robin", joinedAt: joined)],
            codeRepos: [.init(url: "git@example.com:acme/app.git", folder: "app")])
        let added = manifest.addMember("Anna", at: joined)
        let addedTwice = manifest.addMember("Anna", at: joined)
        #expect(added)
        #expect(!addedTwice)
        #expect(manifest.members.map(\.name) == ["Robin", "Anna"])
        try manifest.save(to: repo)
        #expect(SharedProjectManifest.load(from: repo) == manifest)
        #expect(SharedProjectManifest.load(from: temporaryDirectory("empty")) == nil)
    }

    // MARK: - Sync against a bare remote

    /// A bare origin on main and two member clones with an initial commit pushed.
    private func makeRemote() throws -> (origin: URL, robin: URL, anna: URL) {
        let root = temporaryDirectory("remote")
        let origin = root.appendingPathComponent("origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        #expect(git(["init", "-q", "--bare", "-b", "main"], in: origin).succeeded)
        let robin = root.appendingPathComponent("robin", isDirectory: true)
        try FileManager.default.createDirectory(at: robin, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: robin)
        identify(robin, as: "Robin")
        try write("/private/\n/.minutemind/meetings.json\n", to: ".gitignore", in: robin)
        try write("# Decisions\n\n- Start. (meetings/2026-11-01-kickoff-robin)\n", to: "knowledge/decisions.md", in: robin)
        git(["add", "-A"], in: robin)
        git(["commit", "-q", "-m", "Start"], in: robin)
        git(["remote", "add", "origin", origin.path], in: robin)
        #expect(git(["push", "-q", "origin", "main"], in: robin).succeeded)
        #expect(git(["clone", "-q", origin.path, "anna"], in: root).succeeded)
        let anna = root.appendingPathComponent("anna", isDirectory: true)
        identify(anna, as: "Anna")
        return (origin, robin, anna)
    }

    private func commit(_ text: String, to path: String, in repo: URL, message: String) throws {
        try write(text, to: path, in: repo)
        git(["add", "-A", "--", path], in: repo)
        git(["commit", "-q", "-m", message], in: repo)
    }

    @Test("Sync pushes, pulls, hands back conflicts without leaving a rebase, and stays off side branches")
    func syncLoop() throws {
        let (_, robin, anna) = try makeRemote()
        try commit("# Weekly\n", to: "meetings/2026-11-12-weekly-robin/summary.md", in: robin, message: "Mirror meeting: Weekly")
        try write("my private note\n", to: "private/meetings/2026-11-12-retro/summary.md", in: robin)
        #expect(SharedRepoGit.sync(repo: robin) == .synced(pulled: false))
        #expect(SharedRepoGit.sync(repo: anna) == .synced(pulled: true))
        #expect(exists("meetings/2026-11-12-weekly-robin/summary.md", in: anna))
        #expect(!exists("private", in: anna))

        // Both members edit the same line by hand: the second sync aborts the rebase and hands
        // back the in-memory merge (resolved in SharedProjectSyncMergeTests).
        try commit("# Decisions\n\n- Robin's version.\n", to: "knowledge/decisions.md", in: robin, message: "Robin edits")
        try commit("# Decisions\n\n- Anna's version.\n", to: "knowledge/decisions.md", in: anna, message: "Anna edits")
        #expect(SharedRepoGit.sync(repo: robin) == .synced(pulled: false))
        guard case .conflicts(let plan) = SharedRepoGit.sync(repo: anna) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(plan.conflicts.map(\.path) == ["knowledge/decisions.md"])
        #expect(plan.unsupported.isEmpty)
        #expect(WorkspaceGit.operation(in: anna) == nil)
        #expect(WorkspaceGit.state(of: anna)?.branchName == "main")

        // Uncommitted (staged) changes survive a pull.
        git(["reset", "-q", "--hard", "origin/main"], in: anna)
        try commit("# Weekly 2\n", to: "meetings/2026-11-13-weekly-robin/summary.md", in: robin, message: "Mirror meeting: Weekly 2")
        #expect(SharedRepoGit.sync(repo: robin) == .synced(pulled: false))
        try write("draft\n", to: "notes/draft.md", in: anna)
        git(["add", "notes/draft.md"], in: anna)
        #expect(SharedRepoGit.sync(repo: anna) == .synced(pulled: true))
        #expect(exists("notes/draft.md", in: anna))
        #expect(exists("meetings/2026-11-13-weekly-robin/summary.md", in: anna))

        git(["switch", "-q", "-c", "feature"], in: anna)
        #expect(SharedRepoGit.sync(repo: anna) == .problem(SharedRepoGit.switchBackMessage))
    }

    @Test("A knowledge file deleted by hand reaches the others while meetings/ holds nothing tracked")
    func deletionWithUntrackedMeetingsFolder() throws {
        let (origin, robin, anna) = try makeRemote()
        // No published meeting yet: meetings/ exists, git knows no file in it.
        try FileManager.default.createDirectory(at: robin.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: robin.appendingPathComponent("knowledge/decisions.md"))

        #expect(SharedRepoGit.sync(repo: robin) == .synced(pulled: false))
        #expect(!git(["show", "main:knowledge/decisions.md"], in: origin).succeeded)
        #expect(git(["status", "--porcelain"], in: robin).stdout.isEmpty)
        #expect(SharedRepoGit.sync(repo: anna) == .synced(pulled: true))
        #expect(!exists("knowledge/decisions.md", in: anna))
    }

    @Test("Knowledge replay starts over after a rejected push and never sees private/")
    func knowledgeReplay() async throws {
        let (origin, robin, anna) = try makeRemote()
        try commit("# Weekly\n", to: "meetings/2026-11-12-weekly-robin/summary.md", in: robin, message: "Mirror meeting: Weekly")
        try write("secret\n", to: "private/knowledge/ideas.md", in: robin)

        let sync = SharedProjectSync()
        let worktrees = temporaryDirectory("curation")
        sync.worktreeDirectory = { worktrees.appendingPathComponent($0.uuidString, isDirectory: true) }
        var pulls = 0
        sync.onPulled = { _, _ in pulls += 1 }
        let projectID = UUID()
        var attempts: [Set<String>] = []
        let pushed = await sync.replayKnowledge(projectID, repo: robin, message: "Knowledge: Weekly") { worktree in
            let files = Set((try? FileManager.default.contentsOfDirectory(atPath: worktree.appendingPathComponent("knowledge").path)) ?? [])
            attempts.append(files)
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("private").path))
            #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("meetings/2026-11-12-weekly-robin/summary.md").path))
            if attempts.count == 1 {
                // Anna pushes her own knowledge while the agent works: Robin's push is rejected.
                try self.commit("# Risks\n\n- Late. (meetings/2026-11-12-standup-anna)\n", to: "knowledge/risks.md", in: anna, message: "Knowledge: Standup")
                _ = SharedRepoGit.sync(repo: anna)
            }
            try self.write("# Timeline\n\n- Ship in May. (meetings/2026-11-12-weekly-robin)\n", to: "knowledge/timeline.md", in: worktree)
        }
        #expect(pushed)
        #expect(attempts.count == 2)
        #expect(attempts.last?.contains("risks.md") == true)
        #expect(git(["show", "main:knowledge/timeline.md"], in: origin).succeeded)
        #expect(git(["show", "main:knowledge/risks.md"], in: origin).succeeded)
        #expect(exists("knowledge/timeline.md", in: robin))
        #expect(exists("knowledge/risks.md", in: robin))
        #expect(exists("private/knowledge/ideas.md", in: robin))
        #expect(pulls >= 1)
        #expect(sync.status(for: projectID).state == .idle)
        #expect(sync.status(for: projectID).lastSynced != nil)

        // A step that changes nothing pushes nothing and still succeeds.
        let head = SharedRepoGit.head(of: robin)
        let unchanged = await sync.replayKnowledge(projectID, repo: robin, message: "Knowledge: nothing") { _ in }
        #expect(unchanged)
        #expect(SharedRepoGit.head(of: robin) == head)
    }

    @Test("A sync off main reports a problem status")
    func syncStatusProblem() async throws {
        let (_, _, anna) = try makeRemote()
        git(["switch", "-q", "-c", "feature"], in: anna)
        let sync = SharedProjectSync()
        let projectID = UUID()
        let outcome = await sync.syncNow(projectID, repo: anna)
        #expect(outcome == .problem(SharedRepoGit.switchBackMessage))
        #expect(sync.status(for: projectID).state == .problem(SharedRepoGit.switchBackMessage))
    }
}
