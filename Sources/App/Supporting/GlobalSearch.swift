// Purpose: The Cmd+K global search without UI: what a result is and opens (GlobalSearchResult,
//          GlobalSearchTarget), the searchable entries the app hands over (GlobalSearchEntry for
//          names, GlobalSearchMeeting for meetings with their full text), the matching and
//          ranking, and the text excerpt shown under a full-text hit.
// Dependencies: Sources/App/Supporting/AppNavigation.swift (NavigationPlace),
//               Sources/App/Views/MeetingMinutesSettingsView.swift (Settings tabs)
// Used by: Sources/App/ViewModels/AppViewModel+GlobalSearch.swift (entries, meetings, knowledge),
//          Sources/App/Views/GlobalSearchView.swift (runs the search, shows the results),
//          Tests/GlobalSearchTests.swift
// Notes: Pure value types, so the full-text scan over transcripts and summaries can run off the
//        main actor. Meetings are searched by a plain case and diacritic insensitive scan of the
//        texts the app already holds (transcripts in memory, summaries read once when the search
//        opens), the way All Transcripts filters; there is no separate index for them. Knowledge
//        comes from the existing FTS index (KnowledgeStore.searchChunks). Names match anywhere in
//        the name; a match at the start of the name or of a word ranks first. One row per
//        meeting, found in the title first, then in the transcript, then in the summary, and the
//        row opens what it was found in.

import Foundation

/// What a search result opens.
enum GlobalSearchTarget: Hashable, Sendable {
    case place(NavigationPlace)
    case settings(MeetingMinutesSettingsView.Tab)
    /// A main menu item, found again by its position (indices from the main menu down) and
    /// checked against its title before it runs.
    case menuItem(path: [Int], title: String)
    case project(UUID)
    /// A Claude session of a workspace or the Claude (General) window.
    case agentSession(UUID)
    /// A meeting's Summary window.
    case summary(sessionID: UUID)
    /// A meeting's transcript, filtered to the lines containing `query` (all lines when empty).
    case transcript(sessionID: UUID, query: String)
    /// A knowledge file of a workspace repo, opened in that project's editor.
    case knowledgeFile(repoID: UUID, relativePath: String)
}

/// The groups results are shown in, in this order.
enum GlobalSearchSection: Int, CaseIterable, Comparable, Sendable {
    case places, projects, agentSessions, meetings, knowledge, menu

