import Foundation
import GRDB

/// Manages the local SQLite knowledge base
final class KnowledgeStore {
    private let dbQueue: DatabaseQueue

    init(baseDirectory: URL) throws {
        let databaseURL = baseDirectory.appendingPathComponent("knowledge.sqlite")

        let config = Configuration()

        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "knowledgeEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("content", .text).notNull()
                t.column("category", .text).notNull()
                t.column("sourceMeetingID", .text).notNull()
                t.column("sourceMeetingTitle", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("embedding", .blob)  // Stored as JSON data
            }

            // FTS5 table for keyword search
            try db.create(virtualTable: "knowledgeEntry_fts", using: FTS5()) { t in
                t.tokenizer = .porter()  // stemming support
                t.column("content")
                t.column("category")
                t.column("sourceMeetingTitle")
                t.content = "knowledgeEntry"
            }

            // Triggers to keep FTS index in sync
            try db.execute(
                sql: """
                        CREATE TRIGGER knowledgeEntry_ai AFTER INSERT ON knowledgeEntry BEGIN
                            INSERT INTO knowledgeEntry_fts(rowid, content, category, sourceMeetingTitle)
                            VALUES (new.rowid, new.content, new.category, new.sourceMeetingTitle);
                        END;
                        CREATE TRIGGER knowledgeEntry_ad AFTER DELETE ON knowledgeEntry BEGIN
                            INSERT INTO knowledgeEntry_fts(knowledgeEntry_fts, rowid, content, category, sourceMeetingTitle)
                            VALUES('delete', old.rowid, old.content, old.category, old.sourceMeetingTitle);
                        END;
                        CREATE TRIGGER knowledgeEntry_au AFTER UPDATE ON knowledgeEntry BEGIN
                            INSERT INTO knowledgeEntry_fts(knowledgeEntry_fts, rowid, content, category, sourceMeetingTitle)
                            VALUES('delete', old.rowid, old.content, old.category, old.sourceMeetingTitle);
                            INSERT INTO knowledgeEntry_fts(rowid, content, category, sourceMeetingTitle)
                            VALUES (new.rowid, new.content, new.category, new.sourceMeetingTitle);
                        END;
                    """)
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "knowledgeEntry") { t in
                t.add(column: "projectID", .text)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "knowledgeEntry") { t in
                t.add(column: "attachments", .blob)
            }
        }

        migrator.registerMigration("v4") { db in
            // 1. Create KnowledgeDocument table
            try db.create(table: "knowledgeDocument") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fullContent", .text).notNull()
                t.column("title", .text).notNull()
                t.column("category", .text).notNull()
                t.column("sourceMeetingID", .text).notNull()
                t.column("sourceMeetingTitle", .text).notNull()
                t.column("projectID", .text)
                t.column("date", .datetime).notNull()
                t.column("attachments", .blob)
            }

            // 2. Create KnowledgeChunk table
            try db.create(table: "knowledgeChunk") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("documentID", .integer).notNull().references(
                    "knowledgeDocument", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("chunkIndex", .integer).notNull()
                t.column("startOffset", .integer).notNull()
                t.column("endOffset", .integer).notNull()
                t.column("embedding", .blob)
            }

            // 3. Create FTS5 table for chunks
            try db.create(virtualTable: "knowledgeChunk_fts", using: FTS5()) { t in
                t.tokenizer = .porter()
                t.column("content")
                t.content = "knowledgeChunk"
            }

            // 4. Triggers for Chunk FTS
            try db.execute(
                sql: """
                        CREATE TRIGGER knowledgeChunk_ai AFTER INSERT ON knowledgeChunk BEGIN
                            INSERT INTO knowledgeChunk_fts(rowid, content) VALUES (new.rowid, new.content);
                        END;
                        CREATE TRIGGER knowledgeChunk_ad AFTER DELETE ON knowledgeChunk BEGIN
                            INSERT INTO knowledgeChunk_fts(knowledgeChunk_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                        END;
                        CREATE TRIGGER knowledgeChunk_au AFTER UPDATE ON knowledgeChunk BEGIN
                            INSERT INTO knowledgeChunk_fts(knowledgeChunk_fts, rowid, content) VALUES('delete', old.rowid, old.content);
                            INSERT INTO knowledgeChunk_fts(rowid, content) VALUES (new.rowid, new.content);
                        END;
                    """)

            // 5. DATA MIGRATION: Move KnowledgeEntry -> Document + Chunks
            let rows = try Row.fetchCursor(db, sql: "SELECT * FROM knowledgeEntry")
            while let row = try rows.next() {
                let content: String = row["content"]
                let category: String = row["category"]
                let meetingIDStr: String = row["sourceMeetingID"]
                let meetingTitle: String = row["sourceMeetingTitle"]
                let projectIDStr: String? = row["projectID"]
                let date: Date = row["date"]
                let attachmentsData: Data? = row["attachments"]
                let oldEmbedding: Data? = row["embedding"]

                // Create Document
                var document = KnowledgeDocument(
                    fullContent: content,
                    title: "Entry from \(date.formatted(date: .numeric, time: .shortened))",
                    category: category,
                    sourceMeetingID: UUID(uuidString: meetingIDStr) ?? UUID(),
                    sourceMeetingTitle: meetingTitle,
                    projectID: projectIDStr != nil ? UUID(uuidString: projectIDStr!) : nil,
                    date: date,
                    attachments: nil
                )

                if let data = attachmentsData {
                    document.attachments = try? JSONDecoder().decode(
                        [FileAttachment].self, from: data)
                }

                try document.insert(db)
                let docID = db.lastInsertedRowID

                // Chunking Logic (Simplified for migration)
                let chunks = KnowledgeStore.performMigrationChunking(content: content)

                for (index, chunkText) in chunks.enumerated() {
                    let start =
                        content.range(of: chunkText)?.lowerBound.utf16Offset(in: content) ?? 0
                    let end = start + chunkText.count

                    var chunk = KnowledgeChunk(
                        documentID: docID,
                        content: chunkText,
                        chunkIndex: index,
                        startOffset: start,
                        endOffset: end,
                        embedding: (index == 0 && oldEmbedding != nil)
                            ? try? JSONDecoder().decode([Double].self, from: oldEmbedding!) : nil
                    )
                    try chunk.insert(db)
                }
            }

            // 6. Drop old tables
            try db.drop(table: "knowledgeEntry")
            try db.drop(table: "knowledgeEntry_fts")
        }
        migrator.registerMigration("v5") { db in
            // Add FTS5 index on document title for hybrid search
            try db.create(virtualTable: "knowledgeDocument_fts", using: FTS5()) { t in
                t.tokenizer = .porter()  // stemming support
                t.column("title")
                t.content = "knowledgeDocument"
            }

            // Triggers to keep FTS index in sync
            try db.execute(
                sql: """
                    CREATE TRIGGER knowledgeDocument_ai AFTER INSERT ON knowledgeDocument BEGIN
                        INSERT INTO knowledgeDocument_fts(rowid, title)
                        VALUES (new.rowid, new.title);
                    END;
                    CREATE TRIGGER knowledgeDocument_ad AFTER DELETE ON knowledgeDocument BEGIN
                        INSERT INTO knowledgeDocument_fts(knowledgeDocument_fts, rowid, title)
                        VALUES('delete', old.rowid, old.title);
                    END;
                    CREATE TRIGGER knowledgeDocument_au AFTER UPDATE ON knowledgeDocument BEGIN
                        INSERT INTO knowledgeDocument_fts(knowledgeDocument_fts, rowid, title)
                        VALUES('delete', old.rowid, old.title);
                        INSERT INTO knowledgeDocument_fts(rowid, title)
                        VALUES (new.rowid, new.title);
                    END;
                    """)
        }
        migrator.registerMigration("v6") { db in
            try db.alter(table: "knowledgeDocument") { t in
                t.add(column: "sourceNoteID", .text)
            }
        }
        return migrator
    }

    /// Simple chunking for migration purposes
    private static func performMigrationChunking(content: String) -> [String] {
        let maxChunkSize = 2000
        var chunks: [String] = []
        var currentChunk = ""

        let sentences = content.components(separatedBy: ". ")

        for sentence in sentences {
            let s = sentence + ". "
            if currentChunk.count + s.count > maxChunkSize {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                currentChunk = s
            } else {
                currentChunk += s
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if chunks.isEmpty && !content.isEmpty {
            chunks.append(content)
        }

        return chunks
    }

    // MARK: - API

    func saveDocument(_ document: inout KnowledgeDocument) throws {
        try dbQueue.write { db in
            if document.id == nil {
                try document.insert(db)
                document.id = db.lastInsertedRowID
            } else {
                try document.update(db)
            }
        }
    }

    func saveChunks(_ chunks: [KnowledgeChunk], forDocumentID docID: Int64) throws {
        try dbQueue.write { db in
            try KnowledgeChunk.filter(Column("documentID") == docID).deleteAll(db)

            for var chunk in chunks {
                chunk.documentID = docID
                try chunk.insert(db)
            }
        }
    }

    func updateChunk(_ chunk: KnowledgeChunk) throws {
        try dbQueue.write { db in
            try chunk.update(db)
        }
    }

    func fetchDocument(id: Int64) throws -> KnowledgeDocument? {
        try dbQueue.read { db in
            try KnowledgeDocument.fetchOne(db, key: id)
        }
    }

    func fetchAllDocuments(projectID: UUID? = nil) throws -> [KnowledgeDocument] {
        try dbQueue.read { db in
            if let projectID = projectID {
                return try KnowledgeDocument.filter(Column("projectID") == projectID.uuidString)
                    .fetchAll(db)
            } else {
                return try KnowledgeDocument.fetchAll(db)
            }
        }
    }

    func fetchAllChunks(projectID: UUID? = nil) throws -> [ChunkSearchResult] {
        try dbQueue.read { db in
            var sql = """
                    SELECT 
                        knowledgeChunk.id as chunkId,
                        knowledgeChunk.documentID,
                        knowledgeChunk.content,
                        knowledgeChunk.chunkIndex,
                        knowledgeChunk.startOffset,
                        knowledgeChunk.endOffset,
                        knowledgeChunk.embedding as chunkEmbedding,
                        knowledgeDocument.id as docId,
                        knowledgeDocument.fullContent,
                        knowledgeDocument.title,
                        knowledgeDocument.category,
                        knowledgeDocument.sourceMeetingID,
                        knowledgeDocument.sourceMeetingTitle,
                        knowledgeDocument.projectID,
                        knowledgeDocument.date,
                        knowledgeDocument.attachments
                    FROM knowledgeChunk
                    JOIN knowledgeDocument ON knowledgeChunk.documentID = knowledgeDocument.id
                """

            var arguments: [Any] = []

            if let projectID = projectID {
                sql += " WHERE knowledgeDocument.projectID = ?"
                arguments.append(projectID.uuidString)
            }

            let rows = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(arguments)!)
            var results: [ChunkSearchResult] = []

            while let row = try rows.next() {
                // Manually construct chunk with correct ID
                let chunkEmbeddingData: Data? = row["chunkEmbedding"]
                let chunkEmbedding = chunkEmbeddingData.flatMap { try? JSONDecoder().decode([Double].self, from: $0) }
                
                let chunk = KnowledgeChunk(
                    id: row["chunkId"],
                    documentID: row["documentID"],
                    content: row["content"],
                    chunkIndex: row["chunkIndex"],
                    startOffset: row["startOffset"],
                    endOffset: row["endOffset"],
                    embedding: chunkEmbedding
                )
                
                // Manually construct document with correct ID
                let attachmentsData: Data? = row["attachments"]
                let attachments = attachmentsData.flatMap { try? JSONDecoder().decode([FileAttachment].self, from: $0) }
                
                let document = KnowledgeDocument(
                    id: row["docId"],
                    fullContent: row["fullContent"],
                    title: row["title"],
                    category: row["category"],
                    sourceMeetingID: UUID(uuidString: row["sourceMeetingID"]) ?? UUID(),
                    sourceMeetingTitle: row["sourceMeetingTitle"],
                    projectID: row["projectID"] != nil ? UUID(uuidString: row["projectID"]) : nil,
                    date: row["date"],
                    attachments: attachments
                )
                
                results.append(ChunkSearchResult(chunk: chunk, document: document, similarity: nil))
            }

            return results
        }
    }

    // MARK: - Search

    func searchChunks(keyword: String, projectID: UUID? = nil) throws -> [ChunkSearchResult] {
        try dbQueue.read { db in
            if let pattern = FTS5Pattern(matchingAllTokensIn: keyword) {
                // Hybrid search: title matches (boosted) + content matches
                // First, get title matches - these are most relevant
                var titleSql = """
                        SELECT 
                            knowledgeChunk.id as chunkId,
                            knowledgeChunk.documentID,
                            knowledgeChunk.content,
                            knowledgeChunk.chunkIndex,
                            knowledgeChunk.startOffset,
                            knowledgeChunk.endOffset,
                            knowledgeChunk.embedding as chunkEmbedding,
                            knowledgeDocument.id as docId,
                            knowledgeDocument.fullContent,
                            knowledgeDocument.title,
                            knowledgeDocument.category,
                            knowledgeDocument.sourceMeetingID,
                            knowledgeDocument.sourceMeetingTitle,
                            knowledgeDocument.projectID,
                            knowledgeDocument.date,
                            knowledgeDocument.attachments,
                            0 as searchRank
                        FROM knowledgeDocument
                        JOIN knowledgeDocument_fts ON knowledgeDocument_fts.rowid = knowledgeDocument.id
                        JOIN knowledgeChunk ON knowledgeChunk.documentID = knowledgeDocument.id
                        WHERE knowledgeDocument_fts MATCH ?
                    """
                
                var titleArguments: [Any] = [pattern]
                
                if let projectID = projectID {
                    titleSql += " AND knowledgeDocument.projectID = ?"
                    titleArguments.append(projectID.uuidString)
                }
                
                // Then, get content matches
                var contentSql = """
                        SELECT 
                            knowledgeChunk.id as chunkId,
                            knowledgeChunk.documentID,
                            knowledgeChunk.content,
                            knowledgeChunk.chunkIndex,
                            knowledgeChunk.startOffset,
                            knowledgeChunk.endOffset,
                            knowledgeChunk.embedding as chunkEmbedding,
                            knowledgeDocument.id as docId,
                            knowledgeDocument.fullContent,
                            knowledgeDocument.title,
                            knowledgeDocument.category,
                            knowledgeDocument.sourceMeetingID,
                            knowledgeDocument.sourceMeetingTitle,
                            knowledgeDocument.projectID,
                            knowledgeDocument.date,
                            knowledgeDocument.attachments,
                            1 as searchRank
                        FROM knowledgeChunk
                        JOIN knowledgeChunk_fts ON knowledgeChunk_fts.rowid = knowledgeChunk.id
                        JOIN knowledgeDocument ON knowledgeChunk.documentID = knowledgeDocument.id
                        WHERE knowledgeChunk_fts MATCH ?
                    """

                var contentArguments: [Any] = [pattern]

                if let projectID = projectID {
                    contentSql += " AND knowledgeDocument.projectID = ?"
                    contentArguments.append(projectID.uuidString)
                }

                // Combine both queries with UNION, ordering by searchRank (title matches first), then by FTS rank
                let sql = "\(titleSql) UNION \(contentSql) ORDER BY searchRank, chunkId LIMIT 20"
                let arguments = titleArguments + contentArguments

                let rows = try Row.fetchCursor(
                    db, sql: sql, arguments: StatementArguments(arguments)!)
                var results: [ChunkSearchResult] = []
                var seenChunkIDs = Set<Int64>()

                while let row = try rows.next() {
                    // Deduplicate chunks that appear in both title and content results
                    let chunkId: Int64 = row["chunkId"]
                    if seenChunkIDs.contains(chunkId) {
                        continue
                    }
                    seenChunkIDs.insert(chunkId)
                    
                    // Manually construct chunk with correct ID
                    let chunkEmbeddingData: Data? = row["chunkEmbedding"]
                    let chunkEmbedding = chunkEmbeddingData.flatMap { try? JSONDecoder().decode([Double].self, from: $0) }
                    
                    let chunk = KnowledgeChunk(
                        id: row["chunkId"],
                        documentID: row["documentID"],
                        content: row["content"],
                        chunkIndex: row["chunkIndex"],
                        startOffset: row["startOffset"],
                        endOffset: row["endOffset"],
                        embedding: chunkEmbedding
                    )
                    
                    // Manually construct document with correct ID
                    let attachmentsData: Data? = row["attachments"]
                    let attachments = attachmentsData.flatMap { try? JSONDecoder().decode([FileAttachment].self, from: $0) }
                    
                    let document = KnowledgeDocument(
                        id: row["docId"],
                        fullContent: row["fullContent"],
                        title: row["title"],
                        category: row["category"],
                        sourceMeetingID: UUID(uuidString: row["sourceMeetingID"]) ?? UUID(),
                        sourceMeetingTitle: row["sourceMeetingTitle"],
                        projectID: row["projectID"] != nil ? UUID(uuidString: row["projectID"]) : nil,
                        date: row["date"],
                        attachments: attachments
                    )
                    
                    results.append(
                        ChunkSearchResult(chunk: chunk, document: document, similarity: nil))
                }

                return results
            } else {
                // Invalid pattern or empty
                return []
            }
        }
    }

    func fetchDocument(byNoteID noteID: UUID) throws -> KnowledgeDocument? {
        try dbQueue.read { db in
            try KnowledgeDocument
                .filter(Column("sourceNoteID") == noteID.uuidString)
                .fetchOne(db)
        }
    }

    func fetchDocument(projectID: UUID, category: String) throws -> KnowledgeDocument? {
        try dbQueue.read { db in
            try KnowledgeDocument
                .filter(Column("projectID") == projectID.uuidString)
                .filter(Column("category") == category)
                .filter(Column("sourceNoteID") == nil)
                .order(Column("date").desc)
                .fetchOne(db)
        }
    }

    func fetchDocuments(byMeetingID meetingID: UUID) throws -> [KnowledgeDocument] {
        try dbQueue.read { db in
            try KnowledgeDocument
                .filter(Column("sourceMeetingID") == meetingID.uuidString)
                .fetchAll(db)
        }
    }

    /// Atomically swaps the knowledge extracted from one meeting's minutes for a fresh set.
    /// Only documents whose source is that meeting are replaced: notes, manual entries, imports
    /// and agent commits carry other source ids and are never touched. If anything fails, the
    /// transaction rolls back and the old documents stay.
    func replaceMeetingDocuments(
        meetingID: UUID, with results: [(document: KnowledgeDocument, chunks: [KnowledgeChunk])]
    ) throws {
        try dbQueue.write { db in
            try KnowledgeDocument
                .filter(Column("sourceMeetingID") == meetingID.uuidString)
                .filter(Column("sourceNoteID") == nil)
                .deleteAll(db)
            for (document, chunks) in results {
                var document = document
                document.id = nil
                try document.insert(db)
                let documentID = db.lastInsertedRowID
                for var chunk in chunks {
                    chunk.documentID = documentID
                    try chunk.insert(db)
                }
            }
        }
    }

    func deleteAll() throws {
        try dbQueue.write { db in
            try KnowledgeChunk.deleteAll(db)
            try KnowledgeDocument.deleteAll(db)
        }
    }
    
    func deleteDocument(id: Int64) throws {
        _ = try dbQueue.write { db in
            // Chunks are deleted automatically via ON DELETE CASCADE
            try KnowledgeDocument.deleteOne(db, key: id)
        }
    }
}
