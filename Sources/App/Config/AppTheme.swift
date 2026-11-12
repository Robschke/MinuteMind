// Purpose: AppTheme, the colour themes of the app: the four built-in themes (Studio, Ember,
//          Midnight, Voltage) and the user's Custom theme, each with light and dark values.
// Dependencies: AppKit (dynamic NSColor), SwiftUI
// Used by: Sources/App/Supporting/ThemeStore.swift (active theme, persistence),
//          Sources/App/Views/AppearanceSettingsView.swift (picker, custom editor),
//          Sources/App/Components/DesignSystem.swift (Colors read the active theme)
// Notes: User decisions 2026-10-05: four themes from the design review plus a Custom theme that
//        starts from one of them and overrides accent, background, card and border, each with
//        its own light and dark value. Studio uses the system's semantic colours, so it looks
//        exactly like the app did before themes. Custom derives its text colours from the
//        background's brightness, so text stays readable whatever background is picked.
//        Recording red stays red in every theme (status, not decoration).

import AppKit
import SwiftUI

/// One colour with a light and a dark value, or a system colour that adapts by itself.
enum ThemeColor: Codable, Equatable, Sendable {
    case hex(light: UInt32, dark: UInt32)
    case system(SystemColor)

    /// The system colours Studio is built from.
    enum SystemColor: String, Codable, Sendable {
        case accent, windowBackground, controlBackground, underPageBackground, separator,
             label, secondaryLabel, tertiaryLabel, green, orange, red
    }

    var nsColor: NSColor {
        switch self {
        case .system(let system):
            switch system {
            case .accent: return .controlAccentColor
            case .windowBackground: return .windowBackgroundColor
            case .controlBackground: return .controlBackgroundColor
            case .underPageBackground: return .underPageBackgroundColor
            case .separator: return .separatorColor
            case .label: return .labelColor
            case .secondaryLabel: return .secondaryLabelColor
            case .tertiaryLabel: return .tertiaryLabelColor
            case .green: return .systemGreen
            case .orange: return .systemOrange
            case .red: return .systemRed
            }
        case .hex(let light, let dark):
            return NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return Self.srgb(isDark ? dark : light)
            }
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// The concrete light or dark value, e.g. to seed a colour picker from a system colour.
    /// Translucent system colours (separator, secondary label) are composited over a typical
    /// light or dark background, so they come out as the colour you actually see.
    func resolved(dark: Bool) -> UInt32 {
        switch self {
        case .hex(let light, let darkValue): return dark ? darkValue : light
        case .system:
            var value: UInt32 = 0
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                value = Self.hex(of: nsColor, over: dark ? 0x1E1E1E : 0xFFFFFF)
            }
            return value
        }
    }

    static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// sRGB hex of a colour; a translucent colour is composited over `background`.
    static func hex(of color: NSColor, over background: UInt32 = 0xFFFFFF) -> UInt32 {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        let alpha = rgb.alphaComponent
        func channel(_ value: CGFloat, _ shift: UInt32) -> UInt32 {
            let base = CGFloat((background >> shift) & 0xFF) / 255
            let mixed = value * alpha + base * (1 - alpha)
            return UInt32((mixed * 255).rounded().clamped(to: 0...255))
        }
        return (channel(rgb.redComponent, 16) << 16) | (channel(rgb.greenComponent, 8) << 8)
            | channel(rgb.blueComponent, 0)
    }

    /// Relative luminance (WCAG) of a hex colour, 0 (black) to 1 (white).
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF)
            + 0.0722 * channel(hex & 0xFF)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// A complete set of colours for the app.
