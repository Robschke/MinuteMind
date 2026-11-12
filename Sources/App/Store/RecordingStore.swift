import Foundation
import UniformTypeIdentifiers

final class RecordingStore {
    private enum StoreError: Error {
        case failedToCreateDirectory
    }

    private let fileManager: FileManager
    let baseDirectory: URL
    let recordingsDirectory: URL
    let transcriptsDirectory: URL
    let minutesDirectory: URL
    private let sessionsFileURL: URL

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
        self.recordingsDirectory = baseDirectory.appendingPathComponent("Recordings", isDirectory: true)
        self.transcriptsDirectory = baseDirectory.appendingPathComponent("Transcripts", isDirectory: true)
        self.minutesDirectory = baseDirectory.appendingPathComponent("MeetingMinutes", isDirectory: true)
        self.sessionsFileURL = baseDirectory.appendingPathComponent("sessions.json", conformingTo: .json)
        try? ensureDirectories()
    }

    func ensureDirectories() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: recordingsDirectory.path) {
            try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: transcriptsDirectory.path) {
            try fileManager.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: minutesDirectory.path) {
            try fileManager.createDirectory(at: minutesDirectory, withIntermediateDirectories: true)
        }
    }

    func loadSessions() throws -> [RecordingSession] {
        guard fileManager.fileExists(atPath: sessionsFileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: sessionsFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RecordingSession].self, from: data)
    }

    func saveSessions(_ sessions: [RecordingSession]) throws {
        // Compact encoding — sessions.json is machine-only, and pretty-printing
        // forces every Float waveform sample through String(describing:), which
        // dominated CPU time on startup migrations. Compact JSON uses the fast
        // Float→ASCII path.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sessions)
        try ensureDirectories()
        try data.write(to: sessionsFileURL, options: .atomic)
    }
}
