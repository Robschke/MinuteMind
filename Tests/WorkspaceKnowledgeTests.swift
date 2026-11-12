// Purpose: Tests for knowledge in the workspaces: the knowledge/ folder and CLAUDE.md rules, the
//          General workspace, unmirroring a moved meeting, cleanup of emptied knowledge files,
//          and the index that mirrors knowledge files into the knowledge base. No Claude runs.
// Dependencies: Sources/App/Services/ProjectRepositoryService.swift,
//               Sources/App/Services/KnowledgeCurationService.swift,
//               Sources/App/Services/KnowledgeIndexer.swift, Sources/App/Store/KnowledgeStore.swift

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
struct WorkspaceKnowledgeTests {
    private func makeService() -> ProjectRepositoryService {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return ProjectRepositoryService(baseDirectory: base, legacyWorkspaceStore: WorkspaceStore(baseDirectory: base))
    }

    private func processedSession(_ title: String) -> RecordingSession {
        var session = RecordingSession(title: title, languageCode: "en-US", status: .completed)
        session.transcript = .init(text: "[00:01] You: hello", languageCode: "en-US", updatedAt: Date())
        return session
    }

    @Test func repoHasKnowledgeFolderAndRules() throws {
        let service = makeService()
        let repo = service.ensureRepository(for: Project(name: "Alpha"))
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("knowledge").path))
        let claude = try String(contentsOf: repo.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(claude.contains("## Knowledge"))
        #expect(claude.contains("knowledge/"))
    }

    @Test func generalWorkspaceDescribesItself() throws {
        let service = makeService()
        let repo = service.ensureRepository(for: ProjectRepositoryService.generalProject)
        #expect(repo.lastPathComponent == ProjectRepositoryService.generalProjectID.uuidString)
        let claude = try String(contentsOf: repo.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(claude.contains("General workspace"))
        #expect(service.existingRepositories().map(\.projectID).contains(ProjectRepositoryService.generalProjectID))
    }

    @Test func unmirrorRemovesTheMeetingFolder() {
        let service = makeService()
        let project = Project(name: "Alpha")
        let session = processedSession("API Sync")
        service.mirror(session: session, minutes: "## Summary\nOAuth.", project: project)
        let folder = service.mirroredFolder(for: session, in: project)
        #expect(folder?.hasPrefix("meetings/") == true)

        let removed = service.unmirror(session: session, from: project)
        #expect(removed == folder)
        #expect(service.mirroredFolder(for: session, in: project) == nil)
        let path = service.repoURL(for: project.id).appendingPathComponent(folder ?? "x").path
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func emptiedKnowledgeFilesAreRemoved() throws {
        let service = makeService()
        let repo = service.ensureRepository(for: Project(name: "Alpha"))
        let knowledge = repo.appendingPathComponent("knowledge")
        try "# Timeline\n\n".write(to: knowledge.appendingPathComponent("timeline.md"), atomically: true, encoding: .utf8)
        try "".write(to: knowledge.appendingPathComponent("empty.md"), atomically: true, encoding: .utf8)
        try "# Architecture\n\n- OAuth2. (meetings/x)\n".write(to: knowledge.appendingPathComponent("architecture.md"), atomically: true, encoding: .utf8)

        let removed = KnowledgeCurator.removeEmptyKnowledgeFiles(in: repo)
        #expect(Set(removed) == ["knowledge/timeline.md", "knowledge/empty.md"])
        #expect(service.knowledgeFiles(in: repo).map(\.lastPathComponent) == ["architecture.md"])
    }

    @Test func documentIDsAreStable() {
        let repo = UUID()
        let first = KnowledgeIndexer.documentID(repoID: repo, relativePath: "knowledge/a.md")
        #expect(first == KnowledgeIndexer.documentID(repoID: repo, relativePath: "knowledge/a.md"))
        #expect(first != KnowledgeIndexer.documentID(repoID: repo, relativePath: "knowledge/b.md"))
        let source = KnowledgeIndexer.source(repoID: repo, relativePath: "knowledge/a.md")
        #expect(KnowledgeIndexer.file(fromSource: source)?.relativePath == "knowledge/a.md")
        #expect(KnowledgeIndexer.file(fromSource: "Agent Knowledge") == nil)
    }

    @Test func indexFollowsTheFiles() async throws {
        let service = makeService()
        let project = Project(name: "Alpha")
        let repo = service.ensureRepository(for: project)
        let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = try KnowledgeStore(baseDirectory: storeDir)
        let knowledge = repo.appendingPathComponent("knowledge")
        let file = knowledge.appendingPathComponent("architecture.md")
        try "# Architecture\n\n- The API uses OAuth2 client credentials. (meetings/2026-10-01-api-sync)\n"
            .write(to: file, atomically: true, encoding: .utf8)

        func reindex() async {
            await KnowledgeIndexer.index(
                repoID: project.id, repo: repo, files: service.knowledgeFiles(in: repo),
                projectID: project.id, store: store)
        }

        await reindex()
        var docs = try store.fetchAllDocuments(projectID: project.id)
        #expect(docs.count == 1)
        #expect(docs.first?.title == "Architecture")
        #expect(try store.searchChunks(keyword: "OAuth2", projectID: project.id).count == 1)

        // Reindexing an unchanged file keeps the one document.
        await reindex()
        #expect(try store.fetchAllDocuments(projectID: project.id).count == 1)

        // A changed file replaces its document; a deleted file removes it.
        try "# Architecture\n\n- The API uses mutual TLS. (meetings/2026-10-08-security)\n"
            .write(to: file, atomically: true, encoding: .utf8)
        await reindex()
        docs = try store.fetchAllDocuments(projectID: project.id)
        #expect(docs.count == 1)
        #expect(docs.first?.fullContent.contains("mutual TLS") == true)
        #expect(try store.searchChunks(keyword: "OAuth2", projectID: project.id).isEmpty)

        try FileManager.default.removeItem(at: file)
        await reindex()
        #expect(try store.fetchAllDocuments(projectID: project.id).isEmpty)
    }

    @Test func indexLeavesNotesAlone() async throws {
        let service = makeService()
        let project = Project(name: "Alpha")
        let repo = service.ensureRepository(for: project)
        let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = try KnowledgeStore(baseDirectory: storeDir)
        var note = KnowledgeDocument(
            fullContent: "Call Jonas", title: "Note", category: "Note", sourceMeetingID: UUID(),
            sourceMeetingTitle: "Note", projectID: project.id, date: Date(), sourceNoteID: UUID())
        try store.saveDocument(&note)

        await KnowledgeIndexer.index(
            repoID: project.id, repo: repo, files: [], projectID: project.id, store: store)
        #expect(try store.fetchAllDocuments(projectID: project.id).count == 1)
    }
}