struct AppTheme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mood: String
    var accent: ThemeColor
    /// Page background behind the content.
    var background: ThemeColor
    /// Secondary panes (file tree, strips).
    var surface: ThemeColor
    /// Cards and raised panels.
    var card: ThemeColor
    var border: ThemeColor
    var textPrimary: ThemeColor
    var textSecondary: ThemeColor
    var textTertiary: ThemeColor
    var success: ThemeColor
    var warning: ThemeColor
    var danger: ThemeColor
    /// Eight speaker colours (SpeakerPalette slots).
    var speakers: [ThemeColor]

    static let customID = "custom"

    // MARK: - Built-in themes

    /// Stock macOS: the system's own colours, i.e. the app as it looked before themes.
    static let studio = AppTheme(
        id: "studio", name: "Studio", mood: "Stock macOS, crisp and neutral",
        accent: .system(.accent), background: .system(.windowBackground),
        surface: .system(.underPageBackground), card: .system(.controlBackground),
        border: .system(.separator), textPrimary: .system(.label),
        textSecondary: .system(.secondaryLabel), textTertiary: .system(.tertiaryLabel),
        success: .system(.green), warning: .system(.orange), danger: .system(.red),
        speakers: hexes([
            (0xC93C30, 0xFF7A6B), (0xA15C00, 0xFFB648), (0x2E8540, 0x5FD27A), (0x0B7F7B, 0x3FD3C9),
            (0x2563EB, 0x6EA2FF), (0x7C4DDB, 0xB49BFF), (0xC2307A, 0xFF7AB8), (0x9A5B34, 0xD9A07A),
        ]))

    static let ember = AppTheme(
        id: "ember", name: "Ember", mood: "Warm paper and terracotta",
        accent: .hex(light: 0xC2541C, dark: 0xFF8A4C), background: .hex(light: 0xFBF8F3, dark: 0x1C1916),
        surface: .hex(light: 0xF4EEE5, dark: 0x252019), card: .hex(light: 0xFFFDF9, dark: 0x2E2822),
        border: .hex(light: 0xE6DCCD, dark: 0x3D342B), textPrimary: .hex(light: 0x2B2118, dark: 0xF3EADF),
        textSecondary: .hex(light: 0x6F6050, dark: 0xB5A693), textTertiary: .hex(light: 0x9A8A76, dark: 0x7D6F60),
        success: .hex(light: 0x3F7D3A, dark: 0x7CC46F), warning: .hex(light: 0xA86A00, dark: 0xF2B544),
        danger: .hex(light: 0xB3261E, dark: 0xFF6B5E),
        speakers: hexes([
            (0xC2541C, 0xFF8A4C), (0x8A5A9E, 0xC79BDB), (0x2F7F72, 0x5CC3B0), (0xB07D10, 0xE8B84A),
            (0xA63D5A, 0xF08AA6), (0x4C6A9E, 0x8FB0E8), (0x5C7F2A, 0xA6CC6A), (0x8B5E3C, 0xD2A47A),
        ]))

    static let midnight = AppTheme(
        id: "midnight", name: "Midnight", mood: "Deep navy and cyan, made for long terminal sessions",
        accent: .hex(light: 0x0E7490, dark: 0x22D3EE), background: .hex(light: 0xF4F7FA, dark: 0x0B1220),
        surface: .hex(light: 0xEAF0F6, dark: 0x111A2B), card: .hex(light: 0xFFFFFF, dark: 0x18233A),
        border: .hex(light: 0xD3DDE8, dark: 0x24324D), textPrimary: .hex(light: 0x0F172A, dark: 0xE2E8F0),
        textSecondary: .hex(light: 0x475569, dark: 0x94A3B8), textTertiary: .hex(light: 0x7C8BA1, dark: 0x64748B),
        success: .hex(light: 0x047857, dark: 0x34D399), warning: .hex(light: 0xB45309, dark: 0xFBBF24),
        danger: .hex(light: 0xBE123C, dark: 0xFB7185),
        speakers: hexes([
            (0x0E7490, 0x22D3EE), (0x6D28D9, 0xA78BFA), (0x0369A1, 0x38BDF8), (0xC2410C, 0xFB923C),
            (0xBE185D, 0xF472B6), (0x4338CA, 0x818CF8), (0x15803D, 0x4ADE80), (0xA16207, 0xFACC15),
        ]))

    static let voltage = AppTheme(
        id: "voltage", name: "Voltage", mood: "Electric violet with lime signals",
        accent: .hex(light: 0x6D28D9, dark: 0xB794FF), background: .hex(light: 0xFFFFFF, dark: 0x0D0D12),
        surface: .hex(light: 0xF6F3FF, dark: 0x16141F), card: .hex(light: 0xFFFFFF, dark: 0x1F1C2B),
        border: .hex(light: 0xE4DCFA, dark: 0x2E2A40), textPrimary: .hex(light: 0x14101F, dark: 0xF4F1FF),
        textSecondary: .hex(light: 0x5B5470, dark: 0xA9A2C2), textTertiary: .hex(light: 0x8A83A3, dark: 0x6E6888),
        success: .hex(light: 0x16A34A, dark: 0xA3E635), warning: .hex(light: 0xD97706, dark: 0xFDE047),
        danger: .hex(light: 0xE11D48, dark: 0xFF4D8D),
        speakers: hexes([
            (0x7C3AED, 0xB794FF), (0xDB2777, 0xFF6EB4), (0x0891B2, 0x22E3FF), (0xEA580C, 0xFF9A3D),
            (0x65A30D, 0xB6F23A), (0x2563EB, 0x6EA2FF), (0xC026D3, 0xF07BFF), (0xCA8A04, 0xFFD23F),
        ]))

    static let builtIn: [AppTheme] = [studio, ember, midnight, voltage]

    static func builtIn(id: String) -> AppTheme? { builtIn.first { $0.id == id } }

    private static func hexes(_ pairs: [(UInt32, UInt32)]) -> [ThemeColor] {
        pairs.map { .hex(light: $0.0, dark: $0.1) }
    }
}

