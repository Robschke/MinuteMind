// Purpose: Tests for AudioRetentionPolicy: which recordings lose their audio after 14 days.
// Dependencies: Sources/App/Services/AudioRetentionPolicy.swift, Sources/App/Models/RecordingSession.swift

import Foundation
import Testing
@testable import MinuteMindApp

struct AudioRetentionPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        daysOld: Double,
        transcript: String? = "Hello",
        keep: Bool? = nil,
        status: RecordingSession.Status = .completed
    ) -> RecordingSession {
        var s = RecordingSession(
            title: "Meeting",
            createdAt: now.addingTimeInterval(-daysOld * 86_400),
            languageCode: "en-US",
            status: status,
            micFileName: "mic.m4a",
            systemFileName: "sys.m4a"
        )
        if let transcript {
            s.transcript = .init(text: transcript, languageCode: "en-US", updatedAt: now)
        }
        s.keepAudio = keep
        return s
    }

    @Test func purgesTranscribedAudioOlderThanTwoWeeks() {
        let old = session(daysOld: 15)
        let fresh = session(daysOld: 13)
        let expired = AudioRetentionPolicy.expiredSessions(in: [old, fresh], now: now)
        #expect(expired.map(\.id) == [old.id])
    }

    @Test func keepAudioExemptsTheRecording() {
        let kept = session(daysOld: 30, keep: true)
        #expect(AudioRetentionPolicy.expiredSessions(in: [kept], now: now).isEmpty)
        #expect(AudioRetentionPolicy.daysUntilDeletion(for: kept, now: now) == nil)
    }

    @Test func neverPurgesAudioWithoutTranscript() {
        let untranscribed = session(daysOld: 30, transcript: nil, status: .recorded)
        let empty = session(daysOld: 30, transcript: "")
        #expect(AudioRetentionPolicy.expiredSessions(in: [untranscribed, empty], now: now).isEmpty)
    }

    @Test func skipsActiveAndQueuedSessions() {
        let active = session(daysOld: 30, status: .transcribing)
        let queued = session(daysOld: 30)
        let expired = AudioRetentionPolicy.expiredSessions(
            in: [active, queued], now: now, busySessionIDs: [queued.id])
        #expect(expired.isEmpty)
    }

    @Test func skipsSessionsWithoutAudio() {
        var noAudio = session(daysOld: 30)
        noAudio.micFileName = nil
        noAudio.systemFileName = nil
        #expect(!AudioRetentionPolicy.hasAudio(noAudio))
        #expect(AudioRetentionPolicy.expiredSessions(in: [noAudio], now: now).isEmpty)
    }

    @Test func pendingCropOriginalCountsAsAudio() {
        var cropped = session(daysOld: 30)
        cropped.micFileName = nil
        cropped.systemFileName = nil
        cropped.originalMicFileName = "orig.m4a"
        #expect(AudioRetentionPolicy.expiredSessions(in: [cropped], now: now).count == 1)
    }

    @Test func daysUntilDeletionCountsDown() {
        #expect(AudioRetentionPolicy.daysUntilDeletion(for: session(daysOld: 0.5), now: now) == 14)
        #expect(AudioRetentionPolicy.daysUntilDeletion(for: session(daysOld: 13.5), now: now) == 1)
        #expect(AudioRetentionPolicy.daysUntilDeletion(for: session(daysOld: 20), now: now) == 0)
    }

    @Test func keepAudioRoundTripsAndDefaultsToNil() throws {
        let kept = session(daysOld: 1, keep: true)
        let decoded = try JSONDecoder().decode(
            RecordingSession.self, from: JSONEncoder().encode(kept))
        #expect(decoded.keepAudio == true)

        let plain = session(daysOld: 1)
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("keepAudio"))
    }
}
