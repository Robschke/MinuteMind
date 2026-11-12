// Purpose: AppearanceSettingsView, the "Appearance" tab in Settings: light/dark mode, the colour
//          theme, the editor for the Custom theme and saved profiles, and the desktop companion's
//          look.
// Dependencies: Sources/App/Supporting/ThemeStore.swift (active theme, mode, custom settings,
//               saved profiles), Sources/App/Config/AppTheme.swift (themes, ThemeColor,
//               CustomThemeSettings, SavedThemeProfile), Sources/App/Supporting/CompanionAppearance.swift
//               (size, colour), Sources/App/Supporting/CompanionController.swift (show / hide)
// Used by: Sources/App/Views/MeetingMinutesSettingsView.swift (Appearance tab)
// Notes: User decisions 2026-10-05: four built-in themes plus Custom; Custom starts from one of
//        them and overrides accent, background, card and border with a colour picker for light
//        and one for dark each. Text colours follow the background, speaker colours come from
//        the base theme. Every card previews its theme half light, half dark, so a theme can be
//        judged in both modes without switching. A click applies at once; nothing to save.
//        Saved profiles (user request 2026-10-13): "Save as Profile" stores the colours being
//        edited under a name; profiles sit between the built-in themes and the Custom draft,
//        are edited in place when selected (changes save at once, like Custom), and can be
//        renamed (name field, saved on Return or focus loss, or the card's context menu),
//        duplicated and deleted (with confirmation; the app falls back to the profile's base
//        theme). A bookmark marks profile cards; the Custom card says it is a draft.
//        Companion section (same day): show on the desktop, come to the pointer on a mouse
//        shake, avatar (blob, duck, dog, puppy, pug, three cats, lime; each
//        shown as a still preview at its size), size (2, 3 or 4 pt pixels) and colour (default or a
//        picked one) with a live preview.

import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var store = ThemeStore.shared
    @State private var naming: NamingRequest?
    @State private var profileToDelete: SavedThemeProfile?

    /// The text field sheet for saving or renaming a profile.
    private struct NamingRequest: Identifiable {
        let id = UUID()
        /// nil: save a new profile; otherwise rename this one.
        var renaming: UUID?
        var name: String
    }

    private var options: [AppTheme] {
        AppTheme.builtIn + store.profiles.map { $0.resolve() } + [store.custom.resolve()]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Appearance")
                        .font(.title3.weight(.semibold))
                    Text("Colours of the whole app. Menus, window frames and pickers stay native macOS.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Text("Mode")
                        .frame(width: 80, alignment: .leading)
                    Picker("Mode", selection: $store.appearanceMode) {
                        ForEach(ThemeStore.AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Theme")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 14, alignment: .top)],
                              alignment: .leading, spacing: 14) {
                        ForEach(options) { theme in
                            let profile = store.profiles.first { $0.themeID == theme.id }
                            ThemeCard(theme: theme, isSelected: store.themeID == theme.id) {
                                store.themeID = theme.id
                            }
                            .contextMenu {
                                if let profile {
                                    Button("Rename\u{2026}") { naming = NamingRequest(renaming: profile.id, name: profile.name) }
                                    Button("Duplicate\u{2026}") {
                                        store.themeID = profile.themeID
                                        naming = NamingRequest(name: store.nextProfileName())
                                    }
                                    Button("Delete\u{2026}", role: .destructive) { profileToDelete = profile }
                                } else if theme.id == AppTheme.customID {
                                    Button("Save as Profile\u{2026}") {
                                        store.themeID = AppTheme.customID
                                        naming = NamingRequest(name: store.nextProfileName())
                                    }
                                }
                            }
                        }
                    }
                }

                if store.themeID == AppTheme.customID || store.selectedProfile != nil {
                    CustomThemeEditor(
                        store: store,
                        saveAsProfile: { naming = NamingRequest(name: store.nextProfileName()) },
                        deleteProfile: { profileToDelete = store.selectedProfile })
                }

                CompanionAppearanceSection(companion: viewModel.companion)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $naming) { request in
            ProfileNameSheet(
                title: request.renaming == nil ? "Save as Profile" : "Rename Profile",
                action: request.renaming == nil ? "Save" : "Rename",
                name: request.name
            ) { name in
                if let id = request.renaming {
                    store.renameProfile(id, to: name)
                } else {
                    store.saveProfile(named: name)
                }
            }
        }
        .confirmationDialog(
            "Delete \u{201C}\(profileToDelete?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { profileToDelete != nil }, set: { if !$0 { profileToDelete = nil } }),
            presenting: profileToDelete
        ) { profile in
            Button("Delete Profile", role: .destructive) { store.deleteProfile(profile.id) }
        } message: { profile in
            let base = AppTheme.builtIn(id: profile.settings.baseID)?.name ?? AppTheme.studio.name
            Text("The profile is removed. If it is in use, the app switches to \(base), the theme it was based on.")
        }
    }
}

