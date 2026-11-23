// Purpose: Tests for SpeakerAssignment — mapping diarization turns onto transcribed utterances
//          and labeling them "Speaker N" in first-appearance order.
// Dependencies: Sources/App/Transcription/SpeakerDiarization.swift

import Foundation
import Testing
@testable import MinuteMindApp

@Suite("SpeakerAssignment Tests")
struct SpeakerAssignmentTests {

    private let turns: [SpeakerTurn] = [
        SpeakerTurn(start: 0, end: 5, speaker: 0),
        SpeakerTurn(start: 5, end: 10, speaker: 1),
        SpeakerTurn(start: 10, end: 15, speaker: 0),
        SpeakerTurn(start: 15, end: 20, speaker: 2),
    ]

    @Test("Utterance is assigned the speaker with the greatest overlap")
    func testMaxOverlapWins() {
        // Utterance 4–9s overlaps speaker 0 for 1s and speaker 1 for 4s → speaker 1.
        let idx = SpeakerAssignment.speakerIndex(utteranceStart: 4, duration: 5, turns: turns)
        #expect(idx == 1)
    }

    @Test("Utterance fully inside a single turn maps to that speaker")
    func testInsideSingleTurn() {
        let idx = SpeakerAssignment.speakerIndex(utteranceStart: 11, duration: 2, turns: turns)
        #expect(idx == 0)
    }

    @Test("Utterance overlapping no turn returns nil")
    func testNoOverlap() {
        let idx = SpeakerAssignment.speakerIndex(utteranceStart: 25, duration: 2, turns: turns)
        #expect(idx == nil)
    }

    @Test("Labels are numbered in first-appearance order, stable per cluster")
    func testFirstAppearanceLabeling() {
        // Chronological utterances hitting clusters 0, 1, 0, 2 → Speaker 1, 2, 1, 3.
        let ranges: [(start: TimeInterval, duration: TimeInterval)] = [
            (start: 1, duration: 2),   // cluster 0
            (start: 6, duration: 2),   // cluster 1
            (start: 11, duration: 2),  // cluster 0 again
            (start: 16, duration: 2),  // cluster 2
        ]
        let labels = SpeakerAssignment.labelUtterances(utteranceRanges: ranges, turns: turns)
        #expect(labels == ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 3"])
    }

    @Test("Utterances with no overlapping turn get the fallback label")
    func testFallbackLabel() {
        let ranges: [(start: TimeInterval, duration: TimeInterval)] = [
            (start: 1, duration: 2),   // cluster 0
            (start: 30, duration: 2),  // no turn
        ]
        let labels = SpeakerAssignment.labelUtterances(
            utteranceRanges: ranges, turns: turns, fallbackLabel: "Other")
        #expect(labels == ["Speaker 1", "Other"])
    }
}

@Suite("SpeakerLabeler Tests")
struct SpeakerLabelerTests {

    private let micTurns = [
        SpeakerTurn(start: 0, end: 5, speaker: 0),
        SpeakerTurn(start: 5, end: 10, speaker: 1),
    ]
    private let systemTurns = [
        SpeakerTurn(start: 0, end: 5, speaker: 0),
        SpeakerTurn(start: 5, end: 10, speaker: 1),
    ]

    @Test("Numbering continues across channels so clusters never collide")
    func testSharedNumberingAcrossChannels() {
        var labeler = SpeakerLabeler()

        let mic = labeler.labels(
            forUtteranceRanges: [(start: 1, duration: 2), (start: 6, duration: 2)],
            result: DiarizationResult(turns: micTurns), channel: "mic", fallbackLabel: "You")
        let system = labeler.labels(
            forUtteranceRanges: [(start: 1, duration: 2), (start: 6, duration: 2)],
            result: DiarizationResult(turns: systemTurns), channel: "system", fallbackLabel: "Other")

        // Same cluster indices on both channels must still yield four distinct speakers.
        #expect(mic == ["Speaker 1", "Speaker 2"])
        #expect(system == ["Speaker 3", "Speaker 4"])
        #expect(labeler.speakerCount == 4)
    }

    @Test("A cluster seen again keeps its number")
    func testStableNumbering() {
        var labeler = SpeakerLabeler()
        let labels = labeler.labels(
            forUtteranceRanges: [
                (start: 1, duration: 2), (start: 6, duration: 2), (start: 3, duration: 1),
            ],
            result: DiarizationResult(turns: micTurns), channel: "mic", fallbackLabel: "You")

        #expect(labels == ["Speaker 1", "Speaker 2", "Speaker 1"])
        #expect(labeler.speakerCount == 2)
    }

