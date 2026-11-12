// Purpose: Exports transcripts and AI summaries into a user-chosen per-project folder,
//          organized as <export folder>/<yyyy-MM-dd>/<meeting name>/, with automatic
//          file versioning instead of overwriting.
// Dependencies: Sources/App/Models/Project.swift (exportFolderPath / exportOptOut),
//               Sources/App/Models/RecordingSession.swift (exportFolderName)
// Used by: Sources/App/ViewModels/AppViewModel.swift
// Notes: Re-running a transcription or summary never overwrites — a "-v2"/"-v3" sibling
//        is written instead. If the new content is identical to the latest existing
//        version, nothing is written (prevents duplicate versions on no-op re-runs).
//        The day folder is derived from the session's createdAt, so re-exports years
//        later still land next to the original recording.

import Foundation

enum ProjectExportService {

    enum Artifact {
        case transcript
        case summary

        var baseName: String {
            switch self {
            case .transcript: return "transcript"
            case .summary: return "summary"
            }
        }

        var fileExtension: String {
            switch self {
            case .transcript: return "txt"
            case .summary: return "md"
            }
        }
    }

    /// Writes `text` into the session's meeting folder inside the project's export folder.
    /// Returns the relative meeting folder ("2026-07-11/Weekly Sync") so the caller can
    /// persist it on the session — later exports and title renames then target the same
    /// folder even if the session title changed in between.
    /// Returns nil when the project has no export folder configured or opted out.
    static func export(
        _ artifact: Artifact,
        text: String,
        session: RecordingSession,
        project: Project
    ) throws -> String? {
        guard let base = exportBaseURL(for: project) else { return nil }

        let relativeFolder = session.exportFolderName ?? defaultRelativeFolder(for: session)
        let folderURL = base.appendingPathComponent(relativeFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        try writeVersioned(text: text, artifact: artifact, in: folderURL)
        return relativeFolder
    }

    /// Renames the session's existing meeting folder after a title change (AI title
    /// generation or manual rename). Returns the new relative folder to persist on the
    /// session, or nil when nothing was renamed (no export yet, target exists, …).
    static func renameMeetingFolder(
        session: RecordingSession,
        project: Project,
        newTitle: String
    ) -> String? {
        guard let base = exportBaseURL(for: project),
            let currentRelative = session.exportFolderName
        else { return nil }

        let dayComponent = (currentRelative as NSString).deletingLastPathComponent
        let newName = sanitizedFolderName(newTitle)
        let newRelative = dayComponent.isEmpty ? newName : "\(dayComponent)/\(newName)"
        guard newRelative != currentRelative else { return nil }

        let fm = FileManager.default
        let currentURL = base.appendingPathComponent(currentRelative, isDirectory: true)
        let newURL = base.appendingPathComponent(newRelative, isDirectory: true)
        guard fm.fileExists(atPath: currentURL.path), !fm.fileExists(atPath: newURL.path) else {
            return nil
        }
        do {
            try fm.moveItem(at: currentURL, to: newURL)
            return newRelative
        } catch {
            NSLog("ProjectExportService: Folder rename failed — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    private static func exportBaseURL(for project: Project) -> URL? {
        guard project.exportOptOut != true,
            let path = project.exportFolderPath, !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func defaultRelativeFolder(for session: RecordingSession) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: session.createdAt)
        return "\(day)/\(sanitizedFolderName(session.title))"
    }

    /// Keeps the human-readable meeting title but strips characters that are unsafe
    /// in folder names, collapses whitespace, and caps the length.
    static func sanitizedFolderName(_ title: String) -> String {
        var invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        invalid.formUnion(.controlCharacters)
        invalid.formUnion(.newlines)
        let cleaned =
            title
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let trimmed = String(cleaned.prefix(80)).trimmingCharacters(
            in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "Untitled Meeting" : trimmed
    }

    /// Writes `transcript.txt` on first export, then `transcript-v2.txt`, `-v3`, … on
    /// re-runs. Skips the write entirely when the latest version already has this content.
    private static func writeVersioned(text: String, artifact: Artifact, in folder: URL) throws {
        let fm = FileManager.default
        var latestURL = folder.appendingPathComponent(
            "\(artifact.baseName).\(artifact.fileExtension)")
        var nextVersion = 2
        while fm.fileExists(atPath: candidateURL(in: folder, artifact: artifact, version: nextVersion).path) {
            latestURL = candidateURL(in: folder, artifact: artifact, version: nextVersion)
            nextVersion += 1
        }

        if fm.fileExists(atPath: latestURL.path) {
            if let existing = try? String(contentsOf: latestURL, encoding: .utf8),
                existing == text {
                return  // identical to the latest version — nothing new to write
            }
            // First export goes to the unversioned name; latestURL exists → write next version.
            let targetVersion = latestURL.lastPathComponent.contains("-v") ? nextVersion : 2
            let target = candidateURL(in: folder, artifact: artifact, version: targetVersion)
            try text.write(to: target, atomically: true, encoding: .utf8)
        } else {
            try text.write(to: latestURL, atomically: true, encoding: .utf8)
        }
    }

    private static func candidateURL(in folder: URL, artifact: Artifact, version: Int) -> URL {
        folder.appendingPathComponent(
            "\(artifact.baseName)-v\(version).\(artifact.fileExtension)")
    }
}
