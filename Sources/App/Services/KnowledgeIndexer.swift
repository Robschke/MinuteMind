// Purpose: KnowledgeIndexer, keeps the SQLite knowledge base in step with the knowledge/*.md files
//          of the workspace repos, so search (MCP search_knowledge_base) finds
//          what the knowledge agent and the user wrote. The files are the source of truth; the
//          database is only an index of them.
// Dependencies: Sources/App/Store/KnowledgeStore.swift (documents, chunks, FTS),
//               Sources/App/Services/KnowledgeExtractionService.swift (chunkContent),
//               CryptoKit (stable document ids)
// RBAC: None.
// Dependents: Sources/App/ViewModels/AppViewModel.swift (after every curation, at launch)
// Notes: One document per file. Its sourceMeetingID is derived from repo + path, so a file keeps
//        its document across reindexes, and sourceMeetingTitle reads "workspace:<repo id>/<path>"
//        so indexed files are told apart from notes (which stay database-only). Unchanged files
//        are skipped. Search is keyword search (FTS5); no embeddings are computed. Files of the
//        General workspace are indexed without a project (global knowledge), as before.
//        A Shared Project's private layer (private/knowledge/) is indexed too, under its own paths,
//        so local search covers both layers.

import CryptoKit
import Foundation

@MainActor
enum KnowledgeIndexer {
    static let sourcePrefix = "workspace:"

    /// Stable id for a knowledge file: the same repo and path always give the same UUID.
    static func documentID(repoID: UUID, relativePath: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(repoID.uuidString)/\(relativePath)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version-5 style, name based
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: uuid)
    }

    static func source(repoID: UUID, relativePath: String) -> String {
        "\(sourcePrefix)\(repoID.uuidString)/\(relativePath)"
    }

    /// Repo id and path from a document's source, or nil for documents that are not files.
    static func file(fromSource source: String) -> (repoID: UUID, relativePath: String)? {
        guard source.hasPrefix(sourcePrefix) else { return nil }
        let rest = source.dropFirst(sourcePrefix.count)
        guard let slash = rest.firstIndex(of: "/"), let id = UUID(uuidString: String(rest[..<slash])) else { return nil }
        return (id, String(rest[rest.index(after: slash)...]))
    }

    /// The first `# Heading`, else the file name.
    static func title(of markdown: String, fallback: String) -> String {
        for line in markdown.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") { return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return fallback
    }

    /// Brings the index for one repo in line with its knowledge files: new and changed files are
    /// (re)indexed, documents of deleted files removed. `projectID` is nil for General.
    static func index(
        repoID: UUID, repo: URL, files: [URL], projectID: UUID?, store: KnowledgeStore
    ) async {
        let repoPrefix = source(repoID: repoID, relativePath: "")
        let existing = ((try? store.fetchAllDocuments()) ?? []).filter { $0.sourceMeetingTitle.hasPrefix(repoPrefix) }
        var current: Set<UUID> = []
        // Symlinks resolved on both sides (a temporary folder can be reached as /var or /private/var).
        let base = repo.resolvingSymlinksInPath().path + "/"

        for file in files {
            // knowledge/<file> or private/knowledge/<file>: the path decides the document id.
            let path = file.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : "knowledge/" + file.lastPathComponent
            let id = documentID(repoID: repoID, relativePath: relative)
            guard let content = try? String(contentsOf: file, encoding: .utf8),
                  KnowledgeCurator.hasContent(content) else { continue }
            current.insert(id)
            if let old = existing.first(where: { $0.sourceMeetingID == id }),
               old.fullContent == content, old.projectID == projectID { continue }

            let stem = file.deletingPathExtension().lastPathComponent
            let document = KnowledgeDocument(
                fullContent: content,
                title: title(of: content, fallback: stem),
                category: stem.replacingOccurrences(of: "-", with: " ").capitalized,
                sourceMeetingID: id,
                sourceMeetingTitle: source(repoID: repoID, relativePath: relative),
                projectID: projectID,
                date: (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
            let chunks = KnowledgeExtractionService.chunkContent(content)
            try? store.replaceMeetingDocuments(meetingID: id, with: [(document, chunks)])
        }

        for stale in existing where !current.contains(stale.sourceMeetingID) {
            if let docID = stale.id { try? store.deleteDocument(id: docID) }
        }
    }
}
