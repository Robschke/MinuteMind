// Purpose: ThemeStore, the active colour theme and appearance mode, persisted and applied to the
//          whole app (SwiftUI views through DesignSystem.Colors, AppKit through a notification).
// Dependencies: Sources/App/Config/AppTheme.swift (themes, custom settings), AppKit (NSApp.appearance)
// Used by: Sources/App/Components/DesignSystem.swift (Colors), Sources/App/Components/SpeakerPalette.swift,
//          Sources/App/MinuteMindApp.swift (tint at every scene root),
//          Sources/App/Supporting/WorkspaceTerminalStore.swift (terminal colours, via notification),
//          Sources/App/Views/AppearanceSettingsView.swift (picker and custom editor)
// Notes: One shared @Observable instance: DesignSystem.Colors are computed properties that read
//        it, so every view that uses a token redraws when the theme changes, without threading an
//        environment value through the app. Colours are built once per change, not per access.
//        Keys: mm.theme (theme id), mm.themeCustom (JSON of CustomThemeSettings, the Custom draft),
//        mm.themeProfiles (JSON of saved custom themes, user request 2026-10-13: save the Custom
//        colours as named profiles, several of them, each deletable), mm.appearanceMode (system,
//        light, dark; applied through NSApp.appearance).

import AppKit
import Observation
import SwiftUI

extension Notification.Name {
    /// Posted after the theme or the appearance mode changed; AppKit views recolour themselves.
    static let minuteMindThemeChanged = Notification.Name("MinuteMindThemeChanged")
}

@Observable
@MainActor
final class ThemeStore {
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// The SwiftUI colours of the active theme, built once per change.
    struct Palette {
        let accent, background, surface, card, border: Color
        let textPrimary, textSecondary, textTertiary: Color
        let success, warning, danger: Color
        let speakers: [Color]

        init(_ theme: AppTheme) {
            accent = theme.accent.color
            background = theme.background.color
            surface = theme.surface.color
            card = theme.card.color
            border = theme.border.color
            textPrimary = theme.textPrimary.color
            textSecondary = theme.textSecondary.color
            textTertiary = theme.textTertiary.color
            success = theme.success.color
            warning = theme.warning.color
            danger = theme.danger.color
            speakers = theme.speakers.map(\.color)
        }
    }

    static let shared = ThemeStore()

    private let defaults: UserDefaults

    private(set) var theme: AppTheme
    private(set) var palette: Palette

    var themeID: String {
        didSet {
            defaults.set(themeID, forKey: "mm.theme")
            rebuild()
        }
    }

    var custom: CustomThemeSettings {
        didSet {
            if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: "mm.themeCustom") }
            if themeID == AppTheme.customID { rebuild() }
        }
    }

    /// Saved custom themes, in the order they were saved.
    private(set) var profiles: [SavedThemeProfile] {
        didSet {
            if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "mm.themeProfiles") }
            if themeID.hasPrefix(SavedThemeProfile.idPrefix) { rebuild() }
        }
    }

    /// The selected saved profile, if one is selected.
    var selectedProfile: SavedThemeProfile? { profiles.first { $0.themeID == themeID } }

    /// What the colour editor edits: the selected profile, or else the Custom draft.
    var editableSettings: CustomThemeSettings {
        get { selectedProfile?.settings ?? custom }
        set {
            if let index = profiles.firstIndex(where: { $0.themeID == themeID }) {
                profiles[index].settings = newValue
            } else {
                custom = newValue
            }
        }
    }

    /// Saves the colours being edited as a new profile and selects it. A name already in use gets
    /// a number ("Night 2").
    @discardableResult
    func saveProfile(named name: String) -> SavedThemeProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = SavedThemeProfile(name: trimmed.isEmpty ? nextProfileName() : uniqueName(trimmed), settings: editableSettings)
        profiles.append(profile)
        themeID = profile.themeID
        return profile
    }

    func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].name != trimmed else { return }
        profiles[index].name = uniqueName(trimmed, excluding: id)
    }

    /// Deletes a profile; when it was selected, the app switches to the theme it was based on
    /// (the closest look).
    func deleteProfile(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let removed = profiles.remove(at: index)
        if removed.themeID == themeID {
            themeID = AppTheme.builtIn(id: removed.settings.baseID)?.id ?? AppTheme.studio.id
        }
    }

    private func uniqueName(_ name: String, excluding id: UUID? = nil) -> String {
        let names = Set(profiles.filter { $0.id != id }.map(\.name))
        guard names.contains(name) else { return name }
        var number = 2
        while names.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    /// "My Theme 1", "My Theme 2", ...: the first number no profile uses.
    func nextProfileName() -> String {
        let names = Set(profiles.map(\.name))
        var number = 1
        while names.contains("My Theme \(number)") { number += 1 }
        return "My Theme \(number)"
    }

    var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "mm.appearanceMode")
            applyAppearance()
            NotificationCenter.default.post(name: .minuteMindThemeChanged, object: nil)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let id = defaults.string(forKey: "mm.theme") ?? AppTheme.studio.id
        let custom = defaults.data(forKey: "mm.themeCustom")
            .flatMap { try? JSONDecoder().decode(CustomThemeSettings.self, from: $0) } ?? CustomThemeSettings()
        let profiles = defaults.data(forKey: "mm.themeProfiles")
            .flatMap { try? JSONDecoder().decode([SavedThemeProfile].self, from: $0) } ?? []
        let theme = Self.resolve(id: id, custom: custom, profiles: profiles)
        self.themeID = id
        self.custom = custom
        self.profiles = profiles
        self.appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "mm.appearanceMode") ?? "") ?? .system
        self.theme = theme
        self.palette = Palette(theme)
    }

    /// Sets NSApp.appearance from the saved mode; call once at launch.
    func applyAppearance() {
        switch appearanceMode {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func rebuild() {
        theme = Self.resolve(id: themeID, custom: custom, profiles: profiles)
        palette = Palette(theme)
        NotificationCenter.default.post(name: .minuteMindThemeChanged, object: nil)
    }

    /// A deleted profile's ID falls back to Studio.
    private static func resolve(id: String, custom: CustomThemeSettings, profiles: [SavedThemeProfile]) -> AppTheme {
        if id == AppTheme.customID { return custom.resolve() }
        if let profile = profiles.first(where: { $0.themeID == id }) { return profile.resolve() }
        return AppTheme.builtIn(id: id) ?? .studio
    }
}

/// Applies the active theme to a window's content: control tint, accent colour and the base text
/// colour (secondary and tertiary text derive from it). With Studio these are the system's own.
private struct ThemedWindow: ViewModifier {
    func body(content: Content) -> some View {
        let palette = ThemeStore.shared.palette
        content
            .tint(palette.accent)
            .accentColor(palette.accent)
            .foregroundStyle(palette.textPrimary)
    }
}

extension View {
    /// Put on every scene's root view.
    func themedWindow() -> some View { modifier(ThemedWindow()) }
}
