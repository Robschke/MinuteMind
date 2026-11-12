// Purpose: Tests for the recording card's speaker logic: stable colour slots that never collide
//          inside one meeting, the user and generated labels kept out of the palette, initials,
//          the grouped preview turns and the talk-time estimate.
// Dependencies: Sources/App/Components/SpeakerPalette.swift,
//               Sources/App/Transcription/TranscriptSpeakerSummary.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("Speaker palette and summary")
struct SpeakerSummaryTests {

    @Test("A name keeps its slot regardless of case, accents and spacing")
    func testPreferredSlotIsStable() {
        let slot = SpeakerPalette.preferredSlot(for: "Holger Wünsch")
        #expect(SpeakerPalette.preferredSlot(for: "  holger wunsch ") == slot)
        #expect((0..<SpeakerPalette.slotCount).contains(slot))
    }

    @Test("Eight people in one meeting get eight different colours")
    func testNoCollisionsInsideMeeting() {
        let names = ["Anna", "Ben", "Clara", "David", "Eva", "Felix", "Greta", "Hans"]
        let kinds = SpeakerPalette.assign(names, ownName: nil)
        let slots = names.compactMap { name -> Int? in
            if case .person(let slot) = kinds[name] { return slot }
            return nil
        }
        #expect(Set(slots).count == 8)
    }

    @Test("The first speaker always gets their preferred slot")
    func testFirstSpeakerKeepsPreferredSlot() {
        let kinds = SpeakerPalette.assign(["Roman", "Holger"], ownName: nil)
        #expect(kinds["Roman"] == .person(slot: SpeakerPalette.preferredSlot(for: "Roman")))
    }

    @Test("You, the own name and generated labels stay out of the palette")
    func testOwnerAndUnnamed() {
        let kinds = SpeakerPalette.assign(["You", "Robin", "Speaker 2", "Other", "Anna"], ownName: "Robin")
        #expect(kinds["You"] == .owner)
        #expect(kinds["Robin"] == .owner)
        #expect(kinds["Speaker 2"] == .unnamed)
        #expect(kinds["Other"] == .unnamed)
        if case .person = kinds["Anna"] {} else { Issue.record("Anna should be a person") }
    }

    @Test("Initials for names, generated labels and the user")
    func testInitials() {
        #expect(SpeakerPalette.initials(for: "Holger Wunsch", ownName: nil) == "HW")
        #expect(SpeakerPalette.initials(for: "anna", ownName: nil) == "A")
        #expect(SpeakerPalette.initials(for: "Speaker 12", ownName: nil) == "12")
        #expect(SpeakerPalette.initials(for: "You", ownName: "Robin Stein") == "RS")
        #expect(SpeakerPalette.initials(for: "You", ownName: nil) == "Y")
    }

    @Test("Consecutive lines of one speaker merge into one preview turn with the first timestamp")
    func testPreviewTurnsGroup() {
        let text = """
            [00:11] Holger: Maybe the other way around.
            [00:12] Holger: I think.
            [00:14] You: Yeah, good.
            [00:20] Roman: Let's start.
            [00:30] Holger: Fourth turn is cut.
            """
        let turns = TranscriptSpeakerSummary.previewTurns(text)
        #expect(turns.count == 3)
        #expect(turns[0] == .init(speaker: "Holger", timestamp: "00:11", startSeconds: 11,
                                  text: "Maybe the other way around. I think."))
        #expect(turns[1].speaker == "You")
        #expect(turns[2].speaker == "Roman")
    }

    @Test("Talk time runs until the next line, capped, in order of first appearance")
    func testTalkTimes() {
        let text = """
            [00:00] Anna: one two
            [00:10] Ben: three
            [05:00] Anna: four five
            """
        let times = TranscriptSpeakerSummary.talkTimes(text)
        #expect(times.map(\.speaker) == ["Anna", "Ben"])
        // Anna: 10 s, then the last line at 0.4 s per word; Ben: capped at 120 s.
        #expect(abs(times[0].seconds - 10.8) < 0.001)
        #expect(times[1].seconds == 120)
    }
}
