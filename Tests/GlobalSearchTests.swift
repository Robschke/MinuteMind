// Purpose: Tests for the Cmd+K global search's matching: name ranking and limits, meetings found by
//          title, transcript or summary with the right target and order, excerpts and grouping.
// Dependencies: Sources/App/Supporting/GlobalSearch.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("GlobalSearch Tests")
struct GlobalSearchTests {
    private func entry(_ title: String, _ section: GlobalSearchSection = .places) -> GlobalSearchEntry {
        GlobalSearchEntry(section: section, title: title, subtitle: "", icon: "circle", target: .project(UUID()))
    }

    private func meeting(
        _ title: String, transcript: String = "", summary: String? = nil, daysAgo: Double = 0
    ) -> GlobalSearchMeeting {
        GlobalSearchMeeting(
            id: UUID(), title: title, subtitle: "", createdAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            transcript: transcript, summary: summary, hasSummary: summary != nil)
    }

    // MARK: - Names

    @Test func nameRankPrefersStartThenWordThenInside() {
        #expect(GlobalSearch.nameRank(of: "Calendar", query: "cal") == 0)
        #expect(GlobalSearch.nameRank(of: "All Tasks", query: "tas") == 1)
        #expect(GlobalSearch.nameRank(of: "Clipboard", query: "board") == 2)
        #expect(GlobalSearch.nameRank(of: "Inbox", query: "zz") == nil)
    }

    @Test func matchingIgnoresCaseAndAccents() {
        #expect(GlobalSearch.nameRank(of: "Café Relaunch", query: "cafe") == 0)
    }

    @Test func entriesAreRankedAndCappedPerSection() {
        let entries = [entry("Clipboard"), entry("Calendar")]
            + (0..<12).map { entry("Board \($0)", .menu) }
        let results = GlobalSearch.matchEntries("board", in: entries)
        #expect(results.filter { $0.section == .menu }.count == GlobalSearch.entryLimit)
        // A name starting with the query comes before one containing it.
        #expect(results.first?.title == "Board 0")
        #expect(results.contains { $0.title == "Clipboard" })
        #expect(!results.contains { $0.title == "Calendar" })
    }

    @Test func emptyQueryFindsNothing() {
        #expect(GlobalSearch.matchEntries("  ", in: [entry("Home")]).isEmpty)
        #expect(GlobalSearch.matchMeetings("x", in: [meeting("x")]).isEmpty)
    }

    // MARK: - Meetings

    @Test func transcriptHitOpensTheTranscriptFilteredToTheQuery() throws {
        let standup = meeting("Standup", transcript: "[00:10] Anna: hello\n[00:20] Ben: the potatoes are late\n")
        let result = try #require(GlobalSearch.matchMeetings("Potatoes", in: [standup]).first)
        #expect(result.target == .transcript(sessionID: standup.id, query: "Potatoes"))
        #expect(result.subtitle == "[00:20] Ben: the potatoes are late")
    }

    @Test func summaryHitOpensTheSummary() throws {
        let review = meeting("Review", transcript: "nothing here", summary: "# Decisions\n- Ship the potatoes on Friday")
        let result = try #require(GlobalSearch.matchMeetings("potatoes", in: [review]).first)
        #expect(result.target == .summary(sessionID: review.id))
        #expect(result.subtitle == "Ship the potatoes on Friday")
    }

    @Test func titleHitOpensSummaryOrElseTheWholeTranscript() {
        let withSummary = meeting("Potato planning", summary: "text")
        let without = meeting("Potato sync")
        let results = GlobalSearch.matchMeetings("potato", in: [withSummary, without])
        #expect(results.map(\.target).contains(.summary(sessionID: withSummary.id)))
        #expect(results.map(\.target).contains(.transcript(sessionID: without.id, query: "")))
    }

    @Test func titleHitsComeFirstThenNewestFirst() {
        let old = meeting("Weekly", transcript: "about potatoes", daysAgo: 5)
        let recent = meeting("Daily", transcript: "about potatoes", daysAgo: 1)
        let titled = meeting("Potatoes", daysAgo: 30)
        let results = GlobalSearch.matchMeetings("potatoes", in: [old, recent, titled])
        #expect(results.map(\.title) == ["Potatoes", "Daily", "Weekly"])
    }

    @Test func meetingsAreCapped() {
        let many = (0..<30).map { meeting("Meeting \($0)", transcript: "potatoes") }
        #expect(GlobalSearch.matchMeetings("potatoes", in: many).count == GlobalSearch.meetingLimit)
    }

    // MARK: - Excerpts and groups

    @Test func longLinesAreCutAroundTheMatch() {
        let text = String(repeating: "a", count: 300) + " potatoes " + String(repeating: "b", count: 300)
        let range = text.range(of: "potatoes")!
        let snippet = GlobalSearch.snippet(in: text, around: range)
        #expect(snippet.contains("potatoes"))
        #expect(snippet.hasPrefix("\u{2026}"))
        #expect(snippet.hasSuffix("\u{2026}"))
        #expect(snippet.count <= GlobalSearch.snippetLength + 2)
    }

    @Test func snippetForAQueryUsesItsFirstFoundWord() {
        #expect(GlobalSearch.snippet(in: "one\ntwo potatoes\nthree", matching: "missing potatoes") == "two potatoes")
    }

    @Test func groupsFollowTheSectionOrder() {
        let results = [
            GlobalSearchResult(section: .menu, title: "m", subtitle: "", icon: "", target: .project(UUID())),
            GlobalSearchResult(section: .places, title: "p", subtitle: "", icon: "", target: .project(UUID())),
            GlobalSearchResult(section: .meetings, title: "x", subtitle: "", icon: "", target: .project(UUID())),
        ]
        #expect(GlobalSearch.grouped(results).map(\.section) == [.places, .meetings, .menu])
    }
}
