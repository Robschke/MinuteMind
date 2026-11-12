// Purpose: Tests for the settings Claude can read and change over MCP: every stored "mm." key in the
//          sources is either a catalog setting or listed as internal (so a new setting cannot be
//          forgotten), entries point to existing guide topics, the MCP server's own settings stay
//          read-only, values parse as documented, and the help tool names do not clash.
// Dependencies: Sources/App/Help/AppSettingsCatalog.swift, Sources/App/Help/AppSetting.swift,
//               Sources/App/Help/HelpGuide.swift, Sources/App/Services/MCP/ (tool definitions)
// Notes: The key scan reads Sources/ next to this file, so it runs against the code being tested.
//        No test here builds an AppViewModel: that would touch the real Application Support data.

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("AppSettingsCatalog Tests")
struct AppSettingsCatalogTests {
    private static let sourcesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    /// Every quoted "mm.xxx" literal in Sources.
    private static func storedKeysInSources() throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: "\"(mm\\.[A-Za-z0-9_.]+)\"")
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: sourcesURL, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let keyRange = Range(match.range(at: 1), in: text) { keys.insert(String(text[keyRange])) }
            }
        }
        return keys
    }

    private static func isCovered(_ key: String) -> Bool {
        let settingKeys = Set(AppSettingsCatalog.all.flatMap(\.storageKeys))
        if settingKeys.contains(key) || AppSettingsCatalog.internalKeys[key] != nil { return true }
        return AppSettingsCatalog.internalKeys.keys.contains { $0.hasSuffix(".") && key.hasPrefix($0) }
    }

    @Test("Every stored key in the code is a setting or listed as internal")
    func everyKeyClassified() throws {
        let keys = try Self.storedKeysInSources()
        #expect(keys.count > 30, "the scan found too few keys; is Sources/ where the test expects it?")
        let unclassified = keys.filter { !Self.isCovered($0) }.sorted()
        #expect(unclassified.isEmpty, "Add these to AppSettingsCatalog (or internalKeys): \(unclassified)")
    }

    @Test("Catalog and internal keys still exist in the code")
    func noStaleKeys() throws {
        let keys = try Self.storedKeysInSources()
        let listed = AppSettingsCatalog.all.flatMap(\.storageKeys) + AppSettingsCatalog.internalKeys.keys
        let stale = listed.filter { key in !keys.contains(key) && !keys.contains { $0.hasPrefix(key) } }.sorted()
        #expect(stale.isEmpty, "No longer in the code: \(stale)")
    }

    @Test("Ids are unique snake_case, every entry names an existing guide topic")
    func entriesWellFormed() {
        let settings = AppSettingsCatalog.all
        let ids = settings.map(\.id)
        #expect(Set(ids).count == ids.count)
        let keys = settings.flatMap(\.storageKeys)
        #expect(Set(keys).count == keys.count, "a key belongs to one setting")
        for setting in settings {
            #expect(setting.id.range(of: "^[a-z]+(_[a-z]+)*$", options: .regularExpression) != nil, "bad id \(setting.id)")
            #expect(HelpGuide.topic(setting.helpTopic) != nil, "\(setting.id) points to missing topic \(setting.helpTopic)")
            #expect(setting.location.hasPrefix("Settings >") || setting.location.contains(">") || setting.location.contains("menu"))
            #expect(setting.isWritable || setting.readOnlyReason != nil, "\(setting.id) has no write and no reason")
            if setting.kind == .choice { #expect(setting.options != nil, "\(setting.id) is a choice without options") }
            let text = setting.title + setting.summary + setting.location
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "dash in \(setting.id)")
        }
    }

    @Test("The MCP server's own settings cannot be changed over MCP")
    func mcpSettingsReadOnly() {
        for id in ["mcp_server", "mcp_server_port"] {
            let setting = AppSettingsCatalog.setting(id)
            #expect(setting != nil)
            #expect(setting?.isWritable == false)
        }
        #expect(AppSettingsCatalog.setting("double_tap_to_record")?.isWritable == true)
    }

    @Test("Switches accept booleans and common words, nothing else")
    func parseToggle() throws {
        let setting = try #require(AppSettingsCatalog.setting("double_tap_to_record"))
        #expect(try setting.parse(true, choices: []) == .bool(true))
        #expect(try setting.parse(NSNumber(value: false), choices: []) == .bool(false))
        #expect(try setting.parse("Off", choices: []) == .bool(false))
        #expect(try setting.parse("on", choices: []) == .bool(true))
        #expect(throws: AppSetting.ParseError.self) { try setting.parse("maybe", choices: []) }
    }

    @Test("Choices match value, value ignoring case, or label")
    func parseChoice() throws {
        let setting = try #require(AppSettingsCatalog.setting("quick_dictation_trigger"))
        let choices = [AppSetting.Option(value: "holdFn", label: "Hold fn"), AppSetting.Option(value: "toggle", label: "Press")]
        #expect(try setting.parse("holdFn", choices: choices) == .string("holdFn"))
        #expect(try setting.parse("HOLDFN", choices: choices) == .string("holdFn"))
        #expect(try setting.parse("press", choices: choices) == .string("toggle"))
        #expect(throws: AppSetting.ParseError.self) { try setting.parse("holdLeftShift", choices: choices) }

        let silence = try #require(AppSettingsCatalog.setting("meeting_over_question_after_silence"))
        let seconds = ["15", "30", "60", "120"].map { AppSetting.Option(value: $0, label: "\($0) s") }
        #expect(try silence.parse(60, choices: seconds) == .string("60"))
        #expect(try silence.parse(60.0, choices: seconds) == .string("60"))
    }

    @Test("Times of day and colours parse and print as documented")
    func parseTimesAndColours() throws {
        let times = try #require(AppSetting.timesOfDay("14:30, 9:00,14:30"))
        #expect(AppSetting.timesOfDayText(times) == "09:00, 14:30")
        #expect(AppSetting.timesOfDay("")?.isEmpty == true)
        #expect(AppSetting.timesOfDay("25:00") == nil)
        #expect(AppSetting.timesOfDay("noon") == nil)

        let colour = try #require(AppSettingsCatalog.setting("companion_colour"))
        #expect(try colour.parse("ff8800", choices: []) == .string("#FF8800"))
        #expect(try colour.parse("Default", choices: []) == .string("default"))
        #expect(throws: AppSetting.ParseError.self) { try colour.parse("orange", choices: []) }
        #expect(AppSetting.hexColour("#00FF00") == 0x00FF00)
    }

    @Test("Help and app tools are defined once and do not clash with other tools")
    func toolNames() {
        func names(_ definitions: [[String: Any]]) -> [String] {
            definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        }
        #expect(Set(names(MCPHelpTools.definitions)) == MCPHelpTools.names)
        #expect(Set(names(MCPAppControlTools.definitions)) == MCPAppControlTools.names)
        let others = names(AgentToolRegistry.shared.allDefinitions() + MCPMeetingTools.definitions
            + MCPJobTools.definitions + MCPSharedProjectTools.definitions)
        #expect(MCPHelpTools.names.isDisjoint(with: others))
        #expect(MCPAppControlTools.names.isDisjoint(with: others))
        let exposed = MinuteMindMCPServer.exposedToolNames()
        #expect(Set(exposed).count == exposed.count, "a tool name is defined twice")
        #expect(MCPHelpTools.names.isSubset(of: exposed) && MCPAppControlTools.names.isSubset(of: exposed))
    }
}