    @Test("Utterances overlapping no turn get the fallback label and no number")
    func testFallbackNotNumbered() {
        var labeler = SpeakerLabeler()
        let labels = labeler.labels(
            forUtteranceRanges: [(start: 50, duration: 2)],
            result: DiarizationResult(turns: micTurns), channel: "mic", fallbackLabel: "You")

        #expect(labels == ["You"])
        #expect(labeler.speakerCount == 0)
    }

    // MARK: - Word-level assignment

    private func timed(_ text: String, from start: TimeInterval, step: TimeInterval = 0.4) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let wordStart = start + Double(index) * step
            return TimedWord(text: String(word), start: wordStart, end: wordStart + step - 0.1)
        }
    }

    @Test("Two speakers answering without a pause become two utterances")
    func speakerChangeSplitsUtterance() {
        // One run of speech, 0.1 s between all words: A talks 0 to 2 s, B from 2 s on.
        let words = timed("Kommst du morgen mit? Ja klar, ich bin dabei.", from: 0)
        let result = DiarizationResult(turns: [
            SpeakerTurn(start: 0, end: 1.6, speaker: 0),
            SpeakerTurn(start: 1.6, end: 4, speaker: 1),
        ])
        var labeler = SpeakerLabeler()
        let utterances = labeler.utterances(
            from: words, result: result, channel: "system", fallbackLabel: "Other", language: "auto")

        #expect(utterances.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(utterances.map(\.text) == ["Kommst du morgen mit?", "Ja klar, ich bin dabei."])
    }

    @Test("A speaker change that falls mid-sentence moves to the sentence end")
    func boundarySnapsToSentenceEnd() {
        // The turn boundary sits one word late: "Ja" still overlaps speaker 0.
        let words = timed("Kommst du morgen mit? Ja klar, ich bin dabei.", from: 0)
        let turns = [
            SpeakerTurn(start: 0, end: 2.0, speaker: 0),
            SpeakerTurn(start: 2.0, end: 4, speaker: 1),
        ]
        let speakers = SpeakerAssignment.wordSpeakers(words: words, turns: turns)
        #expect(speakers == [0, 0, 0, 0, 1, 1, 1, 1, 1])
    }

    @Test("A single word disagreeing with both neighbours follows them")
    func blipIsSmoothed() {
        let words = timed("das ist ein ganz langer Satz ohne Ende", from: 0)
        let turns = [
            SpeakerTurn(start: 0, end: 1.2, speaker: 0),
            SpeakerTurn(start: 1.2, end: 1.5, speaker: 1),
            SpeakerTurn(start: 1.5, end: 4, speaker: 0),
        ]
        let speakers = SpeakerAssignment.wordSpeakers(words: words, turns: turns)
        #expect(Set(speakers) == [0])
    }

    @Test("Words no turn covers take their neighbour's speaker")
    func uncoveredWordsAreFilled() {
        let words = timed("eins zwei drei vier", from: 0)
        let turns = [SpeakerTurn(start: 0.8, end: 1.6, speaker: 3)]
        #expect(SpeakerAssignment.wordSpeakers(words: words, turns: turns) == [3, 3, 3, 3])
    }

    @Test("Without any turn every word keeps the fallback label")
    func noTurnsFallBack() {
        let words = timed("eins zwei", from: 0)
        var labeler = SpeakerLabeler()
        let utterances = labeler.utterances(
            from: words, result: .empty, channel: "system", fallbackLabel: "Other", language: "auto")
        #expect(utterances.map(\.speaker) == ["Other"])
        #expect(utterances.map(\.text) == ["eins zwei"])
    }

    @Test("A one-word fragment inside a sentence joins the speaker of the rest")
    func fragmentIsMerged() {
        let words = timed("Das stimmt. Ich meine, man könnte es versuchen.", from: 0)
        // "Ich" is heard as a third voice between the two real speakers.
        let turns = [
            SpeakerTurn(start: 0, end: 0.75, speaker: 0),
            SpeakerTurn(start: 0.75, end: 1.15, speaker: 2),
            SpeakerTurn(start: 1.15, end: 4, speaker: 1),
        ]
        #expect(SpeakerAssignment.wordSpeakers(words: words, turns: turns) == [0, 0, 1, 1, 1, 1, 1, 1])
    }

    @Test("A short remark that is a sentence of its own keeps its speaker")
    func shortRemarkIsKept() {
        let words = timed("Das machen wir so. Genau. Dann bis morgen.", from: 0)
        let turns = [
            SpeakerTurn(start: 0, end: 1.55, speaker: 0),
            SpeakerTurn(start: 1.55, end: 1.95, speaker: 1),
            SpeakerTurn(start: 1.95, end: 4, speaker: 0),
        ]
        // The blip pass would fold "Genau." into speaker 0; a remark between two sentences stays.
        #expect(SpeakerAssignment.wordSpeakers(words: words, turns: turns) == [0, 0, 0, 0, 1, 0, 0, 0])
    }
}
