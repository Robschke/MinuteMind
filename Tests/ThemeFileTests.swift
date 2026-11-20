// Purpose: Tests for theme files: what the validator accepts and refuses, how a file resolves
//          into a theme (base, derived text colours, style), the round trip through JSON, the
//          warnings, the folder store and how ThemeStore picks files up and falls back.
// Dependencies: Sources/App/Config/ThemeFile.swift, Sources/App/Supporting/ThemeFileStore.swift,
//               Sources/App/Supporting/ThemeStore.swift

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("ThemeFile Tests")
struct ThemeFileTests {
    private func validated(_ object: [String: Any]) throws -> ThemeFile {
        try ThemeFileValidator.validated(object)
    }

    private func issues(_ object: [String: Any]) -> [String] {
        do {
            _ = try validated(object)
            return []
        } catch let failure as ThemeFileValidator.Failure {
            return failure.issues
        } catch {
            return ["\(error)"]
        }
    }

    private let terminal: [String: Any] = [
        "id": "terminal", "name": "Terminal", "base": "midnight",
        "colors": ["background": "#0B0F14", "accent": ["light": "#0E7490", "dark": "#22D3EE"]],
        "font": ["family": "Menlo", "scale": 1.1], "corners": "square", "density": "compact",
        "terminal": ["family": "Menlo", "size": 15],
    ]

    @Test func aMinimalThemeIsStudioWithAName() throws {
        let file = try validated(["id": "plain", "name": "Plain"])
        #expect(file.base == "studio")
        #expect(file.style == .standard)
        let theme = file.resolve()
        #expect(theme.id == "file:plain")
        #expect(theme.accent == AppTheme.studio.accent)
    }

    @Test func readsColoursAndStyle() throws {
        let file = try validated(terminal)
        #expect(file.colors["accent"] == .hex(light: 0x0E7490, dark: 0x22D3EE))
        #expect(file.colors["background"] == .hex(light: 0x0B0F14, dark: 0x0B0F14))
        #expect(file.style.fontFamily == "Menlo")
        #expect(file.style.fontScale == 1.1)
        #expect(file.style.corners == .square)
        #expect(file.style.density == .compact)
        #expect(file.style.terminalFontSize == 15)
    }

    @Test func unsetColoursComeFromTheBaseAndTextFollowsTheBackground() throws {
        let theme = try validated(terminal).resolve()
        #expect(theme.card == AppTheme.midnight.card)
        // A dark background in both modes gets light text in both modes.
        #expect(theme.textPrimary == .hex(light: 0xF5F5F7, dark: 0xF5F5F7))
        #expect(theme.style.corners == .square)
    }

    @Test func refusesTyposAndValuesOutOfRange() {
        #expect(issues(["id": "x", "name": "X", "colour": [:]]).contains { $0.contains("Unknown key \"colour\"") })
        #expect(issues(["id": "x", "name": "X", "colors": ["accent": "orange"]]).contains { $0.hasPrefix("colors.accent") })
        #expect(issues(["id": "x", "name": "X", "colors": ["link": "#FFFFFF"]]).contains { $0.contains("Unknown colour \"link\"") })
        #expect(issues(["id": "x", "name": "X", "colors": ["speakers": ["#FFFFFF"]]]).contains { $0.contains("exactly 8") })
        #expect(issues(["id": "x", "name": "X", "font": ["scale": 3]]).contains { $0.hasPrefix("font.scale") })
        #expect(issues(["id": "x", "name": "X", "terminal": ["size": 40]]).contains { $0.hasPrefix("terminal.size") })
        #expect(issues(["id": "x", "name": "X", "corners": "pill"]).contains { $0.hasPrefix("corners") })
        #expect(issues(["id": "x", "name": "X", "density": "tight"]).contains { $0.hasPrefix("density") })
        #expect(issues(["id": "x", "name": "X", "base": "nord"]).contains { $0.hasPrefix("base") })
        #expect(issues(["id": "Bad ID", "name": "X"]).contains { $0.hasPrefix("id") })
        #expect(issues(["id": "x", "name": ""]).contains { $0.hasPrefix("name") })
        #expect(issues(["id": "x", "name": "X", "formatVersion": 2]).contains { $0.contains("newer") })
    }

    @Test func theFileNameWinsOverTheIdInside() throws {
        let file = try ThemeFileValidator.validated(["id": "other", "name": "X"], fileID: "mine")
        #expect(file.id == "mine")
    }

