// Purpose: HelpGuide, the user guide to MinuteMind as data: topics with Markdown bodies, lookup by
//          id or title, and a keyword search. One source for the Settings Help tab and for Claude,
//          which reads it over MCP (get_help) to answer "how does MinuteMind ..." questions.
// Dependencies: Sources/App/Help/HelpGuideContent.swift (the topics' text),
//               Sources/App/Help/HelpGuideTroubleshooting.swift (the troubleshooting topic)
// Used by: Sources/App/Views/HelpSettingsView.swift (Help tab),
//          Sources/App/Services/MCP/MCPHelpTools.swift (get_help),
//          Sources/App/Help/AppSettingsCatalog.swift (each setting names its help topic),
//          Tests/HelpGuideTests.swift
// Notes: The text is compiled into the app instead of shipped as Markdown resources, because the
//        app bundle built by Scripts/package_app.sh carries no SwiftPM resource bundles. Bodies are
//        written for users (what to click, where a setting lives), never in code terms: Claude
//        quotes them to people who have never seen the source.

import Foundation

struct HelpGuideTopic: Identifiable, Equatable, Sendable {
    /// Stable kebab-case id, used by get_help and by settings that point here.
    let id: String
    let title: String
    /// SF Symbol for the Help tab.
    let icon: String
    /// One line saying what the topic covers, shown in the topic index.
    let summary: String
    /// Markdown, `##` headings for sub-sections.
    let body: String
}

enum HelpGuide {
    static var topics: [HelpGuideTopic] { HelpGuideContent.topics + [HelpGuideTroubleshooting.topic] }

    /// A topic by id or (case-insensitive) title.
    static func topic(_ idOrTitle: String) -> HelpGuideTopic? {
        let wanted = idOrTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return topics.first { $0.id == wanted || $0.title.lowercased() == wanted }
    }

    struct SearchHit: Equatable {
        let topic: HelpGuideTopic
        /// The paragraphs of the body that contain the most query words, in body order.
        let excerpts: [String]
        let score: Int
    }

    /// Topics containing the query's words, best first. Each word counts once per paragraph, a
    /// word in the title or summary counts extra, so the topic about a thing outranks topics that
    /// merely mention it.
    static func search(_ query: String, limit: Int = 5) -> [SearchHit] {
        let words = searchWords(query)
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for topic in topics {
            let heading = (topic.title + " " + topic.summary).lowercased()
            var score = words.filter { heading.contains($0) }.count * 3
            var scored: [(index: Int, text: String, score: Int)] = []
            for (index, paragraph) in paragraphs(of: topic.body).enumerated() {
                let lower = paragraph.lowercased()
                let matched = words.filter { lower.contains($0) }.count
                guard matched > 0 else { continue }
                score += matched
                scored.append((index, paragraph, matched))
            }
            guard score > 0 else { continue }
            let excerpts = scored.sorted { $0.score > $1.score }.prefix(3).sorted { $0.index < $1.index }.map(\.text)
            hits.append(SearchHit(topic: topic, excerpts: excerpts, score: score))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Lowercased words of at least three letters; short words ("a", "to") match everywhere.
    static func searchWords(_ query: String) -> [String] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        return Array(NSOrderedSet(array: words)) as? [String] ?? words
    }

    /// Blank-line separated blocks of a Markdown body, headings kept with nothing else.
    static func paragraphs(of body: String) -> [String] {
        body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
