// Purpose: ThemeFile, the format of a theme Claude (or the user) writes as a JSON file: which
//          built-in it starts from, the colours it replaces, the style (font, corners, density,
//          terminal font), how it is checked, and how it turns into an AppTheme.
// Dependencies: Sources/App/Config/AppTheme.swift (AppTheme, ThemeColor, CustomThemeSettings
//               for derived text colours), Sources/App/Config/ThemeStyle.swift
// Used by: Sources/App/Supporting/ThemeFileStore.swift (reads and writes the files),
//          Sources/App/Supporting/ThemeStore.swift (resolves the active theme),
//          Sources/App/Services/MCP/MCPThemeTools.swift (save, get, preview),
//          Sources/App/Help/HelpGuideContent.swift (the format is documented there), Tests/ThemeFileTests.swift
// Notes: - Checking is strict: an unknown key, a colour that is not "#RRGGBB" or a value out of
//          range is an issue, so a typo never silently falls back to a default. A font that is
//          not installed is only a warning, since fonts can come and go after a theme is saved.
//        - A theme only lists what it changes; the rest comes from `base`. When it sets the
//          background but not the surface or text colours, those follow the background as in
//          the Custom theme, so a dark background never keeps dark text.
//        - The id is the file name without ".json". The `id` inside the file is only used when a
//          theme arrives over MCP; on disk the file name wins.

import Foundation

struct ThemeFile: Equatable, Sendable {
    static let formatVersion = 1
    static let idPrefix = "file:"
    /// The colour slots a theme can set, besides the eight speaker colours.
    static let colorKeys = [
        "accent", "background", "surface", "card", "border", "textPrimary", "textSecondary",
        "textTertiary", "success", "warning", "danger",
    ]
    static let speakerCount = 8

    var id: String
    var name: String
    var description: String?
    /// Built-in theme the unlisted colours come from.
    var base: String = AppTheme.studio.id
    /// Replaced colours by slot (`colorKeys`).
    var colors: [String: ThemeColor] = [:]
    /// All eight speaker colours, or nil to keep the base's.
    var speakers: [ThemeColor]?
    var style: ThemeStyle = .standard

    /// The id ThemeStore selects it by.
    var themeID: String { Self.idPrefix + id }

    /// The finished theme.
    func resolve() -> AppTheme {
        let base = AppTheme.builtIn(id: base) ?? .studio
        func color(_ key: String, _ fallback: ThemeColor) -> ThemeColor { colors[key] ?? fallback }
        var theme = AppTheme(
            id: themeID, name: name, mood: description ?? "Theme file, based on \(base.name)",
            accent: color("accent", base.accent), background: color("background", base.background),
            surface: color("surface", base.surface), card: color("card", base.card),
            border: color("border", base.border), textPrimary: color("textPrimary", base.textPrimary),
            textSecondary: color("textSecondary", base.textSecondary),
            textTertiary: color("textTertiary", base.textTertiary), success: color("success", base.success),
            warning: color("warning", base.warning), danger: color("danger", base.danger),
            speakers: speakers ?? base.speakers, style: style)
        if let background = colors["background"] {
            let light = background.resolved(dark: false)
            let dark = background.resolved(dark: true)
            if colors["surface"] == nil {
                theme.surface = .hex(
                    light: CustomThemeSettings.shift(light, by: -0.04), dark: CustomThemeSettings.shift(dark, by: 0.04))
            }
            for (level, key) in ["textPrimary", "textSecondary", "textTertiary"].enumerated() where colors[key] == nil {
                let derived = ThemeColor.hex(
                    light: CustomThemeSettings.text(on: light, level: level),
                    dark: CustomThemeSettings.text(on: dark, level: level))
                switch level {
                case 0: theme.textPrimary = derived
                case 1: theme.textSecondary = derived
                default: theme.textTertiary = derived
                }
            }
        }
        return theme
    }

    /// Every value of a theme written out explicitly, as a starting point for a new theme file.
    static func snapshot(of theme: AppTheme, id: String, name: String) -> ThemeFile {
        func hex(_ color: ThemeColor) -> ThemeColor {
            .hex(light: color.resolved(dark: false), dark: color.resolved(dark: true))
        }
        let all: [String: ThemeColor] = [
            "accent": theme.accent, "background": theme.background, "surface": theme.surface,
            "card": theme.card, "border": theme.border, "textPrimary": theme.textPrimary,
            "textSecondary": theme.textSecondary, "textTertiary": theme.textTertiary,
            "success": theme.success, "warning": theme.warning, "danger": theme.danger,
        ]
        let baseID = AppTheme.builtIn(id: theme.id)?.id ?? AppTheme.studio.id
        return ThemeFile(
            id: id, name: name, description: theme.mood, base: baseID,
            colors: all.mapValues(hex), speakers: theme.speakers.map(hex), style: theme.style)
    }

