// Purpose: Tests for EventProjectStore, above all that deleting a project drops its series mappings.
// Dependencies: Sources/App/Store/EventProjectStore.swift
// Notes: Uses a temp directory per test for full isolation.

import Foundation
import Testing
@testable import MinuteMindApp

@Suite("EventProjectStore Tests")
@MainActor
struct EventProjectStoreTests {

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test("removeMappings drops every series of that project and keeps the others, persisted")
    func removeMappingsDropsOnlyThatProject() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deleted = UUID()
        let kept = UUID()

        let store = EventProjectStore(baseDirectory: dir)
        try store.setProjectID(deleted, for: "lunch-series")
        try store.setProjectID(deleted, for: "daily-series")
        try store.setProjectID(kept, for: "weekly-series")

        try store.removeMappings(to: deleted)

        let reloaded = EventProjectStore(baseDirectory: dir)
        #expect(reloaded.projectID(for: "lunch-series") == nil)
        #expect(reloaded.projectID(for: "daily-series") == nil)
        #expect(reloaded.projectID(for: "weekly-series") == kept)
    }

    @Test("removeMappings without a matching series leaves the store untouched")
    func removeMappingsWithoutMatchIsNoOp() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = UUID()

        let store = EventProjectStore(baseDirectory: dir)
        try store.setProjectID(kept, for: "weekly-series")
        try store.removeMappings(to: UUID())

        #expect(EventProjectStore(baseDirectory: dir).projectID(for: "weekly-series") == kept)
    }
}
