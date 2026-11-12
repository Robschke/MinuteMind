import AVFoundation
import Foundation
import Testing

@testable import MinuteMindApp

struct AudioImportServiceTests {
    /// Writes a short silent WAV file so the importer has real audio to inspect.
    private func makeAudioFile(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000  // 1 second of silence
        try file.write(from: buffer)
        return url
    }

    @Test func acceptsAudioExtensionsAndRejectsOthers() {
        #expect(AudioImportService.hasAudioExtension(URL(fileURLWithPath: "/tmp/memo.m4a")))
        #expect(AudioImportService.hasAudioExtension(URL(fileURLWithPath: "/tmp/memo.MP3")))
        #expect(AudioImportService.hasAudioExtension(URL(fileURLWithPath: "/tmp/memo.wav")))
        #expect(!AudioImportService.hasAudioExtension(URL(fileURLWithPath: "/tmp/notes.pdf")))
        #expect(!AudioImportService.hasAudioExtension(URL(fileURLWithPath: "/tmp/clip.mov")))
    }

    @Test func copiesFileIntoRecordingsAndReportsDuration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeAudioFile(named: "GYM Integration.wav", in: root.appendingPathComponent("src"))
        let recordings = root.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)

        let imported = try await AudioImportService.copy(
            source, into: recordings, fileNameBase: "gym-integration-ab12cd")

        #expect(imported.fileName == "gym-integration-ab12cd-imported.wav")
        #expect(imported.title == "GYM Integration")
        #expect(imported.duration > 0.9 && imported.duration < 1.1)
        #expect(
            FileManager.default.fileExists(
                atPath: recordings.appendingPathComponent(imported.fileName).path))
        // The original stays put — imports copy, never move.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func rejectsFilesWithoutAudioTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fake = root.appendingPathComponent("not-really-audio.m4a")
        try Data("plain text".utf8).write(to: fake)

        await #expect(throws: (any Error).self) {
            try await AudioImportService.copy(fake, into: root, fileNameBase: "fake")
        }
    }
}
