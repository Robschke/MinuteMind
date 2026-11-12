import Foundation

struct KnowledgeExtractionService {
    
    struct ExtractionResult {
        var document: KnowledgeDocument
        var chunks: [KnowledgeChunk]
    }

    /// Extract knowledge entries from meeting minutes text
    static func extract(
        from minutesText: String, meetingID: UUID, meetingTitle: String, projectID: UUID? = nil,
        date: Date
    ) -> [ExtractionResult]
    {
        var results: [ExtractionResult] = []

        // Find and extract the "Project Knowledge" section
        let lines = minutesText.components(separatedBy: .newlines)
        var isInKnowledgeSection = false
        var currentCategory = "General"
        var currentContent = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.localizedCaseInsensitiveContains("Project Knowledge")
                && (trimmed.hasPrefix("#") || trimmed.hasPrefix("##"))
            {
                isInKnowledgeSection = true
                continue
            }

            if isInKnowledgeSection {
                // Determine if this line is a header
                if trimmed.hasPrefix("#") {
                    // It's a header. Is it a main section or a sub-category?
                    if isMainSection(trimmed) {
                        // It's a different main section, so we stop the knowledge extraction
                        break
                    } else {
                        // It's a subsection header (e.g. ### Architecture or ## Architecture)
                        // Treat it as a category marker
                        if !currentContent.isEmpty {
                            if let result = processContent(
                                content: currentContent,
                                category: currentCategory,
                                meetingID: meetingID,
                                title: meetingTitle,
                                projectID: projectID,
                                date: date
                            ) {
                                results.append(result)
                            }
                            currentContent = ""
                        }
                        currentCategory = trimmed.trimmingCharacters(
                            in: CharacterSet(charactersIn: "# ")
                        ).trimmingCharacters(in: .whitespaces)
                        continue
                    }
                }

                if !trimmed.isEmpty {
                    currentContent += line + "\n"
                }
            }
        }

        // Save the last chunk
        if isInKnowledgeSection && !currentContent.isEmpty {
            if let result = processContent(
                content: currentContent,
                category: currentCategory,
                meetingID: meetingID,
                title: meetingTitle,
                projectID: projectID,
                date: date
            ) {
                results.append(result)
            }
        }

        return results
    }

    private static func isMainSection(_ line: String) -> Bool {
        let mainSections = [
            "Summary", "Decisions Made", "Action Items", "Open Questions", "Detailed Summary",
        ]
        let lowercaseLine = line.lowercased()
        if lowercaseLine.contains("project knowledge") { return false }

        return mainSections.contains { section in
            lowercaseLine.contains(section.lowercased())
        }
    }
    
    private static func processContent(
        content: String,
        category: String,
        meetingID: UUID,
        title: String,
        projectID: UUID?,
        date: Date
    ) -> ExtractionResult? {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return nil }

        let generatedTitle = "\(category) - \(title)"

        // 1. Create the Document
        // Note: ID is nil, will be set when saved to DB
        let document = KnowledgeDocument(
            fullContent: trimmedContent,
            title: generatedTitle,
            category: category,
            sourceMeetingID: meetingID,
            sourceMeetingTitle: title,
            projectID: projectID,
            date: date
        )

        // 2. Create Chunks
        let chunks = chunkContent(trimmedContent)

        return ExtractionResult(document: document, chunks: chunks)
    }

    /// Chunk text into pieces of roughly 500 tokens (using character approx ~2000 chars)
    /// with ~100 char overlap.
    static func chunkContent(_ text: String) -> [KnowledgeChunk] {
        let maxChunkSize = 2000
        let overlap = 100
        var chunks: [KnowledgeChunk] = []

        let count = text.count
        if count <= maxChunkSize {
            // Single chunk
            return [
                KnowledgeChunk(
                    documentID: 0,  // Placeholder, updated on save
                    content: text,
                    chunkIndex: 0,
                    startOffset: 0,
                    endOffset: count
                )
            ]
        }

        var currentStart = 0
        var chunkIndex = 0

        while currentStart < count {
            let remaining = count - currentStart
            var chunkSize = min(maxChunkSize, remaining)

            // Try to find a sentence break near the desired end
            if currentStart + chunkSize < count {
                let rangeChecksStart = text.index(
                    text.startIndex, offsetBy: max(0, currentStart + chunkSize - 200))
                let rangeChecksEnd = text.index(
                    text.startIndex, offsetBy: min(count, currentStart + chunkSize))
                let rangeToCheck = rangeChecksStart..<rangeChecksEnd

                if let range = text.range(of: ". ", options: .backwards, range: rangeToCheck) {
                    // Split at the period
                    chunkSize = text.distance(
                        from: text.index(text.startIndex, offsetBy: currentStart),
                        to: range.upperBound)
                }
            }

            let startIdx = text.index(text.startIndex, offsetBy: currentStart)
            let endIdx = text.index(startIdx, offsetBy: chunkSize)
            let chunkText = String(text[startIdx..<endIdx])

            chunks.append(
                KnowledgeChunk(
                    documentID: 0,
                    content: chunkText.trimmingCharacters(in: .whitespacesAndNewlines),
                    chunkIndex: chunkIndex,
                    startOffset: currentStart,
                    endOffset: currentStart + chunkSize
                ))

            chunkIndex += 1

            // Move forward, backing up by overlap if not at end
            if currentStart + chunkSize >= count {
                break
            }
            currentStart += (chunkSize - overlap)
        }

        return chunks
    }
}
