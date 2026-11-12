// Purpose: Tests for DictationHistoryStore: order, persistence, cap, delete and clear.
// Dependencies: Sources/App/Store/DictationHistoryStore.swift

import Foundation
import Testing
@testable import MinuteMindApp

@MainActor
struct DictationHistoryStoreTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func newestFirstAndPersisted() throws {
        let dir = try tempDirectory()
        let store = DictationHistoryStore(baseDirectory: dir)
        store.add(.init(kind: .dictation, text: "first", inserted: true))
        store.add(.init(kind: .claudeTask, text: "answer", request: "write a mail", appName: "Mail", inserted: false))
        #expect(store.entries.map(\.text) == ["answer", "first"])

        let reloaded = DictationHistoryStore(baseDirectory: dir)
        #expect(reloaded.entries.map(\.text) == ["answer", "first"])
        #expect(reloaded.entries.first?.request == "write a mail")
        #expect(reloaded.entries.first?.kind == .claudeTask)
    }

    @Test func ignoresEmptyText() throws {
        let store = DictationHistoryStore(baseDirectory: try tempDirectory())
        store.add(.init(kind: .dictation, text: "  \n", inserted: true))
        #expect(store.entries.isEmpty)
    }

    @Test func capsAtLimit() throws {
        let store = DictationHistoryStore(baseDirectory: try tempDirectory())
        for index in 0..<(DictationHistoryStore.limit + 5) {
            store.add(.init(kind: .dictation, text: "entry \(index)", inserted: true))
        }
        #expect(store.entries.count == DictationHistoryStore.limit)
        #expect(store.entries.first?.text == "entry \(DictationHistoryStore.limit + 4)")
    }

    @Test func deleteAndClear() throws {
        let store = DictationHistoryStore(baseDirectory: try tempDirectory())
        store.add(.init(kind: .dictation, text: "a", inserted: true))
        store.add(.init(kind: .dictation, text: "b", inserted: true))
        store.delete(store.entries[0].id)
        #expect(store.entries.map(\.text) == ["a"])
        store.clear()
        #expect(store.entries.isEmpty)
    }
}