    // MARK: - Writing

    /// The file's JSON, keys in a stable order when serialised with `.sortedKeys`.
    var jsonObject: [String: Any] {
        var colorObject: [String: Any] = colors.mapValues(Self.json(of:))
        if let speakers { colorObject["speakers"] = speakers.map(Self.json(of:)) }
        var object: [String: Any] = [
            "formatVersion": Self.formatVersion,
            "id": id,
            "name": name,
            "base": base,
            "colors": colorObject,
            "font": ["family": style.fontFamily ?? NSNull(), "scale": style.fontScale] as [String: Any],
            "corners": style.corners.rawValue,
            "density": style.density.rawValue,
            "terminal": ["family": style.terminalFontFamily ?? NSNull(), "size": style.terminalFontSize] as [String: Any],
        ]
        if let description { object["description"] = description }
        return object
    }

    static func json(of color: ThemeColor) -> Any {
        let light = color.resolved(dark: false)
        let dark = color.resolved(dark: true)
        return light == dark ? hexString(light) : ["light": hexString(light), "dark": hexString(dark)]
    }

    static func hexString(_ value: UInt32) -> String { String(format: "#%06X", value) }
}

// MARK: - Reading and checking

enum ThemeFileValidator {
    struct Failure: LocalizedError, Equatable {
        let issues: [String]
        var errorDescription: String? {
            "The theme is not valid:\n" + issues.map { "- \($0)" }.joined(separator: "\n")
        }
    }

    private static let topLevelKeys: Set<String> = [
        "formatVersion", "id", "name", "description", "base", "colors", "font", "corners", "density", "terminal",
    ]