    @Test func survivesARoundTripThroughJSON() throws {
        var object = terminal
        object["colors"] = [
            "background": "#0B0F14",
            "speakers": ["#111111", "#222222", "#333333", "#444444", "#555555", "#666666", "#777777", "#888888"],
        ]
        let file = try validated(object)
        let data = try JSONSerialization.data(withJSONObject: file.jsonObject)
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(try validated(decoded) == file)
    }

    @Test func aSnapshotOfABuiltInResolvesToTheSameColours() throws {
        let file = ThemeFile.snapshot(of: .ember, id: "ember-copy", name: "Ember copy")
        let theme = try validated(file.jsonObject).resolve()
        #expect(theme.accent.resolved(dark: true) == AppTheme.ember.accent.resolved(dark: true))
        #expect(theme.background.resolved(dark: false) == AppTheme.ember.background.resolved(dark: false))
        #expect(theme.speakers.count == 8)
    }

    @Test func warnsAboutMissingFontsAndUnreadableText() throws {
        let file = try validated([
            "id": "x", "name": "X", "font": ["family": "No Such Font"],
            "colors": ["background": "#FFFFFF", "textPrimary": "#EEEEEE"],
        ])
        let warnings = ThemeFileValidator.warnings(for: file, installedFamilies: ["Menlo"])
        #expect(warnings.contains { $0.contains("\"No Such Font\" is not installed") })
        #expect(warnings.contains { $0.contains("textPrimary") })
        // Readable on the page and on its own dark card, fonts installed: nothing to say.
        var readable = terminal
        readable["colors"] = ["background": "#0B0F14", "card": "#141A22"]
        #expect(ThemeFileValidator.warnings(for: try validated(readable), installedFamilies: ["Menlo"]).isEmpty)
    }

    @Test func warnsWhenTextDerivedFromTheBackgroundSitsOnTheBaseCard() throws {
        // Only a dark background for both modes: text turns light in both, the card stays the
        // base theme's, which is light in Light mode.
        let file = try validated(["id": "night", "name": "Night", "base": "ember", "colors": ["background": "#0B0F14"]])
        let theme = file.resolve()
        #expect(theme.card == AppTheme.ember.card)
        let warnings = ThemeFileValidator.warnings(for: file, installedFamilies: [])
        #expect(warnings.contains { $0.contains("In light mode textPrimary on card") })
        #expect(!warnings.contains { $0.contains("on background") })
        #expect(!warnings.contains { $0.contains("In dark mode") })

        let withCard = try validated([
            "id": "night", "name": "Night", "base": "ember",
            "colors": ["background": "#0B0F14", "card": "#141A22", "border": "#2A3340"],
        ])
        #expect(ThemeFileValidator.warnings(for: withCard, installedFamilies: []).isEmpty)
    }

    // MARK: - Folder

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ThemeFileTests-\(UUID().uuidString)")
    }

    @Test func storeSavesLoadsAndKeepsTheLastGoodVersionOfABrokenFile() throws {
        let store = ThemeFileStore(folder: temporaryFolder())
        let file = try validated(terminal)
        let url = try store.save(file)
        #expect(store.load().themes == [file])

        try Data("{ \"name\": ".utf8).write(to: url)
        let broken = store.load(previous: [file])
        #expect(broken.themes == [file])
        #expect(broken.problems["terminal.json"] != nil)
        #expect(store.load().themes.isEmpty)

        try Data("{}".utf8).write(to: store.folder.appendingPathComponent("Bad Name.json"))
        #expect(store.load().problems["Bad Name.json"] != nil)

        try store.delete(id: "terminal")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func themeStoreSelectsAFileAndFallsBackToItsBaseWhenItIsDeleted() throws {
        let suite = "ThemeFileTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let themes = ThemeStore(defaults: defaults, fileStore: ThemeFileStore(folder: temporaryFolder()))

        let file = try validated(terminal)
        try themes.saveFileTheme(file)
        #expect(themes.fileThemes == [file])
        themes.themeID = file.themeID
        #expect(themes.theme.style.density == .compact)

        try themes.deleteFileTheme(id: file.id)
        #expect(themes.fileThemes.isEmpty)
        #expect(themes.themeID == "midnight")
        #expect(themes.theme.style == .standard)
    }
}
