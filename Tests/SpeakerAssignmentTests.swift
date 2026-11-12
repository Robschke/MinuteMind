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
}
