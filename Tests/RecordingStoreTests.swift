import Foundation
import Testing
@testable import MinuteMindApp

struct RecordingStoreTests {
    @Test func saveAndLoadRoundTrip() async throws {
        let tempDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let store = RecordingStore(baseDirectory: tempDirectory)
        var session = RecordingSession(title: "Sample", languageCode: "en-US", status: .completed)
        session.micFileName = "mic.caf"
        session.systemFileName = "system.m4a"

        try store.saveSessions([session])
        let loaded = try store.loadSessions()

        #expect(loaded.count == 1)
        #expect(loaded.first?.title == session.title)
        #expect(loaded.first?.languageCode == session.languageCode)
    }
}
