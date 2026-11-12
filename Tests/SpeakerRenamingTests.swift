// Purpose: Tests for SpeakerRenaming — rewriting speaker labels in a rendered transcript without
//          touching timestamps or the spoken text.
// Dependencies: Sources/App/Transcription/SpeakerRenaming.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("SpeakerRenaming Tests")
struct SpeakerRenamingTests {

    private let transcript = """
        [00:05] You: also fangen wir an

        [00:09] Speaker 1: ja gerne

        [00:14] Speaker 2: ich habe eine Frage

        [00:20] Speaker 1: gerne
        """

    @Test("Named speakers are replaced everywhere they appear")
    func testRenamesAllOccurrences() {
        let (text, changed) = SpeakerRenaming.apply(["Speaker 1": "Anna"], to: transcript)

        #expect(text.contains("[00:09] Anna: ja gerne"))
        #expect(text.contains("[00:20] Anna: gerne"))
        #expect(!text.contains("Speaker 1"))
        #expect(changed == 2)
    }

    @Test("Unnamed speakers keep their label")
    func testLeavesOthersAlone() {
        let (text, _) = SpeakerRenaming.apply(["Speaker 1": "Anna"], to: transcript)

        #expect(text.contains("[00:14] Speaker 2: ich habe eine Frage"))
        #expect(text.contains("[00:05] You: also fangen wir an"))
    }

    @Test("Several speakers can be renamed at once")
    func testRenamesMultiple() {
        let (text, changed) = SpeakerRenaming.apply(
            ["Speaker 1": "Anna", "Speaker 2": "Ben"], to: transcript)

        #expect(text.contains("[00:09] Anna:"))
        #expect(text.contains("[00:14] Ben:"))
        #expect(changed == 3)
    }

    @Test("Timestamps and spoken text are never altered")
    func testTimestampsAndTextPreserved() {
        let (text, _) = SpeakerRenaming.apply(["Speaker 1": "Anna"], to: transcript)
        let original = transcript.components(separatedBy: "\n")
        let renamed = text.components(separatedBy: "\n")

        #expect(renamed.count == original.count)
        for (before, after) in zip(original, renamed) {
            #expect(after.prefix(8) == before.prefix(8))  // "[MM:SS] "
            if let colon = before.firstIndex(of: ":"), before.hasPrefix("[") {
                // spoken text after the label is byte-identical
                let beforeText = before[before.index(after: colon)...]
                let afterText = after[after.index(after: after.firstIndex(of: ":")!)...]
                if !before.contains("Speaker 1") { #expect(beforeText == afterText) }
            }
        }
    }

    @Test("A name occurring inside the spoken text is not rewritten")
    func testNoAccidentalTextRewrite() {
        // "Speaker 1" also appears as spoken content — only the label position may change.
        let input = "[00:09] Speaker 1: ich glaube Speaker 1 hat recht"
        let (text, changed) = SpeakerRenaming.apply(["Speaker 1": "Anna"], to: input)

        #expect(text == "[00:09] Anna: ich glaube Speaker 1 hat recht")
        #expect(changed == 1)
    }

    @Test("A language flag between label and colon is preserved")
    func testLanguageFlagPreserved() {
        let input = "[00:09] Speaker 1 (🇩🇪): ja gerne"
        let (text, changed) = SpeakerRenaming.apply(["Speaker 1": "Anna"], to: input)

        #expect(text == "[00:09] Anna (🇩🇪): ja gerne")
        #expect(changed == 1)
    }

    @Test("Empty names are ignored")
    func testEmptyNameIgnored() {
        let (text, changed) = SpeakerRenaming.apply(["Speaker 1": "   "], to: transcript)

        #expect(text == transcript)
        #expect(changed == 0)
    }

    @Test("Renaming is reversible by applying the inverse map")
    func testReversible() {
        let (renamed, _) = SpeakerRenaming.apply(["Speaker 1": "Anna"], to: transcript)
        let (restored, _) = SpeakerRenaming.apply(["Anna": "Speaker 1"], to: renamed)

        #expect(restored == transcript)
    }

    @Test("Labels present in a transcript are listed in order of first appearance")
    func testLabelDiscovery() {
        #expect(SpeakerRenaming.labels(in: transcript) == ["You", "Speaker 1", "Speaker 2"])
    }

    @Test("Lines that are not transcript lines are left alone")
    func testNonTranscriptLines() {
        let input = "just a plain note\nwithout any prefix"
        let (text, changed) = SpeakerRenaming.apply(["Speaker 1": "Anna"], to: input)

        #expect(text == input)
        #expect(changed == 0)
    }
}
