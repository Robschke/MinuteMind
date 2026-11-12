// Purpose: MeetingProcessingRule, when a recording is processed on its own: as soon as it has a
//          project (or was filed to General) and a transcript, whatever order those arrive in.
// Dependencies: Sources/App/Models/RecordingSession.swift (projectID, assignedToGeneral,
//               meetingMinutesFileName)
// Used by: Sources/App/ViewModels/AppViewModel.swift (meetingAssigned, speakersNamed,
//          shouldProcessAfterTranscription, processingHold), Sources/App/Services/TranscriptionQueue.swift,
//          Sources/App/Views/SpeakerNamingSheet.swift (savesAndProcesses)
// Notes: Nothing is processed before the recording has a project, so the summary and knowledge
//        land in the right workspace. Once it has one, processing never waits for anything else:
//        speaker names are optional (a later rename updates the transcript, the summary keeps
//        the labels it was made with) and quick recordings are processed like meetings (user
//        decision 2026-10-27: "the summary should always be generated", without the user
//        having to do anything after picking the project). The companion asks for the project
//        right after the recording stops (MeetingPillView savedCard).

import Foundation

enum MeetingProcessingRule {
    /// What just happened to the recording.
    enum Trigger {
        case transcribed
        case assigned
        case speakersNamed
    }

    enum Decision: Equatable {
        case process
        /// No project and not filed to General.
        case waitForProject
        /// Has a project but no transcript yet: decided again once it is transcribed.
        case waitForTranscript
        /// Nothing to do (processed already, automatic processing off, still recording).
        case none
    }

    static func decide(_ session: RecordingSession, trigger: Trigger, enabled: Bool = true) -> Decision {
        guard enabled, session.meetingMinutesFileName == nil else { return .none }
        guard session.hasProcessingTarget else { return .waitForProject }
        switch session.status {
        // A running recording is decided once it is transcribed.
        case .recording, .liveTranscribing, .idle: return .none
        default: break
        }
        guard session.status == .completed, session.transcript != nil else {
            return trigger == .assigned ? .waitForTranscript : .none
        }
        return .process
    }

    /// Why a transcribed, unprocessed recording is not being processed, for the inbox and the card.
    /// Nil when nothing holds it back.
    static func hold(for session: RecordingSession) -> Decision? {
        guard session.status == .completed, session.transcript != nil, session.meetingMinutesFileName == nil,
              !session.hasProcessingTarget else { return nil }
        return .waitForProject
    }
}

extension RecordingSession {
    /// A project, or explicitly filed to the General workspace.
    var hasProcessingTarget: Bool { projectID != nil || assignedToGeneral == true }
}