    var title: String {
        switch self {
        case .places: "Go to"
        case .projects: "Projects"
        case .agentSessions: "Claude Sessions"
        case .meetings: "Meetings"
        case .knowledge: "Knowledge"
        case .menu: "Menu"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct GlobalSearchResult: Identifiable, Hashable, Sendable {
    let section: GlobalSearchSection
    let title: String
    /// Where it is (menu path, project, date) or, for full-text hits, the matching text.
    let subtitle: String
    /// SF Symbol shown in front of the row.
    let icon: String
    let target: GlobalSearchTarget

    var id: GlobalSearchTarget { target }
}

/// Something found by its name: a page, a Settings page, a menu item, a project, a Claude session.
struct GlobalSearchEntry: Sendable {
    let section: GlobalSearchSection
    let title: String
    let subtitle: String
    let icon: String
    let target: GlobalSearchTarget
}

/// A meeting (or quick recording) with the texts its full-text search covers.
struct GlobalSearchMeeting: Sendable {
    let id: UUID
    let title: String
    /// Date and project, shown when the title matched.
    let subtitle: String
    let createdAt: Date
    let transcript: String
    /// The summary's Markdown; nil while it is not read yet or the meeting has none.
    var summary: String?
    let hasSummary: Bool
}

enum GlobalSearch {
    /// Shortest query searched in full text (transcripts, summaries, knowledge).
    static let fullTextMinimumLength = 2
    /// Most rows per name section (pages, projects, sessions, menu).
    static let entryLimit = 8
    /// Most meeting rows.
    static let meetingLimit = 20
    /// Longest excerpt under a full-text hit, in characters.
    static let snippetLength = 140

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The entries whose title contains `query`, best first, at most `entryLimit` per section.
    static func matchEntries(_ query: String, in entries: [GlobalSearchEntry]) -> [GlobalSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let ranked = entries.enumerated().compactMap { offset, entry -> (rank: Int, offset: Int, entry: GlobalSearchEntry)? in
            guard let rank = nameRank(of: entry.title, query: query) else { return nil }
            return (rank, offset, entry)
        }
        .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }

        var perSection: [GlobalSearchSection: Int] = [:]
        var results: [GlobalSearchResult] = []
        for item in ranked {
            let count = perSection[item.entry.section, default: 0]
            guard count < entryLimit else { continue }
            perSection[item.entry.section] = count + 1
            let entry = item.entry
            results.append(GlobalSearchResult(
                section: entry.section, title: entry.title, subtitle: entry.subtitle, icon: entry.icon,
                target: entry.target))
        }
        return results
    }

    /// 0: the name starts with the query, 1: a word does, 2: it is inside a word; nil: no match.
    static func nameRank(of name: String, query: String) -> Int? {
        guard let range = name.range(of: query, options: options) else { return nil }
        if range.lowerBound == name.startIndex { return 0 }
        if name.range(of: query, options: options.union(.anchored), range: wordStarts(in: name, from: range.lowerBound)) != nil {
            return 1
        }
        return 2
    }

    /// From the first word start at or after `index` to the end (a word start: a letter or digit
    /// after anything else).
    private static func wordStarts(in name: String, from index: String.Index) -> Range<String.Index> {
        var cursor = index
        while cursor < name.endIndex {
            if cursor > name.startIndex {
                let before = name[name.index(before: cursor)]
                if !(before.isLetter || before.isNumber) { return cursor..<name.endIndex }
            }
            cursor = name.index(after: cursor)
        }
        return name.endIndex..<name.endIndex
    }

    /// The meetings mentioning `query` in their title, transcript or summary: title matches
    /// first, then the newest first, at most `meetingLimit`.
    static func matchMeetings(_ query: String, in meetings: [GlobalSearchMeeting]) -> [GlobalSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= fullTextMinimumLength else { return [] }
        var titled: [(Date, GlobalSearchResult)] = []
        var mentioned: [(Date, GlobalSearchResult)] = []
        for meeting in meetings {
            let icon = "waveform"
            if meeting.title.range(of: query, options: options) != nil {
                let target: GlobalSearchTarget = meeting.hasSummary
                    ? .summary(sessionID: meeting.id) : .transcript(sessionID: meeting.id, query: "")
                titled.append((meeting.createdAt, GlobalSearchResult(
                    section: .meetings, title: meeting.title, subtitle: meeting.subtitle, icon: icon, target: target)))
            } else if let range = meeting.transcript.range(of: query, options: options) {
                mentioned.append((meeting.createdAt, GlobalSearchResult(
                    section: .meetings, title: meeting.title,
                    subtitle: snippet(in: meeting.transcript, around: range), icon: icon,
                    target: .transcript(sessionID: meeting.id, query: query))))
            } else if let summary = meeting.summary, let range = summary.range(of: query, options: options) {
                mentioned.append((meeting.createdAt, GlobalSearchResult(
                    section: .meetings, title: meeting.title, subtitle: snippet(in: summary, around: range),
                    icon: icon, target: .summary(sessionID: meeting.id))))
            }
        }
        let newestFirst: ((Date, GlobalSearchResult), (Date, GlobalSearchResult)) -> Bool = { $0.0 > $1.0 }
        return Array((titled.sorted(by: newestFirst) + mentioned.sorted(by: newestFirst)).map(\.1).prefix(meetingLimit))
    }

    /// An excerpt for `text` around the first word of `query` it contains, else its start.
    static func snippet(in text: String, matching query: String) -> String {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        for word in words {
            if let range = text.range(of: word, options: options) { return snippet(in: text, around: range) }
        }
        return snippet(in: text, around: text.startIndex..<text.startIndex)
    }

    /// The line holding `range`, cut to `snippetLength` around it with an ellipsis where cut, its
    /// Markdown list and heading marks dropped.
    static func snippet(in text: String, around range: Range<String.Index>) -> String {
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        var start = lineStart
        var end = lineEnd
        if text.distance(from: start, to: end) > snippetLength {
            // Keep about a third of the excerpt before the match.
            let lead = snippetLength / 3
            start = text.index(range.lowerBound, offsetBy: -lead, limitedBy: lineStart) ?? lineStart
            end = text.index(start, offsetBy: snippetLength, limitedBy: lineEnd) ?? lineEnd
        }
        var excerpt = text[start..<end].trimmingCharacters(in: .whitespaces)
        if start == lineStart {
            while let first = excerpt.first, first == "#" || first == "-" || first == "*" || first == ">" {
                excerpt = String(excerpt.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        if start > lineStart { excerpt = "\u{2026}" + excerpt }
        if end < lineEnd { excerpt += "\u{2026}" }
        return excerpt
    }

    /// Results grouped by section in the sections' order, keeping their order inside a section.
    static func grouped(_ results: [GlobalSearchResult]) -> [(section: GlobalSearchSection, results: [GlobalSearchResult])] {
        GlobalSearchSection.allCases.compactMap { section in
            let inSection = results.filter { $0.section == section }
            return inSection.isEmpty ? nil : (section, inSection)
        }
    }
}