/// Asks for a profile name.
private struct ProfileNameSheet: View {
    let title: String
    let action: String
    @State var name: String
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        commit(name)
        dismiss()
    }
}

// MARK: - Theme card

private struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    ThemePreview(theme: theme, dark: false)
                    ThemePreview(theme: theme, dark: true)
                }
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: isSelected ? 2.5 : 0.5))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if theme.id.hasPrefix(SavedThemeProfile.idPrefix) {
                            // Marks a saved profile among the built-in themes.
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Saved profile")
                        }
                        Text(theme.name).font(.callout.weight(.semibold))
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(theme.mood)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A miniature page in one mode: background, a card with two text lines, an accent button and
/// four speaker dots.
private struct ThemePreview: View {
    let theme: AppTheme
    let dark: Bool

    private func c(_ color: ThemeColor) -> Color { Color(nsColor: ThemeColor.srgb(color.resolved(dark: dark))) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            c(theme.background)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(c(theme.textPrimary)).frame(width: 34, height: 4)
                RoundedRectangle(cornerRadius: 2).fill(c(theme.textSecondary)).frame(width: 50, height: 3)
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle().fill(c(theme.speakers[index % theme.speakers.count])).frame(width: 7, height: 7)
                    }
                }
                Capsule().fill(c(theme.accent)).frame(width: 30, height: 9)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6).fill(c(theme.card)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(c(theme.border), lineWidth: 1))
            .padding(10)
        }
    }
}

// MARK: - Custom theme editor

private struct CustomThemeEditor: View {
    @Bindable var store: ThemeStore
    let saveAsProfile: () -> Void
    let deleteProfile: () -> Void
    @State private var profileName = ""
    @FocusState private var nameFocused: Bool

    private enum Token: CaseIterable {
        case accent, background, card, border
        var label: String {
            switch self {
            case .accent: "Accent"
            case .background: "Background"
            case .card: "Cards"
            case .border: "Borders"
            }
        }
    }

    private var base: AppTheme { AppTheme.builtIn(id: store.editableSettings.baseID) ?? .studio }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let profile = store.selectedProfile {
                    // A saved profile: its name is edited in place, saved on Return or when the
                    // field loses focus (each keystroke would repaint the whole app).
                    TextField("Profile name", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .frame(width: 220)
                        .focused($nameFocused)
                        .onSubmit { commitName(profile) }
                        .onAppear { profileName = profile.name }
                        .onChange(of: profile.id) { _, _ in profileName = profile.name }
                        .onChange(of: nameFocused) { _, focused in if !focused { commitName(profile) } }
                } else {
                    Text("Custom Colours")
                        .font(.headline)
                }
                Spacer()
                Button(store.selectedProfile == nil ? "Save as Profile\u{2026}" : "Duplicate Profile\u{2026}", action: saveAsProfile)
                    .help(store.selectedProfile == nil
                        ? "Keep these colours as a theme of their own, next to the built-in ones"
                        : "Save a copy of this profile under a new name")
            }

            HStack(spacing: 12) {
                Text("Start from")
                    .frame(width: 80, alignment: .leading)
                Picker("Start from", selection: $store.editableSettings.baseID) {
                    ForEach(AppTheme.builtIn) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                Button("Reset Colours") {
                    store.editableSettings = CustomThemeSettings(baseID: store.editableSettings.baseID)
                }
                .disabled(store.editableSettings == CustomThemeSettings(baseID: store.editableSettings.baseID))
                .help("Use the colours of the theme you started from again")
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(width: 80, height: 1)
                    Text("Light").font(.caption).foregroundStyle(.secondary)
                    Text("Dark").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Token.allCases, id: \.self) { token in
                    GridRow {
                        Text(token.label)
                        ColorPicker(token.label, selection: binding(token, dark: false), supportsOpacity: false)
                            .labelsHidden()
                        ColorPicker(token.label, selection: binding(token, dark: true), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }

            Text("Text colours follow the background, so they stay readable. Speaker colours come from the theme you started from.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.selectedProfile != nil {
                // Apart from the save action, so it is not hit by accident.
                Button("Delete Profile\u{2026}", role: .destructive, action: deleteProfile)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    /// Saves the edited name; an empty field gets the stored name back.
    private func commitName(_ profile: SavedThemeProfile) {
        if profileName.trimmingCharacters(in: .whitespaces).isEmpty {
            profileName = profile.name
        } else {
            store.renameProfile(profile.id, to: profileName)
            profileName = store.selectedProfile?.name ?? profileName
        }
    }

    private func current(_ token: Token) -> ThemeColor {
        let custom = store.editableSettings
        switch token {
        case .accent: return custom.accent ?? base.accent
        case .background: return custom.background ?? base.background
        case .card: return custom.card ?? base.card
        case .border: return custom.border ?? base.border
        }
    }

    /// Edits one mode of one colour and keeps the other mode as it was.
    private func binding(_ token: Token, dark: Bool) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: ThemeColor.srgb(current(token).resolved(dark: dark))) },
            set: { newValue in
                let picked = ThemeColor.hex(of: NSColor(newValue))
                let old = current(token)
                let value = ThemeColor.hex(
                    light: dark ? old.resolved(dark: false) : picked,
                    dark: dark ? picked : old.resolved(dark: true))
                switch token {
                case .accent: store.editableSettings.accent = value
                case .background: store.editableSettings.background = value
                case .card: store.editableSettings.card = value
                case .border: store.editableSettings.border = value
                }
            })
    }
}

