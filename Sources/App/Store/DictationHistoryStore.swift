// Purpose: DictationHistoryStore, everything said through the dictation key: quick dictations
//          (the text that was inserted) and Claude mini tasks (the spoken request and Claude's
//          answer). Backs the sidebar "Clipboard", so text is never lost when pasting fails or
//          when something from earlier is needed again.
// Dependencies: Foundation (JSON file dictation-history.json in the app's base directory)
// RBAC: None (local, single user).
// Dependents: Sources/App/Supporting/QuickDictationController.swift (records entries),
//             Sources/App/Views/DictationHistoryView.swift (lists, copies, deletes),
//             Sources/App/ViewModels/AppViewModel.swift (owns the store)
// Notes: User request 2026-10-04. Newest first, capped at `limit` entries so the file stays
//        small; older entries drop off silently. Saved atomically on every change. It holds
//        everything dictated, so the view offers deleting single entries and clearing all.

import Foundation
import Observation

struct DictationHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case dictation
        case claudeTask
    }

    let id: UUID
    let date: Date
    let kind: Kind
    /// Dictation: the dictated text. Claude task: Claude's answer.
    let text: String
    /// Claude task only: what the user asked.
    let request: String?
    /// The app that was frontmost, e.g. "Mail".
    let appName: String?
    /// False when inserting failed and the text went to the clipboard instead.
    let inserted: Bool

    init(
        id: UUID = UUID(), date: Date = Date(), kind: Kind, text: String,
        request: String? = nil, appName: String? = nil, inserted: Bool
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
        self.request = request
        self.appName = appName
        self.inserted = inserted
    }
}

@Observable
@MainActor
final class DictationHistoryStore {
    static let limit = 1000

    private(set) var entries: [DictationHistoryEntry] = []
    @ObservationIgnored private let fileURL: URL

    init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("dictation-history.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([DictationHistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    func add(_ entry: DictationHistoryEntry) {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
