// Purpose: The small forms around becoming part of a Shared Project: the display name sheet
//          shown before "Make Shared Project…" when no name is set, and the "Join shared" form of
//          the New Project sheet (repo URL, the name when none is set, progress and errors).
// Dependencies: Sources/App/Models/SharedProject.swift (ContributorName),
//               Sources/App/ViewModels/AppViewModel+SharedSetup.swift (joinSharedProject),
//               Sources/App/Components/DesignSystem.swift (tokens)
// RBAC: None in the app; access to the repo is the git host's (the user's own git login).
// Used by: Sources/App/Views/ProjectsSidebarView.swift (context menu, New Project sheet),
//          Sources/App/Views/IntegrationsSettingsView.swift (ContributorNameText)
// Notes: Both forms follow the New Project sheet: caption-style section labels, rounded text
//        fields, Cancel on the left and the default action on the right. The name is stored
//        (ContributorName.current) only when the user continues or joins, never while typing.
//        While a join runs every input and Cancel are disabled: the clone keeps running anyway,
//        and a cancelled sheet would leave a project appearing later without explanation.

import SwiftUI

/// The one-line explanations of the display name, shared by every place that asks for it.
enum ContributorNameText {
    static let explanation = "Added to the folder names of what you publish and shown to the other members."
    static let settingsExplanation = "Added to the folder names of meetings and recordings you publish and shown to the other members. Changing it later keeps existing folder names."
}

/// A caption-style section label, as in the New Project sheet.
private struct SharedFormLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DesignSystem.Typography.caption2)
            .tracking(0.6)
            .foregroundStyle(DesignSystem.Colors.textTertiary)
    }
}

/// The name field with its label and explanation.
private struct ContributorNameField: View {
    @Binding var name: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingS) {
            SharedFormLabel(title: "YOUR NAME")
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(DesignSystem.Typography.body)
            Text(ContributorNameText.explanation)
                .font(DesignSystem.Typography.caption1)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Asks for the display name before a project is made shared. Continue stores it and hands over.
struct ContributorNameSheet: View {
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingXL) {
            Text("Your name for shared projects")
                .font(DesignSystem.Typography.title3)
            ContributorNameField(name: $name)
            HStack(spacing: DesignSystem.Dimensions.spacingM) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Continue") {
                    ContributorName.current = trimmed
                    dismiss()
                    onContinue()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(DesignSystem.Dimensions.spacingXXL)
        .frame(width: 360)
    }
}

/// The "Join shared" side of the New Project sheet.
struct JoinSharedProjectForm: View {
    let onCancel: () -> Void
    let onJoined: (Project) -> Void
    /// True while the clone runs (the sheet locks its mode switch meanwhile).
    @Binding var isJoining: Bool
    @Environment(AppViewModel.self) private var viewModel

    @State private var remoteURL = ""
    @State private var name = ""
    /// Decided once when the form appears, so the field does not vanish after a failed join
    /// that already stored the name.
    @State private var asksForName = ContributorName.current == nil
    @State private var errorMessage: String?

    private var trimmedURL: String { remoteURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canJoin: Bool { !isJoining && !trimmedURL.isEmpty && (!asksForName || !trimmedName.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingXL) {
            VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingS) {
                SharedFormLabel(title: "REPO URL")
                TextField("git@github.com:team/acme-workspace.git", text: $remoteURL)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignSystem.Typography.body)
                    .onSubmit { if canJoin { join() } }
            }
            if asksForName {
                ContributorNameField(name: $name)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: DesignSystem.Dimensions.spacingM) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Spacer()
                if isJoining {
                    ProgressView()
                        .controlSize(.small)
                    Text("Joining…")
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Button("Join", action: join)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canJoin)
            }
        }
        .disabled(isJoining)
    }

    private func join() {
        guard canJoin else { return }
        if asksForName { ContributorName.current = trimmedName }
        let url = trimmedURL
        errorMessage = nil
        isJoining = true
        Task {
            do {
                let project = try await viewModel.joinSharedProject(remoteURL: url)
                isJoining = false
                onJoined(project)
            } catch {
                isJoining = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
