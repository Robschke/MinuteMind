import Foundation
import GRDB
import Testing

@testable import MinuteMindApp

struct KnowledgeBaseTests {

    @Test func knowledgeExtraction() async throws {
        let sampleMinutes = """
            # Meeting Minutes

            ## Summary
            This was a great meeting.

            ## Project Knowledge
            ### Architecture
            We decided to use MVVM pattern.
            Storage will be SQLite.

            ### Risks
            Timeline is tight.

            ## Action Items
            - Do this
            """

        let id = UUID()
        let date = Date()
        let results = KnowledgeExtractionService.extract(
            from: sampleMinutes,
            meetingID: id,
            meetingTitle: "Test Meeting",
            date: date
        )

        // Should now have 2 results: Project Knowledge sections only (no full minutes)
        #expect(results.count == 2)

        // Check individual project knowledge sections
        let archResult = results.first(where: { $0.document.category == "Architecture" })
        #expect(archResult != nil)
        // Check document content
        #expect(archResult?.document.fullContent.contains("MVVM pattern") == true)
        // Check chunking (should be at least 1 chunk)
        #expect(archResult?.chunks.isEmpty == false)
        #expect(archResult?.chunks.first?.content.contains("MVVM pattern") == true)

        let riskResult = results.first(where: { $0.document.category == "Risks" })
        #expect(riskResult != nil)
        #expect(riskResult?.document.fullContent.contains("Timeline is tight") == true)
    }

    @Test func knowledgeStoreCRUD() throws {
        // Use in-memory DB for testing
        let tempDir = FileManager.default.temporaryDirectory
        let dbDir = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let store = try KnowledgeStore(baseDirectory: dbDir)

        let project1 = UUID()
        let project2 = UUID()

        var doc1 = KnowledgeDocument(
            fullContent: "Test Content Project 1. This is a sentence.",
            title: "Doc 1",
            category: "Test Category",
            sourceMeetingID: UUID(),
            sourceMeetingTitle: "Meeting 1",
            projectID: project1,
            date: Date()
        )

        var doc2 = KnowledgeDocument(
            fullContent: "Test Content Project 2. This is another sentence.",
            title: "Doc 2",
            category: "Test Category",
            sourceMeetingID: UUID(),
            sourceMeetingTitle: "Meeting 2",
            projectID: project2,
            date: Date()
        )

        try store.saveDocument(&doc1)
        try store.saveDocument(&doc2)

        guard let id1 = doc1.id, let id2 = doc2.id else {
            #expect(Bool(false), "IDs should be set")
            return
        }

        // Add chunks
        let chunk1 = KnowledgeChunk(
            documentID: id1,
            content: "Test Content Project 1.",
            chunkIndex: 0,
            startOffset: 0,
            endOffset: 10,
            embedding: nil
        )
        try store.saveChunks([chunk1], forDocumentID: id1)

        let chunk2 = KnowledgeChunk(
            documentID: id2,
            content: "Test Content Project 2.",
            chunkIndex: 0,
            startOffset: 0,
            endOffset: 10,
            embedding: nil
        )
        try store.saveChunks([chunk2], forDocumentID: id2)

        // Test display fetch (documents)
        let fetchAllDocs = try store.fetchAllDocuments()
        #expect(fetchAllDocs.count == 2)

        // Test project-specific fetch
        let fetchProject1 = try store.fetchAllDocuments(projectID: project1)
        #expect(fetchProject1.count == 1)
        #expect(fetchProject1.first?.projectID == project1)

        // Test chunk search
        let project1Search = try store.searchChunks(keyword: "Content", projectID: project1)
        #expect(project1Search.count == 1)
        #expect(project1Search.first?.document.projectID == project1)

        let project2Search = try store.searchChunks(keyword: "Content", projectID: project2)
        #expect(project2Search.count == 1)
        #expect(project2Search.first?.document.projectID == project2)

        let globalSearch = try store.searchChunks(keyword: "Content")
        #expect(globalSearch.count == 2)

        let noResults = try store.searchChunks(keyword: "Banana")
        #expect(noResults.count == 0)

        // Clean up
        try FileManager.default.removeItem(at: dbDir)
    }
}
