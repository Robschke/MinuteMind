// Purpose: Guards the knowledge-base safety fix: rebuilding one meeting's knowledge never
//          touches notes, manual entries or agent commits.
// Dependencies: Sources/App/Store/KnowledgeStore.swift (replaceMeetingDocuments)

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("Knowledge Rebuild Safety Tests")
struct KnowledgeRebuildSafetyTests {

    private func makeStore() throws -> KnowledgeStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try KnowledgeStore(baseDirectory: dir)
    }

    private func document(_ title: String, meeting: UUID, note: UUID? = nil) -> KnowledgeDocument {
        KnowledgeDocument(
            fullContent: "\(title) content", title: title, category: "General",
            sourceMeetingID: meeting, sourceMeetingTitle: "Meeting", date: Date(), sourceNoteID: note)
    }

    private func chunk(_ text: String) -> KnowledgeChunk {
        KnowledgeChunk(documentID: 0, content: text, chunkIndex: 0, startOffset: 0, endOffset: text.count)
    }

    @Test("Replacing a meeting's knowledge keeps every other source")
    func testReplaceKeepsOtherSources() throws {
        let store = try makeStore()
        let meeting = UUID(), otherMeeting = UUID()

        for var doc in [
            document("old meeting doc", meeting: meeting),
            document("other meeting doc", meeting: otherMeeting),
            document("agent doc", meeting: UUID()),
            document("note doc", meeting: meeting, note: UUID()),
        ] {
            try store.saveDocument(&doc)
            try store.saveChunks([chunk(doc.title)], forDocumentID: doc.id!)
        }

        try store.replaceMeetingDocuments(
            meetingID: meeting, with: [(document("new meeting doc", meeting: meeting), [chunk("fresh")])])

        let titles = Set(try store.fetchAllDocuments().map(\.title))
        #expect(titles == ["new meeting doc", "other meeting doc", "agent doc", "note doc"])
        #expect(try store.searchChunks(keyword: "fresh").count == 1)
    }
}
