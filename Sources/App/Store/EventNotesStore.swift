// Purpose: Persists EventNote objects as JSON under MinuteMind/event-notes.json.
// Dependencies: Foundation, EventNote model
// Used by: Sources/App/ViewModels/AppViewModel.swift (eventNotesStore property)
// Notes: Intentionally a plain final class (not ObservableObject) — AppViewModel owns the
//        @Published eventNotes array and calls load()/save() as needed.

import Foundation

final class EventNotesStore {
    private let fileURL: URL

    init(baseDirectory: URL) {
        self.fileURL = baseDirectory.appendingPathComponent("event-notes.json")
    }

    func load() -> [EventNote] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([EventNote].self, from: data)) ?? []
    }

    func save(_ notes: [EventNote]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(notes)
        try data.write(to: fileURL, options: .atomic)
    }
}
