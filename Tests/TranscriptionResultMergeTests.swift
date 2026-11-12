// Purpose: Regression tests for a project picked while a meeting was transcribing being lost when
//          the transcription stored its result (2026-10-13): a run writes back only the fields it
//          owns, so whatever the user changed meanwhile survives.
// Dependencies: Sources/App/Models/RecordingSession.swift (takeTranscriptionResult,
//               takeConvertedAudio), Sources/App/Supporting/MeetingProcessingRule.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("Transcription Result Merge Tests")
struct TranscriptionResultMergeTests {
    /// The copy a transcription run takes when it starts: a meeting without a project.
    private func runStart() -> RecordingSession {
        var session = RecordingSession(title: "Recording", languageCode: "auto", status: .transcribing)
        session.micFileName = "mic.caf"
        session.systemFileName = "system.caf"
        return session
    }

    /// The run fills in its copy the way the transcribe functions do.
    private func finished(_ start: RecordingSession, names: [String?]) -> RecordingSession {
        var run = start
        run.languageCode = "de-DE"
        run.transcript = .init(text: "[00:01] Speaker 1: Hallo", languageCode: "de-DE", updatedAt: Date())
        run.speakerProfiles = names.enumerated().map { index, name in
            RecordingSession.SpeakerProfile(
                label: "Speaker \(index + 1)", name: name, channel: .system, sampleStart: 0, sampleEnd: 3)
        }
        run.status = .completed
        run.lastErrorMessage = nil
        return run
    }

    @Test func aProjectPickedDuringTranscriptionSurvivesTheResult() {
        let start = runStart()
        let project = UUID()
        // Meanwhile the user picks a project, renames the meeting, keeps the audio, skips it.
        var live = start
        live.projectID = project
        live.title = "Weekly"
        live.keepAudio = true
        live.inboxDismissed = true

        live.takeTranscriptionResult(from: finished(start, names: ["Anna"]))

        #expect(live.projectID == project)
        #expect(live.title == "Weekly")
        #expect(live.keepAudio == true)
        #expect(live.inboxDismissed == true)
        #expect(live.status == .completed)
        #expect(live.languageCode == "de-DE")
        #expect(live.transcript?.text == "[00:01] Speaker 1: Hallo")
        #expect(live.speakerProfiles?.first?.name == "Anna")
        // So assigning once is enough: with named speakers it is processed right away.
        #expect(MeetingProcessingRule.decide(live, trigger: .transcribed) == .process)
    }

    @Test func generalPickedDuringTranscriptionSurvivesAndProcessesWithUnnamedSpeakers() {
        let start = runStart()
        var live = start
        live.assignedToGeneral = true

        live.takeTranscriptionResult(from: finished(start, names: [nil, "Ben"]))

        #expect(live.assignedToGeneral == true)
        #expect(live.hasProcessingTarget)
        #expect(MeetingProcessingRule.decide(live, trigger: .transcribed) == .process)
        #expect(MeetingProcessingRule.hold(for: live) == nil)
    }

    @Test func aFailedRunKeepsTheProjectToo() {
        let start = runStart()
        var live = start
        live.projectID = UUID()
        var run = start
        run.status = .failed
        run.lastErrorMessage = "No audio files found."

        live.takeTranscriptionResult(from: run)

        #expect(live.projectID != nil)
        #expect(live.status == .failed)
        #expect(live.lastErrorMessage == "No audio files found.")
    }

    @Test func audioConversionKeepsAProjectPickedMeanwhile() {
        let start = runStart()
        var live = start
        live.projectID = UUID()
        var run = start
        run.micFileName = "mic.m4a"
        run.systemFileName = "system.m4a"

        live.takeConvertedAudio(from: run)

        #expect(live.projectID != nil)
        #expect(live.micFileName == "mic.m4a")
        #expect(live.systemFileName == "system.m4a")
    }
}
