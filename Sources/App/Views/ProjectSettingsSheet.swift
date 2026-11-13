// Purpose: Per-project settings sheet: the project's name, its companion creature and that
//          creature's avatar colour, and the export folder where transcripts and AI summaries
//          are filed (<folder>/<yyyy-MM-dd>/<meeting name>/), or the explicit opt-out from
//          export. One of the two is required to record into this project (enforced by
//          AppViewModel.recordingStartBlockReason()).
// Dependencies: Sources/App/Models/Project.swift (name, companionAvatar, avatarColorHex,
//               exportFolderPath / exportOptOut),
//               Sources/App/ViewModels/AppViewModel.swift (renameProject, setProjectCompanion,
//               setProjectAvatarColor, updateProjectExportSettings),
//               Sources/App/Components/ProjectCompanionChooser.swift (creature tiles),
//               Sources/App/Components/ProjectAvatarView.swift (ProjectCreatureMark preview)
// Used by: Sources/App/Views/ContentView.swift ("Edit Project…" from a right click in the
//          sidebars and the switcher, AppViewModel.editingProjectID),
//          Sources/App/Views/ProjectDetailView.swift (ellipsis menu, "Project Settings…"),
//          Sources/App/Views/AllTranscriptsView.swift ("Set Up…")
// Notes: The app is not sandboxed, so a plain folder path is stored, no security-scoped
//        bookmarks needed. The avatar colour follows the home companion's colour control in
//        Settings, Appearance: Default (the creature's natural colour, the theme's accent for
//        the Blob) or Own Colour with the system colour panel (wheel, sliders, hex). It paints
//        the body only. Nothing is stored until Save.

import AppKit
import SwiftUI

struct ProjectSettingsSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var name: String
    @State private var companion: MascotAvatar?
    @State private var avatarColorHex: String?
    @State private var folderPath: String
    @State private var exportOptOut: Bool

    init(project: Project) {
        self.project = project
        _name = State(initialValue: project.name)
        _companion = State(initialValue: project.companionCreature)
        _avatarColorHex = State(initialValue: project.avatarColorHex)
        _folderPath = State(initialValue: project.exportFolderPath ?? "")
        _exportOptOut = State(initialValue: project.exportOptOut == true)
    }

    /// The project as it would be saved, for the preview.
    private var draft: Project {
        var draft = project
        draft.companionAvatar = companion?.rawValue
        draft.avatarColorHex = avatarColorHex
        return draft
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                let look = AppViewModel.projectAvatar(of: draft)
                ProjectCreatureMark(avatar: look.avatar, color: look.color, pixelSize: 2)
                Text("Project Settings")
                    .font(.title3.bold())
                Spacer()
            }

            identitySection

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcript & Summary Export")
                    .font(.headline)
                Text(
                    "New transcripts and summaries are filed into this folder as "
                        + "“\(dayFolderExample)/<meeting name>/”. Re-runs create new versions "
                        + "instead of overwriting."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("No folder selected", text: $folderPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(exportOptOut)
                    Button("Choose…") { chooseFolder() }
                        .disabled(exportOptOut)
                    if !folderPath.isEmpty {
                        Button {
                            folderPath = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear folder")
                        .disabled(exportOptOut)
                    }
                }

                Toggle("Don't export files for this project", isOn: $exportOptOut)
                    .padding(.top, 4)

                if !exportOptOut && folderPath.isEmpty {
                    Label(
                        "Recordings can't be started for this project until a folder is set (or export is disabled).",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    // MARK: - Name, companion, avatar colour

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.headline)
                TextField("Project name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Companion")
                    .font(.headline)
                ProjectCompanionChooser(selection: $companion, avatarColorHex: avatarColorHex, projectID: project.id)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Avatar Colour")
                    .font(.headline)
                HStack(spacing: 10) {
                    Picker("Avatar colour", selection: Binding(
                        get: { avatarColorHex != nil },
                        set: { own in avatarColorHex = own ? suggestedOwnColor : nil })) {
                        Text("Default").tag(false)
                        Text("Own Colour").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    if let hex = avatarColorHex {
                        ColorPicker("Avatar colour", selection: Binding(
                            get: { Color(hex: hex) },
                            set: { avatarColorHex = Self.hexString(of: $0) }),
                            supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                Text("Default is the creature's natural colour (the theme's accent for the Blob); an own colour paints the body only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The colour shown when switching to Own Colour: the creature's current one turned a third of
    /// the way round the colour wheel, so the switch visibly does something (as the companion's
    /// own colour in Settings, Appearance).
    private var suggestedOwnColor: String {
        let current = NSColor(AppViewModel.projectAvatar(of: draft).color).usingColorSpace(.sRGB) ?? .systemBlue
        let rotated = NSColor(hue: (current.hueComponent + 0.33).truncatingRemainder(dividingBy: 1),
                              saturation: max(current.saturationComponent, 0.5),
                              brightness: max(current.brightnessComponent, 0.6), alpha: 1)
        return Self.hexString(of: Color(nsColor: rotated))
    }

    static func hexString(of color: Color) -> String {
        String(format: "#%06X", ThemeColor.hex(of: NSColor(color)))
    }

    private func save() {
        if trimmedName != project.name { viewModel.renameProject(project, newName: trimmedName) }
        if companion != project.companionCreature { viewModel.setProjectCompanion(project, companion) }
        if avatarColorHex != project.avatarColorHex { viewModel.setProjectAvatarColor(project, avatarColorHex) }
        viewModel.updateProjectExportSettings(project, folderPath: folderPath, optOut: exportOptOut)
    }

    private var dayFolderExample: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if !folderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}
