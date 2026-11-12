// Purpose: Persists event-series → project UUID mappings so recordings, transcripts, and notes
//          for a calendar event (or its full recurring series) are automatically routed to a project.
// Dependencies: Foundation
// Used by: Sources/App/ViewModels/AppViewModel.swift (eventProjectStore property)
// Notes: The store key is CalendarEvent.seriesKey — calendarItemExternalIdentifier for recurring
//        events (shared across all occurrences) or eventIdentifier for single events.
//        UUID values are encoded as strings in the JSON file for human-readability.
//        Only called from @MainActor context, so no locking is needed.
//        A mapping can outlive its project (deleted before removeMappings existed), so callers
//        check the returned ID against the existing projects (AppViewModel.projectID(for:)).

import Foundation

final class EventProjectStore {

    private let fileURL: URL
    private var mappings: [String: String]   // seriesKey → projectID.uuidString

    init(baseDirectory: URL) {
        self.fileURL = baseDirectory.appendingPathComponent("event-project-mappings.json")
        self.mappings = Self.load(from: fileURL)
    }

    // MARK: - Public Interface

    func projectID(for seriesKey: String) -> UUID? {
        guard let raw = mappings[seriesKey] else { return nil }
        return UUID(uuidString: raw)
    }

    func setProjectID(_ projectID: UUID?, for seriesKey: String) throws {
        if let id = projectID {
            mappings[seriesKey] = id.uuidString
        } else {
            mappings.removeValue(forKey: seriesKey)
        }
        try save()
    }

    /// Drops every series routed to `projectID`, so a deleted project stops receiving recordings.
    func removeMappings(to projectID: UUID) throws {
        let raw = projectID.uuidString
        let before = mappings.count
        mappings = mappings.filter { $0.value != raw }
        guard mappings.count != before else { return }
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
