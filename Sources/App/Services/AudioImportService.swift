// Purpose: Imports an existing audio file (Voice Memo, meeting export, …) into MinuteMind's
//          recordings folder so it can become a normal RecordingSession — the file side of the
//          "import audio" feature: validation, copying, duration.
// Dependencies: AVFoundation, AppKit (open panel), UniformTypeIdentifiers
// Used by: Sources/App/ViewModels/AppViewModel.swift (importAudioFiles),
//          Sources/App/MinuteMindApp.swift (File → Import Audio…)
// Notes: - The file is COPIED, never referenced in place: Voice Memos hands out paths inside a
//          temporary container that disappears, and imports must survive the original moving.
//        - Imported audio is stored as the session's microphone channel, so the whole existing
//          pipeline (waveform, transcription, cropping, export) works unchanged.
//        - No format conversion happens here. Parakeet and Apple Speech resample internally, and keeping
//          the original avoids a lossy re-encode of an already compressed file.

import AVFoundation
import AppKit
import Foundation
import UniformTypeIdentifiers

enum AudioImportService {
    enum ImportError: LocalizedError {
        case unreadable(String)
        case notAudio(String)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "“\(name)” could not be read. Check that the file still exists and is accessible."
            case .notAudio(let name):
                return "“\(name)” contains no audio track and cannot be imported."
            case .copyFailed(let reason):
                return "Failed to import the audio file: \(reason)"
            }
        }
    }

    /// Result of copying one file into the recordings folder.
    struct ImportedAudio {
        /// File name inside the recordings directory — goes straight into `micFileName`.
        let fileName: String
        /// Suggested session title, derived from the original file name.
        let title: String
        let duration: TimeInterval
    }

    /// Audio types offered in the open panel and accepted on drop.
    static let acceptedTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]

    /// True when the URL looks like an audio file we are willing to import (extension check only —
    /// the real validation is `copy(...)` reading the actual tracks).
    static func hasAudioExtension(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audio) || acceptedTypes.contains { type.conforms(to: $0) }
    }

    /// The session title suggested for an audio file — its name without the extension.
    static func suggestedTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Imported Recording" : name
    }

    /// Copies `sourceURL` into `recordingsDirectory` as `<fileNameBase>-imported.<ext>` and reports
    /// the audio duration. Throws when the file has no audio track or cannot be copied.
    /// `fileNameBase` comes from the caller's slug helper so imported files are named like recorded
    /// ones.
    static func copy(
        _ sourceURL: URL,
        into recordingsDirectory: URL,
        fileNameBase: String
    ) async throws -> ImportedAudio {
        let displayName = sourceURL.lastPathComponent
        let asset = AVURLAsset(url: sourceURL)

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ImportError.unreadable(displayName)
        }
        guard !tracks.isEmpty else { throw ImportError.notAudio(displayName) }

        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0

        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let fileName = "\(fileNameBase)-imported.\(ext)"
        let destination = recordingsDirectory.appendingPathComponent(fileName)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }

        return ImportedAudio(
            fileName: fileName,
            title: suggestedTitle(for: sourceURL),
            duration: duration
        )
    }

    /// Shows the standard macOS open panel. Returns the picked audio files (empty when cancelled).
    @MainActor
    static func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.message = "Choose one or more audio files to add as transcript cards."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = acceptedTypes
        return panel.runModal() == .OK ? panel.urls : []
    }
}
