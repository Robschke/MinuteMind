// Purpose: Tests for ProperNounCorrection — fuzzy correction of misspelled proper nouns against
//          known context terms, and the guardrails that keep it from corrupting correct text.
// Dependencies: Sources/App/Transcription/ProperNounCorrection.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("ProperNounCorrection Tests")
struct ProperNounCorrectionTests {

    // MARK: - Corrections

    @Test("A near-miss surname is corrected")
    func testCorrectsSurname() {
        let (text, count) = ProperNounCorrection.correct(
            "[00:05] You: ich spreche mit Anna Schmitt heute",
            terms: ["Anna Schmid"])

        #expect(text == "[00:05] You: ich spreche mit Anna Schmid heute")
        #expect(count == 1)
    }

    @Test("A missing umlaut is restored")
    func testRestoresUmlaut() {
        let (text, count) = ProperNounCorrection.correct(
            "hallo Herr Muller", terms: ["Müller"])

        #expect(text == "hallo Herr Müller")
        #expect(count == 1)
    }

    @Test("Multiple occurrences are all corrected")
    func testMultipleOccurrences() {
        let (text, count) = ProperNounCorrection.correct(
            "Kowalksi sagte etwas. Dann sagte Kowalksi noch etwas.",
            terms: ["Kowalski"])

        #expect(!text.contains("Kowalksi"))
        #expect(count == 2)
    }

    // MARK: - Guardrails

    @Test("Text that already matches is left untouched")
    func testExactMatchUntouched() {
        let input = "[00:05] You: Anna Schmid ist dabei"
        let (text, count) = ProperNounCorrection.correct(input, terms: ["Anna Schmid"])

        #expect(text == input)
        #expect(count == 0)
    }

    @Test("A common word equal to a term is not re-capitalized")
    func testNoCaseVandalism() {
        // "marketing" matches the project name exactly (ignoring case) → must not be changed.
        let input = "wir haben über marketing gesprochen"
        let (text, count) = ProperNounCorrection.correct(input, terms: ["Marketing"])

        #expect(text == input)
        #expect(count == 0)
    }

    @Test("Unrelated words beyond the distance tolerance are not replaced")
    func testTooDistantNotReplaced() {
        let input = "wir haben über Verträge gesprochen"
        let (text, count) = ProperNounCorrection.correct(input, terms: ["Kowalski"])

        #expect(text == input)
        #expect(count == 0)
    }

    @Test("The timestamp and speaker label are never altered")
    func testPrefixPreserved() {
        // "Speaker" is within edit distance 2 of the term "Speeker" — but it sits in the prefix.
        let (text, _) = ProperNounCorrection.correct(
            "[01:15] Speaker 1: guten Tag", terms: ["Speeker"])

        #expect(text.hasPrefix("[01:15] Speaker 1: "))
    }

    @Test("Terms shorter than the minimum length are ignored")
    func testShortTermsIgnored() {
        let input = "das war ein Tor"
        let (text, count) = ProperNounCorrection.correct(input, terms: ["Tim"])

        #expect(text == input)
        #expect(count == 0)
    }

    @Test("A multi-word term corrects the full name as one unit")
    func testMultiWordTermWins() {
        // The two-word term is tried before the one-word term, so the surname is fixed as part of
        // the full name instead of the words being corrected independently.
        let (text, count) = ProperNounCorrection.correct(
            "gesprochen mit Anna Schmitt",
            terms: ["Anna", "Anna Schmid"])

        #expect(text == "gesprochen mit Anna Schmid")
        #expect(count == 1)
    }

    @Test("Two separate typos in one name exceed the tolerance and are left alone")
    func testConservativeLimit() {
        // "Ana Schmitt" → "Anna Schmid" is 3 edits; the tolerance for an 11-character term is 2.
        // Documents the deliberate trade-off: we would rather miss a fix than corrupt text.
        let input = "gesprochen mit Ana Schmitt"
        let (text, count) = ProperNounCorrection.correct(input, terms: ["Anna Schmid"])

        #expect(text == input)
        #expect(count == 0)
    }

    @Test("Empty terms or empty text are no-ops")
    func testEmptyInputs() {
        #expect(ProperNounCorrection.correct("hallo", terms: []).text == "hallo")
        #expect(ProperNounCorrection.correct("", terms: ["Anna Schmid"]).text == "")
    }

    // MARK: - Distance helper

    @Test("Edit distance is computed correctly")
    func testEditDistance() {
        #expect(ProperNounCorrection.editDistance("schmid", "schmitt") == 2)
        #expect(ProperNounCorrection.editDistance("abc", "abc") == 0)
        #expect(ProperNounCorrection.editDistance("", "abc") == 3)
    }
}
