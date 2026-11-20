// Purpose: Tests for the theme MCP tools: the rules text, listing, starting from a built-in,
//          previewing, saving (and selecting), refusing bad drafts and deleting.
// Dependencies: Sources/App/Services/MCP/MCPThemeTools.swift, Sources/App/Supporting/ThemeStore.swift

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("MCPThemeTools Tests")
struct MCPThemeToolsTests {
    private let suite = "MCPThemeToolsTests-\(UUID().uuidString)"

    private func makeTools() throws -> (MCPThemeTools, ThemeStore) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MCPThemeToolsTests-\(UUID().uuidString)")
        let store = ThemeStore(defaults: defaults, fileStore: ThemeFileStore(folder: folder))
        let tools = MCPThemeTools(
            themes: store, previewFolder: folder.appendingPathComponent("previews"), installedFamilies: { ["Menlo"] })
        return (tools, store)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private let draft: [String: Any] = [
        "id": "terminal", "name": "Terminal", "base": "midnight",
        "colors": ["background": ["light": "#F6F7F9", "dark": "#0A0D12"]],
        "font": ["family": "Menlo", "scale": 0.95], "corners": "square", "density": "compact",
        "terminal": ["family": "Menlo", "size": 13],
    ]

    @Test func rulesNameEveryColourAndStyleValue() throws {
        let (tools, _) = try makeTools()
        let rules = try tools.execute(toolName: "get_theme_rules", arguments: [:]).text
        for key in ThemeFile.colorKeys { #expect(rules.contains("`\(key)`")) }
        for corners in ThemeStyle.Corners.allCases { #expect(rules.contains("`\(corners.rawValue)`")) }
        for density in ThemeStyle.Density.allCases { #expect(rules.contains("`\(density.rawValue)`")) }
    }

    @Test func getOfABuiltInSuggestsANewThemeFile() throws {
        let (tools, _) = try makeTools()
        let theme = try object(try tools.execute(toolName: "get_theme", arguments: ["id": "midnight"]).text)
        #expect(theme["id"] as? String == "midnight")
        #expect(theme["base"] as? String == "midnight")
        #expect((theme["colors"] as? [String: Any])?["accent"] != nil)
    }

    @Test func previewReturnsAPictureAndSavesNothing() throws {
        let (tools, store) = try makeTools()
        let output = try tools.execute(toolName: "preview_theme", arguments: ["theme": draft])
        #expect(output.png?.isEmpty == false)
        #expect(store.fileThemes.isEmpty)
    }

    @Test func saveWritesTheFileAndSelectsIt() throws {
        let (tools, store) = try makeTools()
        let result = try object(try tools.execute(toolName: "save_theme", arguments: ["theme": draft]).text)
        #expect(result["result"] as? String == "created")
        #expect(store.themeID == "file:terminal")
        #expect(store.theme.style.corners == .square)
        #expect(result["warnings"] == nil)

        let listed = try object(try tools.execute(toolName: "list_themes", arguments: [:]).text)
        let themes = try #require(listed["themes"] as? [[String: Any]])
        #expect(themes.contains { $0["id"] as? String == "file:terminal" && $0["active"] as? Bool == true })

        var changed = draft
        changed["density"] = "roomy"
        let again = try object(try tools.execute(toolName: "save_theme", arguments: ["theme": changed, "activate": false]).text)
        #expect(again["result"] as? String == "updated")
        #expect(store.theme.style.density == .roomy)
    }

    @Test func refusesABadDraftWithItsIssues() throws {
        let (tools, store) = try makeTools()
        var bad = draft
        bad["corners"] = "pill"
        #expect(throws: (any Error).self) { try tools.execute(toolName: "save_theme", arguments: ["theme": bad]) }
        #expect(store.fileThemes.isEmpty)
    }

    @Test func deleteOnlyTakesThemeFilesAndFallsBack() throws {
        let (tools, store) = try makeTools()
        _ = try tools.execute(toolName: "save_theme", arguments: ["theme": draft])
        #expect(throws: (any Error).self) { try tools.execute(toolName: "delete_theme", arguments: ["id": "midnight"]) }
        let result = try object(try tools.execute(toolName: "delete_theme", arguments: ["id": "terminal"]).text)
        #expect(result["now_active"] as? String == "midnight")
        #expect(store.fileThemes.isEmpty)
    }
}