    /// Lowercase letters, digits and dashes, starting with a letter or digit, at most 40.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil
    }

    /// Reads and checks a theme. `fileID` (the file name) wins over an `id` inside the object.
    static func validated(_ object: [String: Any], fileID: String? = nil) throws -> ThemeFile {
        var issues: [String] = []
        for key in object.keys.sorted() where !topLevelKeys.contains(key) {
            issues.append("Unknown key \"\(key)\". Allowed: \(topLevelKeys.sorted().joined(separator: ", ")).")
        }
        if let version = object["formatVersion"] {
            if let number = version as? Int, number > ThemeFile.formatVersion {
                issues.append("formatVersion \(number) is newer than this MinuteMind understands (\(ThemeFile.formatVersion)).")
            } else if !(version is Int) {
                issues.append("formatVersion must be a whole number.")
            }
        }

        let id = fileID ?? (object["id"] as? String ?? "")
        if !isValidID(id) {
            issues.append("id \"\(id)\" must be 1 to 40 lowercase letters, digits or dashes, starting with a letter or digit.")
        }
        let name = (object["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 40 { issues.append("name must be 1 to 40 characters.") }
        var description: String?
        if let value = object["description"], !(value is NSNull) {
            if let text = value as? String { description = text } else { issues.append("description must be text.") }
        }
        var base = AppTheme.studio.id
        if let value = object["base"] {
            if let text = value as? String, AppTheme.builtIn(id: text) != nil {
                base = text
            } else {
                issues.append("base must be one of \(AppTheme.builtIn.map { "\"\($0.id)\"" }.joined(separator: ", ")).")
            }
        }

        var colors: [String: ThemeColor] = [:]
        var speakers: [ThemeColor]?
        if let value = object["colors"] {
            if let colorObject = value as? [String: Any] {
                for (key, raw) in colorObject.sorted(by: { $0.key < $1.key }) {
                    if key == "speakers" {
                        if let list = raw as? [Any], list.count == ThemeFile.speakerCount {
                            let parsed = list.enumerated().map { index, item -> ThemeColor? in
                                let color = color(from: item)
                                if color == nil { issues.append("colors.speakers[\(index)]: \(colorFormat)") }
                                return color
                            }
                            if parsed.allSatisfy({ $0 != nil }) { speakers = parsed.compactMap { $0 } }
                        } else {
                            issues.append("colors.speakers must list exactly \(ThemeFile.speakerCount) colours.")
                        }
                    } else if ThemeFile.colorKeys.contains(key) {
                        if let color = color(from: raw) { colors[key] = color } else { issues.append("colors.\(key): \(colorFormat)") }
                    } else {
                        issues.append("Unknown colour \"\(key)\". Allowed: \(ThemeFile.colorKeys.joined(separator: ", ")), speakers.")
                    }
                }
            } else {
                issues.append("colors must be an object.")
            }
        }

        var style = ThemeStyle.standard
        if let value = object["font"] {
            if let font = value as? [String: Any] {
                for key in font.keys.sorted() where !["family", "scale"].contains(key) {
                    issues.append("Unknown key font.\(key). Allowed: family, scale.")
                }
                style.fontFamily = family(font["family"], path: "font.family", issues: &issues)
                if let raw = font["scale"] {
                    if let scale = number(raw), ThemeStyle.fontScaleRange.contains(scale) {
                        style.fontScale = scale
                    } else {
                        issues.append("font.scale must be a number from \(ThemeStyle.fontScaleRange.lowerBound) to \(ThemeStyle.fontScaleRange.upperBound).")
                    }
                }
            } else {
                issues.append("font must be an object with family and scale.")
            }
        }
        if let value = object["corners"] {
            if let text = value as? String, let corners = ThemeStyle.Corners(rawValue: text) {
                style.corners = corners
            } else {
                issues.append("corners must be one of \(ThemeStyle.Corners.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")).")
            }
        }
        if let value = object["density"] {
            if let text = value as? String, let density = ThemeStyle.Density(rawValue: text) {
                style.density = density
            } else {
                issues.append("density must be one of \(ThemeStyle.Density.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")).")
            }
        }
        if let value = object["terminal"] {
            if let terminal = value as? [String: Any] {
                for key in terminal.keys.sorted() where !["family", "size"].contains(key) {
                    issues.append("Unknown key terminal.\(key). Allowed: family, size.")
                }
                style.terminalFontFamily = family(terminal["family"], path: "terminal.family", issues: &issues)
                if let raw = terminal["size"] {
                    if let size = number(raw), ThemeStyle.terminalSizeRange.contains(size) {
                        style.terminalFontSize = size
                    } else {
                        issues.append("terminal.size must be a number from \(Int(ThemeStyle.terminalSizeRange.lowerBound)) to \(Int(ThemeStyle.terminalSizeRange.upperBound)).")
                    }
                }
            } else {
                issues.append("terminal must be an object with family and size.")
            }
        }

        guard issues.isEmpty else { throw Failure(issues: issues) }
        return ThemeFile(
            id: id, name: name, description: description, base: base, colors: colors,
            speakers: speakers, style: style)
    }

    /// Things worth fixing that do not stop the theme from working: fonts that are not
    /// installed (the system font is used instead) and text that is hard to read on the page
    /// (`background`) or on raised panels (`card`, where most text sits).
    static func warnings(for file: ThemeFile, installedFamilies: Set<String>) -> [String] {
        var warnings: [String] = []
        let lowercased = Set(installedFamilies.map { $0.lowercased() })
        for (path, family) in [("font.family", file.style.fontFamily), ("terminal.family", file.style.terminalFontFamily)] {
            if let family, !lowercased.contains(family.lowercased()) {
                warnings.append("\(path) \"\(family)\" is not installed on this Mac; the system font is used until it is (list_fonts shows what is).")
            }
        }
        let theme = file.resolve()
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for (surfaceName, surface) in [("background", theme.background), ("card", theme.card)] {
                for (name, color, minimum) in [
                    ("textPrimary", theme.textPrimary, 4.5), ("textSecondary", theme.textSecondary, 3.0),
                ] {
                    let ratio = contrast(color.resolved(dark: dark), surface.resolved(dark: dark))
                    if ratio < minimum {
                        warnings.append("In \(mode) mode \(name) on \(surfaceName) has a contrast of \(String(format: "%.1f", ratio)):1, below \(minimum):1, so text is hard to read.")
                    }
                }
            }
        }
        return warnings
    }

    /// WCAG contrast ratio of two colours.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let first = ThemeColor.luminance(a), second = ThemeColor.luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static let colorFormat = "a colour is \"#RRGGBB\" for both modes, or {\"light\": \"#RRGGBB\", \"dark\": \"#RRGGBB\"}."

    static func color(from value: Any) -> ThemeColor? {
        if let text = value as? String, let hex = hex(text) { return .hex(light: hex, dark: hex) }
        if let pair = value as? [String: Any], pair.count == 2,
           let light = (pair["light"] as? String).flatMap(hex), let dark = (pair["dark"] as? String).flatMap(hex) {
            return .hex(light: light, dark: dark)
        }
        return nil
    }

    static func hex(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }

    private static func number(_ value: Any) -> Double? {
        if value is Bool { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    /// A family name, or nil for the system font (missing, null or empty).
    private static func family(_ value: Any?, path: String, issues: inout [String]) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else {
            issues.append("\(path) must be a font family name, or null for the system font.")
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
