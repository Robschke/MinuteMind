// Purpose: Decides which recordings lose their audio after the retention period, so audio files
//          do not pile up on disk while transcripts and summaries stay forever.
// Dependencies: Sources/App/Models/RecordingSession.swift (keepAudio, audio file names)
// RBAC: None.
// Dependents: Sources/App/ViewModels/AppViewModel.swift (purgeExpiredAudio),
//             Sources/App/Components/KeepAudioToggle.swift (days-left caption)
// Notes: Audio is deleted 14 days after the recording was made unless the user ticks "Keep audio"
//        on the card. Only audio goes: transcript, summary, waveform sidecar and the session stay.
//        A recording without a transcript is never purged, because then the audio is the only
//        copy of the meeting (never transcribed, or transcription failed). Active sessions and
//        sessions still waiting in the transcription queue are skipped too.
//        Existing recordings older than 14 days are purged on the first launch with this policy
//        (the user chose that over a grace period on 2026-10-02).

import Foundation

enum AudioRetentionPolicy {
    static let retentionDays = 14

    /// True when the session still references any audio file (pre-crop originals included).
    static func hasAudio(_ session: RecordingSession) -> Bool {
        session.micFileName != nil || session.systemFileName != nil
            || session.originalMicFileName != nil || session.originalSystemFileName != nil
    }

    /// True when the policy applies to this session at all (it may not be due yet).
    static func isSubjectToDeletion(_ session: RecordingSession) -> Bool {
        guard session.keepAudio != true, hasAudio(session), !session.isActive else { return false }
        guard let text = session.transcript?.text, !text.isEmpty else { return false }
        return true
    }

    static func deletionDate(for session: RecordingSession, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: retentionDays, to: session.createdAt)
            ?? session.createdAt.addingTimeInterval(Double(retentionDays) * 86_400)
    }

    /// Whole days until the audio is deleted (0 = at the next purge), or nil when it will not be.
    static func daysUntilDeletion(for session: RecordingSession, now: Date = Date()) -> Int? {
        guard isSubjectToDeletion(session) else { return nil }
        let remaining = deletionDate(for: session).timeIntervalSince(now)
        return max(0, Int((remaining / 86_400).rounded(.up)))
    }

    /// Sessions whose audio is due for deletion now. `busySessionIDs` are skipped (queued jobs).
    static func expiredSessions(
        in sessions: [RecordingSession],
        now: Date = Date(),
        busySessionIDs: Set<UUID> = []
    ) -> [RecordingSession] {
        sessions.filter { session in
            isSubjectToDeletion(session)
                && !busySessionIDs.contains(session.id)
                && deletionDate(for: session) <= now
        }
    }
}
