// Purpose: Tests for TranscriptFormatting — pause-based utterance grouping, chronological
//          interleaving with overlap marking, and transcript rendering.
// Dependencies: Sources/App/Transcription/TranscriptFormatting.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("TranscriptFormatting Tests")
struct TranscriptFormattingTests {

    // MARK: - Grouping

    @Test("Words within the pause threshold stay in one utterance")
    func testSingleUtterance() {
        let words = [
            TimedWord(text: "hallo", start: 0.0, end: 0.4),
            TimedWord(text: "wie", start: 0.5, end: 0.8),
            TimedWord(text: "geht's", start: 0.9, end: 1.3),
        ]
        let result = TranscriptFormatting.groupIntoUtterances(
            words, speaker: "You", language: "de-DE")

        #expect(result.count == 1)
        #expect(result[0].text == "hallo wie geht's")
        #expect(result[0].start == 0.0)
        #expect(result[0].duration == 1.3)
    }

    @Test("A pause longer than the threshold splits utterances")
    func testPauseSplits() {
        let words = [
            TimedWord(text: "erster", start: 0.0, end: 0.5),
            TimedWord(text: "satz", start: 0.6, end: 1.0),
            // 2s gap > 0.8s threshold
            TimedWord(text: "zweiter", start: 3.0, end: 3.5),
            TimedWord(text: "satz", start: 3.6, end: 4.0),
        ]
        let result = TranscriptFormatting.groupIntoUtterances(
            words, speaker: "You", language: "de-DE")

        #expect(result.count == 2)
        #expect(result[0].text == "erster satz")
        #expect(result[1].text == "zweiter satz")
        #expect(result[1].start == 3.0)
    }

    @Test("Empty input produces no utterances")
    func testEmptyInput() {
        #expect(
            TranscriptFormatting.groupIntoUtterances([], speaker: "You", language: "de-DE").isEmpty)
    }

    // MARK: - Interleaving

    @Test("Utterances from both streams are ordered chronologically")
    func testChronologicalOrder() {
        let mic = [
            TranscriptUtterance(
                speaker: "You", text: "first", start: 0, duration: 1, language: "de-DE"),
            TranscriptUtterance(
                speaker: "You", text: "third", start: 4, duration: 1, language: "de-DE"),
        ]
        let system = [
            TranscriptUtterance(
                speaker: "Speaker 1", text: "second", start: 2, duration: 1, language: "de-DE")
        ]
        let result = TranscriptFormatting.interleave(mic: mic, system: system)

        #expect(result.map(\.text) == ["first", "second", "third"])
    }

    @Test("A different speaker starting before the previous ends is marked overlapping")
    func testOverlapMarking() {
        let mic = [
            TranscriptUtterance(
                speaker: "You", text: "long turn", start: 0, duration: 5, language: "de-DE")
        ]
        let system = [
            TranscriptUtterance(
                speaker: "Speaker 1", text: "interjection", start: 2, duration: 1, language: "de-DE")
        ]
        let result = TranscriptFormatting.interleave(mic: mic, system: system)

        #expect(result[0].text == "long turn")
        #expect(result[1].text == "[overlapping] interjection")
    }

    @Test("Sequential turns from different speakers are not marked overlapping")
    func testNoFalseOverlap() {
        let mic = [
            TranscriptUtterance(
                speaker: "You", text: "mine", start: 0, duration: 1, language: "de-DE")
        ]
        let system = [
            TranscriptUtterance(
                speaker: "Speaker 1", text: "yours", start: 2, duration: 1, language: "de-DE")
        ]
        let result = TranscriptFormatting.interleave(mic: mic, system: system)

        #expect(result[1].text == "yours")
    }

    // MARK: - Rendering

    @Test("Rendering produces timestamped speaker lines")
    func testRender() {
        let utterances = [
            TranscriptUtterance(
                speaker: "You", text: "hallo", start: 5, duration: 1, language: "de-DE"),
            TranscriptUtterance(
                speaker: "Speaker 1", text: "hi", start: 75, duration: 1, language: "de-DE"),
        ]
        let text = TranscriptFormatting.render(utterances, showLanguage: false)

        #expect(text == "[00:05] You: hallo\n\n[01:15] Speaker 1: hi")
    }

    @Test("Language flags are appended when requested")
    func testRenderWithLanguage() {
        let utterances = [
            TranscriptUtterance(
                speaker: "You", text: "hallo", start: 0, duration: 1, language: "de-DE")
        ]
        let text = TranscriptFormatting.render(utterances, showLanguage: true)

        #expect(text == "[00:00] You: hallo".replacingOccurrences(of: "You:", with: "You (🇩🇪):"))
    }

    // MARK: - assemble

    @Test("assemble splits local vs remote by label, keeping diarized labels intact")
    func testAssembleKeepsDiarizedLabels() {
        let utterances = [
            TranscriptUtterance(
                speaker: "Speaker 2", text: "remote", start: 2, duration: 1, language: "de-DE"),
            TranscriptUtterance(
                speaker: "You", text: "local", start: 0, duration: 1, language: "de-DE"),
        ]
        let text = TranscriptFormatting.assemble(utterances, showLanguage: false)

        #expect(text == "[00:00] You: local\n\n[00:02] Speaker 2: remote")
    }

    @Test("assemble on empty input returns an empty string")
    func testAssembleEmpty() {
        #expect(TranscriptFormatting.assemble([], showLanguage: false) == "")
    }
}
