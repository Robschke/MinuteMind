// Purpose: Tests for AutoRecordStore JSON persistence round-trip (CAL-02).
// Dependencies: Sources/App/Store/AutoRecordStore.swift (not yet created — RED state)
// Notes: Uses a temp directory per test for full isolation. Tests will fail to compile until
//        Plan 02 creates AutoRecordStore with isEnabled(for:) and setEnabled(_:for:) API.

import Foundation
import Testing
@testable import MinuteMindApp

@Suite("AutoRecordStore Tests")
@MainActor
struct AutoRecordStoreTests {

    // MARK: - Default State Tests (CAL-02)

    @Test("isEnabled defaults to false for unknown event IDs")
    func testIsEnabledDefaultsFalse() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AutoRecordStore(baseDirectory: tempDir)
        #expect(store.isEnabled(for: "someID") == false)
    }

    @Test("setEnabled round-trips through a new instance (JSON persistence)")
    func testSetEnabledRoundTripsToNewInstance() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store1 = AutoRecordStore(baseDirectory: tempDir)
        try store1.setEnabled(true, for: "evt-123")

        // Create a second instance at the same path to verify JSON persistence
        let store2 = AutoRecordStore(baseDirectory: tempDir)
        #expect(store2.isEnabled(for: "evt-123") == true)
    }
}
