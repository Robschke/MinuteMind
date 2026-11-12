// Purpose: Guards that diarized speaker profiles actually survive a save/load round-trip.
//          RecordingSession has a hand-written CodingKeys list and encode(to:); a property missing
//          from either is silently dropped, which is exactly how speakerProfiles was lost before.
// Dependencies: Sources/App/Models/RecordingSession.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("SpeakerProfile Persistence Tests")
struct SpeakerProfilePersistenceTests {

    private func embedding(seed: Int, dimensions: Int = 256) -> [Float] {
        (0..<dimensions).map { index in
            Float((index &* 31 &+ seed &* 17) % 97) / 97.0 - 0.5
        }
    }

    private func session(profiles: [RecordingSession.SpeakerProfile]?) -> RecordingSession {
        var session = RecordingSession(title: "Weekly Sync", languageCode: "de-DE")
        session.speakerProfiles = profiles
        return session
    }

    private func roundTrip(_ session: RecordingSession) throws -> RecordingSession {
        let data = try JSONEncoder().encode(session)
        return try JSONDecoder().decode(RecordingSession.self, from: data)
    }

    @Test("Speaker profiles survive an encode/decode round-trip")
    func testProfilesRoundTrip() throws {
        let voiceID = UUID()
        let original = session(profiles: [
            RecordingSession.SpeakerProfile(
                label: "Speaker 1", name: "Anna", channel: .system,
                sampleStart: 12, sampleEnd: 17,
                embedding: embedding(seed: 3), voiceID: voiceID,
                wasAutoMatched: true, spokenSeconds: 245),
            RecordingSession.SpeakerProfile(
                label: "Speaker 2", channel: .microphone,
                sampleStart: 30, sampleEnd: 34),
        ])

        let decoded = try roundTrip(original)
        let profiles = try #require(decoded.speakerProfiles)

        #expect(profiles.count == 2)
        #expect(profiles[0].label == "Speaker 1")
        #expect(profiles[0].name == "Anna")
        #expect(profiles[0].channel == .system)
        #expect(profiles[0].voiceID == voiceID)
        #expect(profiles[0].wasAutoMatched == true)
        #expect(profiles[0].spokenSeconds == 245)
        #expect(profiles[1].name == nil)
        #expect(profiles[1].embedding == nil)
    }

    @Test("The embedding survives exactly — a lossy round-trip would break voice matching")
    func testEmbeddingIsExact() throws {
        let original = embedding(seed: 7)
        let decoded = try roundTrip(
            session(profiles: [
                RecordingSession.SpeakerProfile(
                    label: "Speaker 1", channel: .system, sampleStart: 0, sampleEnd: 3,
                    embedding: original)
            ]))

        let restored = try #require(decoded.speakerProfiles?.first?.embedding)
        #expect(restored == original)
        #expect(VoiceEmbedding.distance(restored, original) < 0.0001)
    }

    @Test("Embeddings are stored compactly, not as a JSON float array")
    func testEmbeddingEncodingIsCompact() throws {
        let data = try JSONEncoder().encode(
            session(profiles: [
                RecordingSession.SpeakerProfile(
                    label: "Speaker 1", channel: .system, sampleStart: 0, sampleEnd: 3,
                    embedding: embedding(seed: 7))
            ]))

        // 256 floats as JSON text run to roughly 6 KB; base64 of the raw buffer stays under 2 KB.
        #expect(data.count < 2500)
    }

    @Test("A session without diarization stays free of speaker keys")
    func testNoProfilesEncodesNothing() throws {
        let data = try JSONEncoder().encode(session(profiles: nil))
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("speakerProfiles"))
        #expect(try roundTrip(session(profiles: nil)).speakerProfiles == nil)
    }

    @Test("Legacy sessions without the key still decode")
    func testLegacyJSONDecodes() throws {
        let json = """
            {"id":"\(UUID().uuidString)","title":"Old Meeting",
             "createdAt":0,"updatedAt":0,"languageCode":"de-DE","status":"completed"}
            """
        let decoded = try JSONDecoder().decode(
            RecordingSession.self, from: Data(json.utf8))

        #expect(decoded.title == "Old Meeting")
        #expect(decoded.speakerProfiles == nil)
    }
}
