// Purpose: Tests for TranscriptDocument — turning a rendered transcript back into structured lines
//          for the in-app reader. A parser that silently drops a line would hide content the user
//          recorded, so the round-trip guarantees are checked explicitly.
// Dependencies: Sources/App/Transcription/TranscriptDocument.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("TranscriptDocument Tests")
struct TranscriptDocumentTests {

    @Test("A spoken line splits into timestamp, speaker and text")
    func testParsesSpokenLine() throws {
        let lines = TranscriptDocument.parse("[01:04] Anna: Wir sollten die KPIs klären.")
        let line = try #require(lines.first)

        #expect(lines.count == 1)
        #expect(line.timestamp == "01:04")
        #expect(line.startSeconds == 64)
        #expect(line.speaker == "Anna")
        #expect(line.text == "Wir sollten die KPIs klären.")
        #expect(line.languageFlag == nil)
        #expect(line.isSpoken)
    }

    @Test("A language flag between speaker and colon is captured, not left in the name")
    func testParsesLanguageFlag() throws {
        let line = try #require(TranscriptDocument.parse("[00:05] Speaker 1 (🇩🇪): Guten Morgen.").first)

        #expect(line.speaker == "Speaker 1")
        #expect(line.languageFlag == "🇩🇪")
        #expect(line.text == "Guten Morgen.")
    }

    @Test("A colon inside the spoken text does not split the speaker")
    func testColonInText() throws {
        let line = try #require(TranscriptDocument.parse("[02:00] Robin: Note: this matters.").first)

        #expect(line.speaker == "Robin")
        #expect(line.text == "Note: this matters.")
    }

    @Test("Lines without a speaker prefix survive as plain text")
    func testKeepsUnparseableLines() {
        let lines = TranscriptDocument.parse("A heading someone typed\n[00:10] Anna: Hi.")

        #expect(lines.count == 2)
        #expect(lines[0].speaker == nil)
        #expect(lines[0].text == "A heading someone typed")
        #expect(!lines[0].isSpoken)
        #expect(lines[1].speaker == "Anna")
    }

    @Test("Blank lines are dropped but nothing else is")
    func testDropsOnlyBlankLines() {
        let lines = TranscriptDocument.parse("[00:01] A: one\n\n   \n[00:02] B: two")

        #expect(lines.count == 2)
        #expect(lines.map(\.text) == ["one", "two"])
    }

    @Test("Hour-long recordings keep their timestamps")
    func testHourTimestamps() throws {
        let line = try #require(TranscriptDocument.parse("[1:02:03] Anna: Still going.").first)

        #expect(line.timestamp == "1:02:03")
        #expect(line.startSeconds == 3723)
    }

    @Test("A non-numeric timestamp yields no seek target but keeps the line")
    func testNonNumericTimestamp() throws {
        let line = try #require(TranscriptDocument.parse("[later] Anna: Hi.").first)

        #expect(line.speaker == "Anna")
        #expect(line.startSeconds == nil)
    }

    @Test("Speakers are listed in order of first appearance, without duplicates")
    func testSpeakerOrder() {
        let lines = TranscriptDocument.parse(
            """
            [00:01] Robin: one
            [00:05] Anna: two
            [00:09] Robin: three
            """)

        #expect(TranscriptDocument.speakers(in: lines) == ["Robin", "Anna"])
    }

    @Test("Word count covers every line, spoken or not")
    func testWordCount() {
        let lines = TranscriptDocument.parse("[00:01] A: one two three\nplain line here")
        #expect(TranscriptDocument.wordCount(lines) == 6)
    }

    @Test("An empty transcript parses to nothing rather than failing")
    func testEmptyTranscript() {
        #expect(TranscriptDocument.parse("").isEmpty)
        #expect(TranscriptDocument.parse("\n\n  \n").isEmpty)
    }
}
