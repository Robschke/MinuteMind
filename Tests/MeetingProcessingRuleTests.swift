// Purpose: Tests for when a recording is processed on its own: as soon as it has a project (or
//          General) and a transcript, named speakers or not, quick recordings included; a project
//          picked before the transcript exists is decided after transcription; never twice.
// Dependencies: Sources/App/Supporting/MeetingProcessingRule.swift,
//               Sources/App/Models/RecordingSession.swift (assignedToGeneral)

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("MeetingProcessingRule Tests")
struct MeetingProcessingRuleTests {
    private func meeting(
        project: UUID? = nil, general: Bool = false, names: [String?] = [], status: RecordingSession.Status = .completed
    ) -> RecordingSession {
        var session = RecordingSession(title: "Weekly", languageCode: "de-DE", status: status, projectID: project)
        session.assignedToGeneral = general ? true : nil
        if status == .completed {
            session.transcript = .init(text: "[00:01] Speaker 1: Hallo", languageCode: "de-DE", updatedAt: Date())
        }
        session.speakerProfiles = names.enumerated().map { index, name in
            RecordingSession.SpeakerProfile(
                label: "Speaker \(index + 1)", name: name, channel: .system, sampleStart: 0, sampleEnd: 3)
        }
        return session
    }

    @Test func withoutAProjectNothingIsProcessed() {
        let session = meeting(names: ["Anna"])
        for trigger in [MeetingProcessingRule.Trigger.transcribed, .assigned, .speakersNamed] {
            #expect(MeetingProcessingRule.decide(session, trigger: trigger) == .waitForProject)
        }
        #expect(MeetingProcessingRule.hold(for: session) == .waitForProject)
    }

    @Test func afterTranscriptionAProjectAndNamedSpeakersProcess() {
        #expect(MeetingProcessingRule.decide(meeting(project: UUID(), names: ["Anna", "Ben"]), trigger: .transcribed) == .process)
        // No diarization: nobody to name.
        #expect(MeetingProcessingRule.decide(meeting(project: UUID()), trigger: .transcribed) == .process)
    }

    @Test func unnamedSpeakersNeverHoldProcessingBack() {
        let session = meeting(project: UUID(), names: ["Anna", nil])
        for trigger in [MeetingProcessingRule.Trigger.transcribed, .assigned, .speakersNamed] {
            #expect(MeetingProcessingRule.decide(session, trigger: trigger) == .process)
        }
        #expect(MeetingProcessingRule.hold(for: session) == nil)
    }

    @Test func generalCountsAsAProject() {
        let session = meeting(general: true, names: ["Anna"])
        #expect(session.hasProcessingTarget)
        #expect(MeetingProcessingRule.decide(session, trigger: .assigned) == .process)
        #expect(MeetingProcessingRule.decide(session, trigger: .transcribed) == .process)
    }

    @Test func assigningBeforeTheTranscriptIsDecidedAfterTranscription() {
        for status in [RecordingSession.Status.transcribing, .recorded, .failed] {
            #expect(MeetingProcessingRule.decide(meeting(project: UUID(), status: status), trigger: .assigned) == .waitForTranscript)
        }
        #expect(MeetingProcessingRule.decide(meeting(project: UUID(), status: .recording), trigger: .assigned) == .none)
        #expect(MeetingProcessingRule.decide(meeting(project: UUID(), status: .transcribing), trigger: .speakersNamed) == .none)
        #expect(MeetingProcessingRule.hold(for: meeting(status: .transcribing)) == nil)
        #expect(MeetingProcessingRule.hold(for: meeting(project: UUID(), status: .transcribing)) == nil)
        // Once transcribed, the project picked meanwhile counts.
        #expect(MeetingProcessingRule.decide(meeting(project: UUID(), names: [nil]), trigger: .transcribed) == .process)
    }

    @Test func processedOrDisabledNeverAutoProcess() {
        var processed = meeting(project: UUID(), names: ["Anna"])
        processed.meetingMinutesFileName = "minutes.md"
        #expect(MeetingProcessingRule.decide(processed, trigger: .assigned) == .none)
        #expect(MeetingProcessingRule.hold(for: processed) == nil)

        #expect(MeetingProcessingRule.decide(meeting(project: UUID()), trigger: .assigned, enabled: false) == .none)
        #expect(MeetingProcessingRule.decide(meeting(project: UUID()), trigger: .transcribed, enabled: false) == .none)
        #expect(MeetingProcessingRule.decide(meeting(project: UUID(), names: [nil]), trigger: .speakersNamed, enabled: false) == .none)
    }

    @Test func quickRecordingsAreProcessedLikeMeetings() {
        var quick = meeting(project: UUID())
        quick.kind = .quickRecording
        #expect(MeetingProcessingRule.decide(quick, trigger: .transcribed) == .process)
        #expect(MeetingProcessingRule.decide(quick, trigger: .assigned) == .process)
    }

    @Test func generalAssignmentSurvivesARoundTrip() throws {
        let session = meeting(general: true)
        let decoded = try JSONDecoder().decode(RecordingSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.assignedToGeneral == true)
        #expect(decoded.projectID == nil)
    }
}
