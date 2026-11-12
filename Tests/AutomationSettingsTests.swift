// Purpose: Tests for AutomationSettings defaults and UserDefaults isolation (SETT-01, SETT-02, SETT-04).
// Dependencies: Sources/App/Models/AutomationSettings.swift (not yet created — RED state until Plan 02)
// Notes: Uses a unique UserDefaults suite per test (UUID suiteName) to prevent cross-test pollution.
//        AutomationSettings must accept a UserDefaults instance for dependency injection.

import Foundation
import Testing
@testable import MinuteMindApp

@Suite("AutomationSettings Tests")
struct AutomationSettingsTests {

    // Helper: create a fresh isolated UserDefaults suite for each test
    private func makeFreshDefaults() -> UserDefaults {
        let suiteName = "test.\(UUID().uuidString)"
        // UserDefaults(suiteName:) returns an isolated store; no teardown needed since UUID is unique
        return UserDefaults(suiteName: suiteName)!
    }

    // MARK: - Default Value Tests (SETT-01, SETT-02)

    @Test("autoStartEnabled defaults to true")
    func testAutoStartEnabledDefault() {
        let defaults = makeFreshDefaults()
        let settings = AutomationSettings(defaults: defaults)
        #expect(settings.autoStartEnabled == true)
    }

    @Test("autoStopSilenceThreshold defaults to 30 seconds")
    func testAutoStopSilenceThresholdDefault() {
        let defaults = makeFreshDefaults()
        let settings = AutomationSettings(defaults: defaults)
        #expect(settings.autoStopSilenceThreshold == 30.0)
    }

    @Test("teamsDetectionEnabled defaults to false")
    func testTeamsDetectionDefault() {
        let defaults = makeFreshDefaults()
        let settings = AutomationSettings(defaults: defaults)
        #expect(settings.teamsDetectionEnabled == false)
    }

    @Test("autoPipelineEnabled defaults to true")
    func testAutoPipelineDefault() {
        let defaults = makeFreshDefaults()
        let settings = AutomationSettings(defaults: defaults)
        #expect(settings.autoPipelineEnabled == true)
    }

    @Test("defaultTranscriptionModel defaults to parakeet")
    func testDefaultTranscriptionModelDefault() {
        let defaults = makeFreshDefaults()
        let settings = AutomationSettings(defaults: defaults)
        #expect(settings.defaultTranscriptionModel == "parakeet")
    }

    @Test("remindersSyncDefault defaults to true")
    func testRemindersSyncDefault() {
        let defaults = makeFreshDefaults()
        let settings = AutomationSettings(defaults: defaults)
        #expect(settings.remindersSyncDefault == true)
    }

    // MARK: - Persistence Tests (SETT-04)

    @Test("settings persist across instances using the same UserDefaults suite")
    func testPersistsAcrossInstances() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults1 = UserDefaults(suiteName: suiteName)!

        var settings1 = AutomationSettings(defaults: defaults1)
        settings1.autoStartEnabled = false

        // Create a second instance with the same suite — must see the persisted value
        let defaults2 = UserDefaults(suiteName: suiteName)!
        let settings2 = AutomationSettings(defaults: defaults2)
        #expect(settings2.autoStartEnabled == false)
    }
}
