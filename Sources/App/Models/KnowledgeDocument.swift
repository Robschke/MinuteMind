import Foundation
import GRDB

/// A full document in the knowledge base, representing complete content from a source.
/// Documents are chunked into `KnowledgeChunk` records for efficient retrieval.
struct KnowledgeDocument: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "knowledgeDocument"

    var id: Int64?
    var fullContent: String
    var title: String
    var category: String
    var sourceMeetingID: UUID
    var sourceMeetingTitle: String
    var projectID: UUID?
    var date: Date
    var attachments: [FileAttachment]?
    /// Links this document to the EventNote it was embedded from (nil for non-note docs)
    var sourceNoteID: UUID?

    init(
        id: Int64? = nil,
        fullContent: String,
        title: String,
        category: String,
        sourceMeetingID: UUID,
        sourceMeetingTitle: String,
        projectID: UUID? = nil,
        date: Date,
        attachments: [FileAttachment]? = nil,
        sourceNoteID: UUID? = nil
    ) {
        self.id = id
        self.fullContent = fullContent
        self.title = title
        self.category = category
        self.sourceMeetingID = sourceMeetingID
        self.sourceMeetingTitle = sourceMeetingTitle
        self.projectID = projectID
        self.date = date
        self.attachments = attachments
        self.sourceNoteID = sourceNoteID
    }

    // MARK: - FetchableRecord

    init(row: Row) throws {
        id = row["id"]
        fullContent = row["fullContent"]
        title = row["title"]
        category = row["category"]
        sourceMeetingID = UUID(uuidString: row["sourceMeetingID"]) ?? UUID()
        sourceMeetingTitle = row["sourceMeetingTitle"]
        projectID = row["projectID"] != nil ? UUID(uuidString: row["projectID"]) : nil
        date = row["date"]
        if let data: Data = row["attachments"] {
            attachments = try? JSONDecoder().decode([FileAttachment].self, from: data)
        } else {
            attachments = nil
        }
        let noteIDStr: String? = row["sourceNoteID"]
        sourceNoteID = noteIDStr.flatMap { UUID(uuidString: $0) }
    }

    // MARK: - PersistableRecord

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["fullContent"] = fullContent
        container["title"] = title
        container["category"] = category
        container["sourceMeetingID"] = sourceMeetingID.uuidString
        container["sourceMeetingTitle"] = sourceMeetingTitle
        container["projectID"] = projectID?.uuidString
        container["date"] = date
        if let attachments = attachments {
            container["attachments"] = try? JSONEncoder().encode(attachments)
        } else {
            container["attachments"] = nil
        }
        container["sourceNoteID"] = sourceNoteID?.uuidString
    }
}
