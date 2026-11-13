// Purpose: StorageAnalyzer — computes disk usage of recording artifacts (audio, waveforms,
//          transcripts, minutes) and aggregates it overall, per project, and as a list of the
//          largest individual recordings. Pure value-type input → background-safe analysis.
// Dependencies: Sources/App/Models/RecordingSession.swift, Sources/App/Models/Project.swift
// RBAC: None — local file metadata only.
// Dependents: Sources/App/ViewModels/AppViewModel.swift (analyzeStorage()),
//             Sources/App/Views/StorageManagementSettingsView.swift (renders StorageReport)
// Notes: Sizing reads file metadata (resourceValues/.fileSizeKey), not file contents — a stat()
//        per file, so it is cheap even with thousands of recordings. Still run off the main actor
//        to keep disk I/O off the UI thread. The "largest recordings" list is restricted to audio
//        files (the dominant consumer and the meaningful target for future archive/compress/delete).

import Foundation

/// Aggregated disk-usage snapshot for all recording artifacts.
struct StorageReport {
    var totalBytes: Int64
    /// Per-project usage, sorted by size descending. Includes a synthetic "unassigned" bucket (id == nil).
    var projects: [ProjectStorageUsage]
    /// Largest individual audio recordings overall, sorted descending.
    var largestRecordings: [RecordingFileUsage]

    static let empty = StorageReport(totalBytes: 0, projects: [], largestRecordings: [])
}

/// Disk usage attributed to a single project (or the unassigned bucket).
struct ProjectStorageUsage: Identifiable {
    /// Project UUID, or nil for recordings without a project.
    let projectID: UUID?
    let name: String
    var totalBytes: Int64
    var recordingCount: Int

    var id: String { projectID?.uuidString ?? "__unassigned__" }
}

/// A single audio file on disk, attributed to its session.
struct RecordingFileUsage: Identifiable {
    let sessionID: UUID
    let sessionTitle: String
    let projectID: UUID?
    /// Human-readable artifact kind, e.g. "Microphone audio".
    let kind: String
    let fileName: String
    let bytes: Int64

    var id: String { fileName }
}

/// How to reclaim space from a recording's audio.
enum StorageArchiveAction {
    /// Re-encode mic/system audio to 32 kbps mono AAC. Lossy, not reversible, ~75% smaller.
    case recompress
    /// Delete all audio files, keeping the transcript and meeting minutes. Frees 100% of audio.
    case deleteAudio
}

enum StorageAnalyzer {
    /// Directories holding recording artifacts. Passed in so the analyzer stays decoupled
    /// from the (private) RecordingStore.
    struct Directories {
        let recordings: URL
        let transcripts: URL
        let minutes: URL
        let waveforms: URL
    }

    /// Computes a full storage report. Safe to call off the main actor — performs only file
    /// metadata reads. `sessions` and `projects` are value snapshots captured by the caller.
    static func analyze(
        sessions: [RecordingSession],
        projects: [Project],
        directories: Directories
    ) -> StorageReport {
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        func sizeOf(_ url: URL?) -> Int64 {
            guard let url else { return 0 }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true,
                  let size = values.fileSize
            else { return 0 }
            return Int64(size)
        }

        var perProject: [UUID?: ProjectStorageUsage] = [:]
        var allAudioFiles: [RecordingFileUsage] = []

        for session in sessions {
            // Audio files (dominant consumer) — eligible for the "largest recordings" list.
            let audioCandidates: [(kind: String, name: String?)] = [
                ("Microphone audio", session.micFileName),
                ("System audio", session.systemFileName),
                ("Original mic (pre-crop)", session.originalMicFileName),
                ("Original system (pre-crop)", session.originalSystemFileName),
            ]

            var sessionBytes: Int64 = 0

            for candidate in audioCandidates {
                guard let name = candidate.name, !name.isEmpty else { continue }
                let url = directories.recordings.appendingPathComponent(name)
                let bytes = sizeOf(url)
                guard bytes > 0 else { continue }
                sessionBytes += bytes
                allAudioFiles.append(
                    RecordingFileUsage(
                        sessionID: session.id,
                        sessionTitle: session.title,
                        projectID: session.projectID,
                        kind: candidate.kind,
                        fileName: name,
                        bytes: bytes
                    )
                )
            }

            // Sidecar artifacts — counted toward totals but not surfaced as "largest recordings".
            if let minutes = session.meetingMinutesFileName, !minutes.isEmpty {
                sessionBytes += sizeOf(directories.minutes.appendingPathComponent(minutes))
            }
            if let live = session.liveTranscriptFileName, !live.isEmpty {
                sessionBytes += sizeOf(directories.transcripts.appendingPathComponent(live))
            }
            sessionBytes += sizeOf(
                directories.waveforms.appendingPathComponent("\(session.id.uuidString).wf")
            )

            guard sessionBytes > 0 else { continue }

            let key = session.projectID
            if var existing = perProject[key] {
                existing.totalBytes += sessionBytes
                existing.recordingCount += 1
                perProject[key] = existing
            } else {
                let project = key.flatMap { projectsByID[$0] }
                perProject[key] = ProjectStorageUsage(
                    projectID: key,
                    name: project?.name ?? "Unassigned",
                    totalBytes: sessionBytes,
                    recordingCount: 1
                )
            }
        }

        let totalBytes = perProject.values.reduce(Int64(0)) { $0 + $1.totalBytes }
        let sortedProjects = perProject.values.sorted { $0.totalBytes > $1.totalBytes }
        let largest = allAudioFiles.sorted { $0.bytes > $1.bytes }

        return StorageReport(
            totalBytes: totalBytes,
            projects: sortedProjects,
            largestRecordings: largest
        )
    }
}