// MARK: - Companion

/// The desktop companion's look: shown or hidden, size, colour, with a live preview.
private struct CompanionAppearanceSection: View {
    let companion: CompanionController
    @State private var appearance = CompanionAppearance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Companion")
                .font(.headline)
            HStack(alignment: .top, spacing: 20) {
                // Live preview at the chosen size and colour.
                MascotCanvas(frame: AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: nil, avatar: appearance.avatar, animated: false)))
                    .frame(width: 64, height: 76)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    .accessibilityHidden(true)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Desktop").frame(width: 80, alignment: .leading)
                        Toggle("Show the companion", isOn: Binding(
                            get: { !companion.model.isHiddenByUser },
                            set: { companion.setHidden(!$0) }))
                    }
                    GridRow {
                        Text("Shake").frame(width: 80, alignment: .leading)
                        Toggle("Come to the pointer when I shake the mouse", isOn: $appearance.comesOnShake)
                            .disabled(companion.model.isHiddenByUser)
                    }
                    GridRow {
                        Text("Sharing").frame(width: 80, alignment: .leading)
                        Toggle("Show the companion in screen shares", isOn: $appearance.visibleInScreenShares)
                            .disabled(companion.model.isHiddenByUser)
                            .help("Others in a call see the creature while you share your screen. Its speech bubbles and the cards stay private.")
                    }
                    GridRow {
                        Text("Avatar").frame(width: 80, alignment: .leading)
                        // One row while it fits, two at large sizes or in a narrow window.
                        ViewThatFits(in: .horizontal) {
                            avatarRow(MascotAvatar.allCases)
                            VStack(alignment: .leading, spacing: 8) {
                                let half = (MascotAvatar.allCases.count + 1) / 2
                                avatarRow(Array(MascotAvatar.allCases.prefix(half)))
                                avatarRow(Array(MascotAvatar.allCases.dropFirst(half)))
                            }
                        }
                        .disabled(companion.model.isHiddenByUser)
                    }
                    GridRow {
                        Text("Size").frame(width: 80, alignment: .leading)
                        Picker("Size", selection: $appearance.size) {
                            ForEach(CompanionAppearance.Size.allCases) { size in
                                Text(size.label).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                        // Size and colour only matter while it shows; Show stays usable.
                        .disabled(companion.model.isHiddenByUser)
                    }
                    GridRow {
                        Text("Colour").frame(width: 80, alignment: .leading)
                        HStack(spacing: 10) {
                            Picker("Colour", selection: Binding(
                                get: { appearance.customColor != nil },
                                set: { own in appearance.customColor = own ? appearance.suggestedOwnColor : nil })) {
                                // Default: the theme's accent for the blob, the natural colour otherwise.
                                Text("Default").tag(false)
                                Text("Own Colour").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 240)
                            if appearance.customColor != nil {
                                ColorPicker("Companion colour", selection: Binding(
                                    get: { appearance.bodyColor },
                                    set: { appearance.customColor = ThemeColor.hex(of: NSColor($0)) }),
                                    supportsOpacity: false)
                                    .labelsHidden()
                            }
                        }
                        .disabled(companion.model.isHiddenByUser)
                    }
                }
            }
            Text("Default is the theme's accent for the blob and the natural colour for the others; an own colour paints the body only. Its cards take the same colour for their border.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

private extension CompanionAppearanceSection {
    func avatarRow(_ avatars: [MascotAvatar]) -> some View {
        HStack(spacing: 8) {
            ForEach(avatars) { avatar in
                AvatarChoice(avatar: avatar, isSelected: appearance.avatar == avatar) {
                    appearance.avatar = avatar
                }
            }
        }
    }
}

/// One creature in the avatar picker: a small still preview and its name.
private struct AvatarChoice: View {
    let avatar: MascotAvatar
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                MascotCanvas(
                    frame: AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: nil, avatar: avatar, animated: false)),
                    avatar: avatar)
                Text(avatar.name).font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isSelected ? 0.08 : 0.03)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(avatar.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