/// A custom theme the user saved under a name; several can exist next to the built-in themes.
struct SavedThemeProfile: Codable, Equatable, Identifiable, Sendable {
    static let idPrefix = "profile:"

    var id = UUID()
    var name: String
    var settings: CustomThemeSettings

    /// The theme ID ThemeStore selects it by.
    var themeID: String { Self.idPrefix + id.uuidString }

    func resolve() -> AppTheme { settings.resolve(id: themeID, name: name) }
}

/// The user's own theme: a built-in base with four colours replaced.
struct CustomThemeSettings: Codable, Equatable, Sendable {
    var baseID: String = AppTheme.studio.id
    var accent: ThemeColor?
    var background: ThemeColor?
    var card: ThemeColor?
    var border: ThemeColor?

    /// The finished theme. Text colours follow the background's brightness per mode once the
    /// background is overridden, so a dark background in light mode still gets light text.
    /// `id` and `name` are the Custom draft's unless a saved profile resolves itself.
    func resolve(id: String = AppTheme.customID, name: String = "Custom") -> AppTheme {
        var theme = AppTheme.builtIn(id: baseID) ?? .studio
        let mood = id == AppTheme.customID
            ? "Draft colours. Save as a profile to keep them."
            : "Saved theme, based on \(theme.name)"
        theme = AppTheme(
            id: id, name: name, mood: mood,
            accent: accent ?? theme.accent, background: background ?? theme.background,
            surface: theme.surface, card: card ?? theme.card, border: border ?? theme.border,
            textPrimary: theme.textPrimary, textSecondary: theme.textSecondary,
            textTertiary: theme.textTertiary, success: theme.success, warning: theme.warning,
            danger: theme.danger, speakers: theme.speakers)
        if let background {
            let light = background.resolved(dark: false)
            let dark = background.resolved(dark: true)
            theme.surface = .hex(light: Self.shift(light, by: -0.04), dark: Self.shift(dark, by: 0.04))
            theme.textPrimary = .hex(light: Self.text(on: light, level: 0), dark: Self.text(on: dark, level: 0))
            theme.textSecondary = .hex(light: Self.text(on: light, level: 1), dark: Self.text(on: dark, level: 1))
            theme.textTertiary = .hex(light: Self.text(on: light, level: 2), dark: Self.text(on: dark, level: 2))
        }
        return theme
    }

    /// Text for a background: dark ink on light backgrounds, light ink on dark ones.
    static func text(on background: UInt32, level: Int) -> UInt32 {
        let onLight: [UInt32] = [0x1D1D1F, 0x5E5E63, 0x86868B]
        let onDark: [UInt32] = [0xF5F5F7, 0xA9A9AE, 0x7C7C82]
        return (ThemeColor.luminance(background) > 0.4 ? onLight : onDark)[min(level, 2)]
    }

    /// Lightens (positive) or darkens (negative) a colour by mixing with white or black.
    static func shift(_ hex: UInt32, by amount: Double) -> UInt32 {
        let target: Double = amount >= 0 ? 255 : 0
        let t = abs(amount)
        func mix(_ value: UInt32) -> UInt32 { UInt32((Double(value) * (1 - t) + target * t).rounded()) }
        return (mix((hex >> 16) & 0xFF) << 16) | (mix((hex >> 8) & 0xFF) << 8) | mix(hex & 0xFF)
    }
}
