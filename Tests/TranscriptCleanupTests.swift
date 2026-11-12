// Purpose: Tests for TranscriptCleanupService's structural guard — the check that rejects an LLM
//          cleanup which dropped, added or relabeled lines, so a misbehaving model can never
//          silently corrupt a transcript.
// Dependencies: Sources/App/Services/TranscriptCleanupService.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("TranscriptCleanup Structural Guard Tests")
struct TranscriptCleanupTests {

    private let original = [
        "[00:05] You: also ähm fangen wir an",
        "[00:09] Speaker 1: ja gerne",
    ]

    @Test("A cleanup that only edits wording is accepted")
    func testAcceptsWordingChanges() {
        let cleaned = """
            [00:05] You: Also, fangen wir an.
            [00:09] Speaker 1: Ja, gerne.
            """
        #expect(TranscriptCleanupService.preservesStructure(original: original, cleaned: cleaned))
    }

    @Test("A dropped line is rejected")
    func testRejectsDroppedLine() {
        let cleaned = "[00:05] You: Also, fangen wir an."
        #expect(!TranscriptCleanupService.preservesStructure(original: original, cleaned: cleaned))
    }

    @Test("An added line is rejected")
    func testRejectsAddedLine() {
        let cleaned = """
            [00:05] You: Also, fangen wir an.
            [00:09] Speaker 1: Ja, gerne.
            [00:12] Speaker 1: Noch ein erfundener Satz.
            """
        #expect(!TranscriptCleanupService.preservesStructure(original: original, cleaned: cleaned))
    }

    @Test("A changed timestamp is rejected")
    func testRejectsChangedTimestamp() {
        let cleaned = """
            [00:06] You: Also, fangen wir an.
            [00:09] Speaker 1: Ja, gerne.
            """
        #expect(!TranscriptCleanupService.preservesStructure(original: original, cleaned: cleaned))
    }

    @Test("A changed speaker label is rejected")
    func testRejectsChangedSpeaker() {
        let cleaned = """
            [00:05] You: Also, fangen wir an.
            [00:09] Speaker 2: Ja, gerne.
            """
        #expect(!TranscriptCleanupService.preservesStructure(original: original, cleaned: cleaned))
    }

    @Test("Plain transcripts without a speaker prefix are compared by line count")
    func testPrefixlessTranscript() {
        let plain = ["hallo welt", "zweite zeile"]
        #expect(
            TranscriptCleanupService.preservesStructure(
                original: plain, cleaned: "Hallo Welt.\nZweite Zeile."))
        #expect(
            !TranscriptCleanupService.preservesStructure(
                original: plain, cleaned: "Hallo Welt."))
    }

    @Test("Blank lines between turns are skipped and put back")
    func testBlankLinesRoundTrip() {
        let transcript = "\n[00:05] You: also ähm fangen wir an\n\n[00:09] Speaker 1: ja gerne\n"
        #expect(TranscriptCleanupService.textLines(of: transcript) == original)
        let cleaned = "[00:05] You: Also, fangen wir an.\n[00:09] Speaker 1: Ja, gerne."
        #expect(TranscriptCleanupService.restoringBlankLines(of: transcript, in: cleaned)
            == "\n[00:05] You: Also, fangen wir an.\n\n[00:09] Speaker 1: Ja, gerne.\n")
        // A count mismatch keeps the original untouched.
        #expect(TranscriptCleanupService.restoringBlankLines(of: transcript, in: "[00:05] You: x") == transcript)
    }
}

/// Opt-in: calls the real Claude Code CLI. Run with MM_CLAUDE_TESTS=1.
@Suite("TranscriptCleanup Claude Tests")
struct TranscriptCleanupClaudeTests {
    static let enabled = ProcessInfo.processInfo.environment["MM_CLAUDE_TESTS"] == "1" && ClaudeCodeService.locate() != nil

    @Test("Claude Sonnet cleans a transcript and keeps its structure", .enabled(if: enabled))
    func testClaudeCleanup() async throws {
        let transcript = """
            [00:05] You: also ähm fangen wir an mit dem thema mit der migration von von der datenbank
            [00:12] Speaker 1: ja genau ähm robin hat da schon was vorbereitet oder
            [00:15] You: ja ich hab das in minute mind äh dokumentiert
            """
        let claude = try #require(ClaudeCodeService.locate())
        let cleaned = try await TranscriptCleanupService().cleanUp(
            transcript, claude: claude, context: "Attendees: Robin\nProject: MinuteMind")
        print("[claude-cleanup]\n\(cleaned)")
        #expect(cleaned != transcript)
        #expect(TranscriptCleanupService.preservesStructure(original: transcript.components(separatedBy: "\n"), cleaned: cleaned))
    }
}
