// Purpose: Per-project settings sheet — configures the export folder where transcripts
//          and AI summaries are filed (<folder>/<yyyy-MM-dd>/<meeting name>/), or the
//          explicit opt-out from export. One of the two is required to record into
//          this project (enforced by AppViewModel.recordingStartBlockReason()).
// Dependencies: Sources/App/Models/Project.swift (exportFolderPath / exportOptOut),
//               Sources/App/ViewModels/AppViewModel.swift (updateProjectExportSettings)
// Used by: Sources/App/Views/ProjectDetailView.swift (ellipsis menu → "Project Settings…")
// Notes: The app is not sandboxed, so a plain folder path is stored — no
//        security-scoped bookmarks needed.

import AppKit
import SwiftUI

struct ProjectSettingsSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var folderPath: String
    @State private var exportOptOut: Bool

    init(project: Project) {
        self.project = project
        _folderPath = State(initialValue: project.exportFolderPath ?? "")
        _exportOptOut = State(initialValue: project.exportOptOut == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hex: project.colorHex))
                    .frame(width: 12, height: 12)
                Text("Project Settings")
                    .font(.title3.bold())
                Spacer()
            }

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
                    viewModel.updateProjectExportSettings(
                        project, folderPath: folderPath, optOut: exportOptOut)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
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
