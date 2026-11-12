// Purpose: AppSetting, one user-facing setting as Claude sees it over MCP: label, place in the
//          Settings window, what it does, its kind and options, how to read it and how to change
//          it through the object that owns it. Also parses the loose values MCP clients send.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (passed to read/write/options),
//               Sources/App/Help/HelpGuide.swift (helpTopic ids)
// Used by: Sources/App/Help/AppSettingsCatalog.swift (the entries),
//          Sources/App/Services/MCP/MCPHelpTools.swift (list_settings, update_setting)
// Notes: A setting changes through its owner (AutomationSettings, ThemeStore, CompanionController,
//        LaunchAtLogin, ...), never by writing UserDefaults behind the owner's back: several owners
//        read their value once and would not notice. `storageKeys` lists the UserDefaults keys an
//        entry covers, so AppSettingsCatalogTests can check that every key in the code is either
//        a catalog entry or listed as internal.

import Foundation

@MainActor
struct AppSetting {
    enum Kind: Equatable {
        case toggle
        /// One of `options`; values and labels are both accepted.
        case choice
        case text
        /// Times of day, written "09:00, 14:30"; "" for none.
        case timesOfDay
        /// "default" or a colour "#RRGGBB".
        case colour
    }

    struct Option: Equatable {
        let value: String
        let label: String
    }

    enum Value: Equatable {
        case bool(Bool)
        case string(String)

        var jsonValue: Any {
            switch self {
            case .bool(let flag): flag
            case .string(let text): text
            }
        }
    }

    enum ParseError: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            }
        }
    }

    /// Stable snake_case id used by list_settings and update_setting.
    let id: String
    /// The label in the Settings window.
    let title: String
    /// Where the user finds it, e.g. "Settings > Automation > Pipeline".
    let location: String
    /// What it does, for Claude to explain.
    let summary: String
    /// HelpGuide topic with the background.
    let helpTopic: String
    /// UserDefaults keys this entry covers (none for values macOS or a file holds).
    let storageKeys: [String]
    let kind: Kind
    /// Set when Claude may read but not change it, with the reason to pass on.
    var readOnlyReason: String? = nil
    /// Choices for `.choice`, computed from the app's state where they vary (microphones, themes).
    var options: (@MainActor (AppViewModel) -> [Option])? = nil
    let read: @MainActor (AppViewModel) -> Value
    /// Applies a parsed value; returns a note for the user when there is more to know.
    var write: (@MainActor (AppViewModel, Value) throws -> String?)? = nil

    var isWritable: Bool { readOnlyReason == nil && write != nil }

    /// The value a client sent, checked against the kind and, for a choice, `choices`
    /// (`options` evaluated by the caller).
    func parse(_ raw: Any, choices: [Option]) throws -> Value {
        switch kind {
        case .toggle:
            if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            switch Self.text(raw).lowercased() {
            case "true", "on", "yes", "1", "enabled": return .bool(true)
            case "false", "off", "no", "0", "disabled": return .bool(false)
            default: throw ParseError.invalid("\(id) is on or off: send true or false.")
            }
        case .choice:
            let wanted = Self.text(raw)
            if let match = Self.option(matching: wanted, in: choices) { return .string(match.value) }
            let list = choices.map { "\($0.value) (\($0.label))" }.joined(separator: ", ")
            throw ParseError.invalid("\(wanted) is not an option for \(id). Options: \(list).")
        case .text:
            guard raw is String else { throw ParseError.invalid("\(id) takes text.") }
            return .string(Self.text(raw))
        case .timesOfDay:
            let text = Self.text(raw)
            guard Self.timesOfDay(text) != nil else {
                throw ParseError.invalid("\(id) takes times like \"09:00, 14:30\", or \"\" for none.")
            }
            return .string(text)
        case .colour:
            let text = Self.text(raw)
            if text.lowercased() == "default" { return .string("default") }
            guard Self.hexColour(text) != nil else {
                throw ParseError.invalid("\(id) takes \"default\" or a colour like \"#FF8800\".")
            }
            return .string(text.uppercased().hasPrefix("#") ? text.uppercased() : "#" + text.uppercased())
        }
    }

    /// The option whose value matches exactly, else case-insensitively, else by its label.
    static func option(matching wanted: String, in choices: [Option]) -> Option? {
        if let exact = choices.first(where: { $0.value == wanted }) { return exact }
        let lower = wanted.lowercased()
        if let byValue = choices.first(where: { $0.value.lowercased() == lower }) { return byValue }
        return choices.first { $0.label.lowercased() == lower }
    }

    /// Text of a JSON scalar, numbers without a trailing ".0".
    static func text(_ raw: Any) -> String {
        if let string = raw as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = raw as? NSNumber {
            let double = number.doubleValue
            return double == double.rounded() ? String(Int(double)) : String(double)
        }
        return String(describing: raw)
    }

    /// "09:00, 14:30" as hour/minute pairs, sorted and without repeats; nil when malformed.
    static func timesOfDay(_ text: String) -> [DateComponents]? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init)
        var seen = Set<Int>()
        var result: [DateComponents] = []
        for part in parts {
            let pieces = part.split(separator: ":")
            guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            guard seen.insert(hour * 60 + minute).inserted else { continue }
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            result.append(components)
        }
        return result.sorted { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) < ($1.hour ?? 0) * 60 + ($1.minute ?? 0) }
    }

    static func timesOfDayText(_ times: [DateComponents]) -> String {
        times.map { String(format: "%02d:%02d", $0.hour ?? 0, $0.minute ?? 0) }.joined(separator: ", ")
    }

    /// "#RRGGBB" or "RRGGBB" as 0xRRGGBB.
    static func hexColour(_ text: String) -> UInt32? {
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(hex, radix: 16)
    }
}
