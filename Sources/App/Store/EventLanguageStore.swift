// Purpose: Persists event-series → transcription language overrides so a calendar event (or its
//          full recurring series) can transcribe in a fixed language instead of the global default.
// Dependencies: Foundation
// Used by: Sources/App/ViewModels/AppViewModel.swift (eventLanguageStore property)
// Notes: The store key is CalendarEvent.seriesKey — calendarItemExternalIdentifier for recurring
//        events (shared across all occurrences) or eventIdentifier for single events.
//        A missing entry means "use the global default language" — only explicit overrides are
//        stored. Values are LanguageOption raw values ("auto", "en-US", "de-DE").
//        Only called from @MainActor context, so no locking is needed.
//        Mirrors EventProjectStore.

import Foundation

final class EventLanguageStore {

    private let fileURL: URL
    private var mappings: [String: String]   // seriesKey → LanguageOption.rawValue

    init(baseDirectory: URL) {
        self.fileURL = baseDirectory.appendingPathComponent("event-language-mappings.json")
        self.mappings = Self.load(from: fileURL)
    }

    // MARK: - Public Interface

    /// The language override for this series, or nil when the event uses the global default.
    func languageCode(for seriesKey: String) -> String? {
        mappings[seriesKey]
    }

    /// Set (or clear, when nil) the language override for this series.
    func setLanguageCode(_ languageCode: String?, for seriesKey: String) throws {
        if let code = languageCode {
            mappings[seriesKey] = code
        } else {
            mappings.removeValue(forKey: seriesKey)
        }
        try save()
    }

    // MARK: - Persistence

    private static func load(from fileURL: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(mappings)
        try data.write(to: fileURL, options: .atomic)
    }
}
