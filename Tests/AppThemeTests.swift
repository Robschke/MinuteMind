// Purpose: Tests for the colour themes: hex conversion and luminance, the Custom theme's derived
//          text colours, and that ThemeStore saves and restores theme, custom colours and mode.
// Dependencies: Sources/App/Config/AppTheme.swift, Sources/App/Supporting/ThemeStore.swift

import AppKit
import Foundation
import Testing

@testable import MinuteMindApp

@Suite("App themes")
@MainActor
struct AppThemeTests {

    @Test("Hex values survive the trip through NSColor")
    func testHexRoundTrip() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0xC2541C, 0x0B1220, 0x22D3EE] {
            #expect(ThemeColor.hex(of: ThemeColor.srgb(hex)) == hex)
        }
    }

    @Test("Luminance runs from black to white")
    func testLuminance() {
        #expect(ThemeColor.luminance(0x000000) == 0)
        #expect(abs(ThemeColor.luminance(0xFFFFFF) - 1) < 0.0001)
        #expect(ThemeColor.luminance(0x0B1220) < 0.4)
        #expect(ThemeColor.luminance(0xFBF8F3) > 0.4)
    }

    @Test("A hex colour resolves to its light and dark value")
    func testResolve() {
        let color = ThemeColor.hex(light: 0x112233, dark: 0x445566)
        #expect(color.resolved(dark: false) == 0x112233)
        #expect(color.resolved(dark: true) == 0x445566)
    }

    @Test("Custom with a dark background in light mode gets light text")
    func testCustomTextFollowsBackground() {
        var custom = CustomThemeSettings(baseID: AppTheme.ember.id)
        custom.background = .hex(light: 0x101010, dark: 0xFAFAFA)
        let theme = custom.resolve()
        #expect(theme.id == AppTheme.customID)
        #expect(theme.textPrimary.resolved(dark: false) == 0xF5F5F7)
        #expect(theme.textPrimary.resolved(dark: true) == 0x1D1D1F)
        // Untouched colours come from the base theme.
        #expect(theme.accent == AppTheme.ember.accent)
        #expect(theme.speakers == AppTheme.ember.speakers)
    }

    @Test("Custom without overrides is its base theme under another name")
    func testCustomWithoutOverrides() {
        let theme = CustomThemeSettings(baseID: AppTheme.midnight.id).resolve()
        #expect(theme.background == AppTheme.midnight.background)
        #expect(theme.textPrimary == AppTheme.midnight.textPrimary)
    }

    @Test("Theme, custom colours and mode are saved and restored")
    func testPersistence() throws {
        let suite = "AppThemeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ThemeStore(defaults: defaults)
        #expect(store.themeID == AppTheme.studio.id)
        store.custom.accent = .hex(light: 0x123456, dark: 0x654321)
        store.themeID = AppTheme.customID
        store.appearanceMode = .dark

        let reloaded = ThemeStore(defaults: defaults)
        #expect(reloaded.themeID == AppTheme.customID)
        #expect(reloaded.custom.accent == .hex(light: 0x123456, dark: 0x654321))
        #expect(reloaded.appearanceMode == .dark)
        #expect(reloaded.theme.accent == .hex(light: 0x123456, dark: 0x654321))
    }

    @Test("Custom colours saved as profiles: several, restored, edited in place, renamed, deleted")
    func testProfiles() throws {
        let suite = "AppThemeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ThemeStore(defaults: defaults)
        store.themeID = AppTheme.customID
        store.custom.accent = .hex(light: 0x111111, dark: 0x222222)
        let first = store.saveProfile(named: "Night Shift")
        #expect(store.themeID == first.themeID)
        #expect(store.theme.name == "Night Shift")
        #expect(store.theme.accent == .hex(light: 0x111111, dark: 0x222222))

        // Editing while the profile is selected changes the profile, not the Custom draft.
        store.editableSettings.accent = .hex(light: 0x333333, dark: 0x444444)
        #expect(store.selectedProfile?.settings.accent == .hex(light: 0x333333, dark: 0x444444))
        #expect(store.custom.accent == .hex(light: 0x111111, dark: 0x222222))

        let second = store.saveProfile(named: "  ")
        #expect(second.name == "My Theme 1")
        #expect(store.profiles.count == 2)
        store.renameProfile(second.id, to: "Daylight")

        let reloaded = ThemeStore(defaults: defaults)
        #expect(reloaded.profiles.map(\.name) == ["Night Shift", "Daylight"])
        #expect(reloaded.themeID == second.themeID)
        #expect(reloaded.theme.accent == .hex(light: 0x333333, dark: 0x444444))

        reloaded.deleteProfile(second.id)
        #expect(reloaded.themeID == AppTheme.studio.id, "falls back to the theme it was based on")
        #expect(reloaded.profiles.map(\.name) == ["Night Shift"])
        #expect(reloaded.saveProfile(named: "Night Shift").name == "Night Shift 2")
    }
}
