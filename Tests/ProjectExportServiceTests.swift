import Foundation
import Testing

@testable import MinuteMindApp

struct ProjectExportServiceTests {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSession(title: String = "Weekly Sync") -> RecordingSession {
        RecordingSession(title: title, languageCode: "en-US", status: .completed)
    }

    @Test func exportCreatesDayAndMeetingFolder() throws {
        let base = makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let project = Project(name: "Alpha", exportFolderPath: base.path)
        let session = makeSession()

        let relative = try ProjectExportService.export(
            .transcript, text: "hello", session: session, project: project)

        let expectedDay: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: session.createdAt)
        }()
        #expect(relative == "\(expectedDay)/Weekly Sync")
        let fileURL = base.appendingPathComponent("\(relative!)/transcript.txt")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "hello")
    }

    @Test func reExportCreatesNewVersionInsteadOfOverwriting() throws {
        let base = makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let project = Project(name: "Alpha", exportFolderPath: base.path)
        var session = makeSession()

        session.exportFolderName = try ProjectExportService.export(
            .summary, text: "first", session: session, project: project)
        _ = try ProjectExportService.export(
            .summary, text: "second", session: session, project: project)
        _ = try ProjectExportService.export(
            .summary, text: "third", session: session, project: project)

        let folder = base.appendingPathComponent(session.exportFolderName!)
        #expect(
            try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
                == "first")
        #expect(
            try String(contentsOf: folder.appendingPathComponent("summary-v2.md"), encoding: .utf8)
                == "second")
        #expect(
            try String(contentsOf: folder.appendingPathComponent("summary-v3.md"), encoding: .utf8)
                == "third")
    }

    @Test func identicalContentDoesNotCreateDuplicateVersion() throws {
        let base = makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let project = Project(name: "Alpha", exportFolderPath: base.path)
        var session = makeSession()

        session.exportFolderName = try ProjectExportService.export(
            .transcript, text: "same", session: session, project: project)
        _ = try ProjectExportService.export(
            .transcript, text: "same", session: session, project: project)

        let folder = base.appendingPathComponent(session.exportFolderName!)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files == ["transcript.txt"])
    }

    @Test func optOutAndMissingFolderSkipExport() throws {
        let base = makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let session = makeSession()

        let optedOut = Project(name: "A", exportFolderPath: base.path, exportOptOut: true)
        #expect(
            try ProjectExportService.export(
                .transcript, text: "x", session: session, project: optedOut) == nil)

        let unconfigured = Project(name: "B")
        #expect(
            try ProjectExportService.export(
                .transcript, text: "x", session: session, project: unconfigured) == nil)
    }

    @Test func sanitizedFolderNameStripsUnsafeCharacters() {
        #expect(ProjectExportService.sanitizedFolderName("Q3: Plan / Review?") == "Q3 Plan Review")
        #expect(ProjectExportService.sanitizedFolderName("///") == "Untitled Meeting")
        #expect(ProjectExportService.sanitizedFolderName("  Sync  ") == "Sync")
    }

    @Test func renameMeetingFolderMovesDirectory() throws {
        let base = makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let project = Project(name: "Alpha", exportFolderPath: base.path)
        var session = makeSession(title: "Untitled")

        session.exportFolderName = try ProjectExportService.export(
            .transcript, text: "hello", session: session, project: project)
        let oldFolder = base.appendingPathComponent(session.exportFolderName!)

        let newRelative = ProjectExportService.renameMeetingFolder(
            session: session, project: project, newTitle: "Budget Meeting")
        #expect(newRelative?.hasSuffix("/Budget Meeting") == true)
        #expect(!FileManager.default.fileExists(atPath: oldFolder.path))
        let newFile = base.appendingPathComponent("\(newRelative!)/transcript.txt")
        #expect(try String(contentsOf: newFile, encoding: .utf8) == "hello")
    }

    @Test func isExportConfiguredRequiresFolderOrOptOut() {
        #expect(Project(name: "A").isExportConfigured == false)
        #expect(Project(name: "B", exportFolderPath: "/tmp/x").isExportConfigured == true)
        #expect(Project(name: "C", exportOptOut: true).isExportConfigured == true)
        #expect(Project(name: "D", exportFolderPath: "").isExportConfigured == false)
    }
}
