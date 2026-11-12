// Purpose: Per-event auto-record toggle persistence — stores [eventID: Bool] as JSON.
// Dependencies: Foundation (JSONEncoder, JSONDecoder, FileManager), Observation
// Used by: Sources/App/ViewModels/AppViewModel.swift (autoRecordStore property),
//          Sources/App/Views/CalendarView.swift, WeekCalendarView.swift,
//          CalendarEventDetailView.swift, DailyBriefingView.swift
// Notes: Intentionally a final class (not actor) because it is only ever called from
//        @MainActor context (AppViewModel). Writes to disk on every setEnabled call —
//        the dictionary is tiny so no debounce is needed.
//        @Observable matters here: the checkbox in the event list writes through a Binding, and
//        without observation nothing tells SwiftUI to re-read it. The value was persisted correctly
//        but the tick snapped straight back, which looked exactly like a save that failed.
//        AutomationCoordinator already reaches this through `await MainActor.run`, so the actor
//        annotation costs it nothing.

import Foundation
import Observation

@Observable
@MainActor
final class AutoRecordStore {

    // MARK: - Private State

    private let fileURL: URL
    private var toggles: [String: Bool]

    // MARK: - Public Interface

    init(baseDirectory: URL) {
        self.fileURL = baseDirectory.appendingPathComponent("auto-record-toggles.json")
        self.toggles = Self.load(from: fileURL)
    }

    /// Returns `true` if the user has enabled auto-record for the given event ID.
    /// Returns `false` for unknown event IDs (safe default — never auto-starts without consent).
    func isEnabled(for eventID: String) -> Bool {
        toggles[eventID] ?? false
    }

    /// Persists the auto-record toggle for the given event ID immediately to disk.
    func setEnabled(_ enabled: Bool, for eventID: String) throws {
        toggles[eventID] = enabled
        try save()
    }

    // MARK: - Private Persistence

    private static func load(from fileURL: URL) -> [String: Bool] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
    }

    private func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(toggles)
        try data.write(to: fileURL, options: .atomic)
    }
}
