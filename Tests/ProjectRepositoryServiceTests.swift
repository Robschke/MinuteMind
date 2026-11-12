// Purpose: Tests for ProjectRepositoryService: the per-project repo is created with git and a
//          CLAUDE.md, the managed CLAUDE.md block is refreshed without touching user text, and
//          meetings are mirrored as Markdown and follow renames instead of duplicating, and quick
//          recordings land under recordings/ with the time in the folder name.
// Dependencies: Sources/App/Services/ProjectRepositoryService.swift, Sources/App/Store/WorkspaceStore.swift

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("ProjectRepositoryService Tests")
struct ProjectRepositoryServiceTests {
    private func makeService() -> (ProjectRepositoryService, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let service = ProjectRepositoryService(baseDirectory: base, legacyWorkspaceStore: WorkspaceStore(baseDirectory: base))
        return (service, base)
    }

    @Test("A new repo gets git, meetings/ and a CLAUDE.md naming the project")
    func testCreatesRepository() throws {
        let (service, _) = makeService()
        let project = Project(name: "Alpha")
        let repo = service.ensureRepository(for: project)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: repo.appendingPathComponent(".git").path))
        #expect(fm.fileExists(atPath: repo.appendingPathComponent("meetings").path))
        let claude = try String(contentsOf: repo.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(claude.contains("Alpha"))
        #expect(claude.contains(project.id.uuidString))
    }

    @Test("Workspace Claude settings report status and let Claude match the terminal background")
    func testHookSettingsThemeAuto() throws {
        let (service, _) = makeService()
        let data = try Data(contentsOf: service.writeClaudeHookSettings())
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(settings["theme"] as? String == "auto")
        #expect((settings["hooks"] as? [String: Any])?["Stop"] != nil)
    }

    @Test("User text in CLAUDE.md survives a refresh of the managed block")
    func testKeepsUserText() throws {
        let (service, _) = makeService()
        var project = Project(name: "Alpha")
        let repo = service.ensureRepository(for: project)
        let url = repo.appendingPathComponent("CLAUDE.md")
        try (String(contentsOf: url, encoding: .utf8) + "\nAlways answer in German.\n").write(to: url, atomically: true, encoding: .utf8)

        project.name = "Alpha Renamed"
        service.ensureRepository(for: project)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Alpha Renamed"))
        #expect(text.contains("Always answer in German."))
        #expect(text.components(separatedBy: "minutemind:begin").count == 2)
    }

    @Test("Mirrored meetings follow a rename instead of duplicating")
    func testMirrorFollowsRename() throws {
        let (service, _) = makeService()
        let project = Project(name: "Beta")
        var session = RecordingSession(title: "Kickoff", languageCode: "en-US", status: .completed)
        session.transcript = .init(text: "[00:01] You: hello", languageCode: "en-US", updatedAt: Date())
        service.mirror(session: session, minutes: "## Summary\nAll good.", project: project)

        session.title = "Kickoff with Acme"
        service.mirror(session: session, minutes: "## Summary\nAll good.", project: project)

        let meetings = service.repoURL(for: project.id).appendingPathComponent("meetings")
        let folders = try FileManager.default.contentsOfDirectory(atPath: meetings.path)
        #expect(folders.count == 1)
        #expect(folders.first?.hasSuffix("-kickoff-with-acme") == true)
        let summary = try String(contentsOf: meetings.appendingPathComponent(folders[0]).appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(summary.contains("All good."))
        #expect(summary.contains(session.id.uuidString))
    }

    @Test("A mirrored file someone edited is kept, not overwritten")
    func testKeepsEditedMirror() throws {
        let (service, _) = makeService()
        let project = Project(name: "Gamma")
        var session = RecordingSession(title: "Review", languageCode: "en-US", status: .completed)
        session.transcript = .init(text: "[00:01] You: hi", languageCode: "en-US", updatedAt: Date())
        service.mirror(session: session, minutes: "v1", project: project)

        let folder = service.repoURL(for: project.id).appendingPathComponent("meetings").appendingPathComponent(ProjectRepositoryService.folderName(for: session))
        try "my notes".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        service.mirror(session: session, minutes: "v2", project: project)

        #expect(try String(contentsOf: folder.appendingPathComponent("summary.edited.md"), encoding: .utf8) == "my notes")
        #expect(try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8).contains("v2"))

        // A second edit must not replace the first kept copy.
        try "more notes".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        service.mirror(session: session, minutes: "v3", project: project)
        #expect(try String(contentsOf: folder.appendingPathComponent("summary.edited.md"), encoding: .utf8) == "my notes")
        #expect(try String(contentsOf: folder.appendingPathComponent("summary.edited-2.md"), encoding: .utf8) == "more notes")
    }

    @Test("Quick recordings go to recordings/<date>-<time>-<title>, not meetings/")
    func testQuickRecordingMirror() throws {
        let (service, _) = makeService()
        let project = Project(name: "Delta")
        var components = DateComponents(year: 2026, month: 10, day: 4, hour: 9, minute: 5)
        components.timeZone = .current
        let created = try #require(Calendar.current.date(from: components))
        var session = RecordingSession(title: "Recording", createdAt: created, languageCode: "de-DE", status: .completed)
        session.kind = .quickRecording
        session.transcript = .init(text: "[00:01] You: idea for the pitch", languageCode: "de-DE", updatedAt: Date())
        service.mirror(session: session, minutes: nil, project: project)

        let repo = service.repoURL(for: project.id)
        let folder = repo.appendingPathComponent("recordings/2026-10-04-0905-recording")
        let transcript = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(transcript.contains("idea for the pitch"))
        #expect(transcript.contains("kind: recording"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.md").path))
        let meetings = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("meetings").path)
        #expect(meetings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".minutemind/recordings.json").path))
    }

    @Test("A session's kind survives a save and old sessions decode as meetings")
    func testKindCodable() throws {
        var session = RecordingSession(title: "Recording", languageCode: "en-US")
        session.kind = .quickRecording
        let decoded = try JSONDecoder().decode(RecordingSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.isQuickRecording)

        let legacy = try JSONDecoder().decode(RecordingSession.self, from: JSONEncoder().encode(
            RecordingSession(title: "Old", languageCode: "en-US")))
        #expect(legacy.kind == nil)
        #expect(!legacy.isQuickRecording)
    }

    @Test("Slugs have no spaces and transliterate German")
    func testSlug() {
        #expect(ProjectRepositoryService.slug("Weekly Sync: Q3 Größen") == "weekly-sync-q3-groessen")
        #expect(ProjectRepositoryService.slug("  ") == "meeting")
    }
}
