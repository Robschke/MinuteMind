import Foundation
import GRDB

/// A chunk of content from a `KnowledgeDocument`, optimized for search and retrieval.
/// Each chunk contains a portion of the parent document's content with optional embeddings
/// for semantic search.
struct KnowledgeChunk: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "knowledgeChunk"

    var id: Int64?
    /// Foreign key to the parent document
    var documentID: Int64
    /// The chunked content (~500 tokens / ~2000 chars)
    var content: String
    /// Position of this chunk in the document (0-indexed)
    var chunkIndex: Int
    /// Start character offset in the original document
    var startOffset: Int
    /// End character offset in the original document
    var endOffset: Int
    /// Embedding vector for semantic search
    var embedding: [Double]?

    init(
        id: Int64? = nil,
        documentID: Int64,
        content: String,
        chunkIndex: Int,
        startOffset: Int,
        endOffset: Int,
        embedding: [Double]? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.content = content
        self.chunkIndex = chunkIndex
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.embedding = embedding
    }

    // MARK: - FetchableRecord

    init(row: Row) throws {
        id = row["id"]
        documentID = row["documentID"]
        content = row["content"]
        chunkIndex = row["chunkIndex"]
        startOffset = row["startOffset"]
        endOffset = row["endOffset"]
        if let data: Data = row["embedding"] {
            embedding = try? JSONDecoder().decode([Double].self, from: data)
        } else {
            embedding = nil
        }
    }

    // MARK: - PersistableRecord

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["documentID"] = documentID
        container["content"] = content
        container["chunkIndex"] = chunkIndex
        container["startOffset"] = startOffset
        container["endOffset"] = endOffset
        if let embedding = embedding {
            container["embedding"] = try? JSONEncoder().encode(embedding)
        } else {
            container["embedding"] = nil
        }
    }
}

// MARK: - Search Result

/// A search result containing a chunk with its parent document context
struct ChunkSearchResult: Equatable {
    let chunk: KnowledgeChunk
    let document: KnowledgeDocument
    let similarity: Double?  // For semantic search results

    /// Format the result for AI consumption with document reference
    func formatForAI() -> String {
        let docRef = document.id.map { "Doc:\($0)" } ?? "Doc:?"
        let chunkRef = "Chunk:\(chunk.chunkIndex)"
        return
            "[\(docRef), \(chunkRef)] (Category: \(document.category), Source: \(document.sourceMeetingTitle))\n\(chunk.content)"
    }
}
