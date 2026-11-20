// Purpose: NewProjectSheet, the New Project sheet: create a project (name and companion) or join
//          a Shared Project. Opened from the Home sidebar (and Home's New Project tile through it)
//          and from the agent cockpit's "+" menu.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (createProject),
//               Sources/App/Views/SharedProjectSetupViews.swift (JoinSharedProjectForm),
//               Sources/App/Components/ProjectCompanionChooser.swift (creature tiles),
//               Sources/App/Supporting/CompanionCast.swift (firstFreeAvatar)
// Used by: Sources/App/Views/ProjectsSidebarView.swift, Sources/App/Views/AgentCockpitSidebar.swift
// Notes: The sheet only creates or joins; what happens next is the caller's (`onProject`): the
//        Home sidebar enters the project, the cockpit starts a Claude session in it and stays.
//        The companion is preset to the first creature no project and not the home companion
//        wears, each time the sheet opens.

import SwiftUI

struct NewProjectSheet: View {
    @Binding var isPresented: Bool
    /// Called with the project once it was created or joined, after the sheet closed.
    let onProject: (Project) -> Void
    @Environment(AppViewModel.self) private var viewModel

    @State private var name = ""
    @State private var companion: MascotAvatar?
    @State private var mode: Mode = .create
    @State private var isJoining = false

    private enum Mode: Hashable { case create, join }

    var body: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingXL) {
            Text("New Project")
                .font(DesignSystem.Typography.title2)

            Picker("", selection: $mode) {
                Text("Create new").tag(Mode.create)
                Text("Join shared").tag(Mode.join)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(isJoining)

            switch mode {
            case .create:
                createForm
            case .join:
                JoinSharedProjectForm(
                    onCancel: { isPresented = false },
                    onJoined: { project in
                        isPresented = false
                        onProject(project)
                    },
                    isJoining: $isJoining)
            }
        }
        .padding(DesignSystem.Dimensions.spacingXXXL)
        .frame(width: 380)
        .interactiveDismissDisabled(isJoining)
        .onAppear {
            mode = .create
            companion = firstFreeCompanion
        }
    }

    /// Name and companion.
    private var createForm: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingXL) {
            VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingS) {
                Text("PROJECT NAME")
                    .font(DesignSystem.Typography.caption2)
                    .tracking(0.6)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)

                TextField("Enter project name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignSystem.Typography.body)
            }

            companionChooser

            HStack(spacing: DesignSystem.Dimensions.spacingM) {
                Button("Cancel") {
                    isPresented = false
                    name = ""
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

                Spacer()

                Button("Create") {
                    let project = viewModel.createProject(name: name, companion: companion, enter: false)
                    isPresented = false
                    name = ""
                    if let project { onProject(project) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// The first creature no project and not the home companion wears.
    private var firstFreeCompanion: MascotAvatar? {
        CompanionCast.firstFreeAvatar(
            used: Set(viewModel.projects.compactMap(\.companionCreature)), homeAvatar: CompanionAppearance.shared.avatar)
    }

    /// The new project's creature, in its natural colour (an avatar colour is picked in the
    /// project settings).
    private var companionChooser: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingM) {
            Text("COMPANION")
                .font(DesignSystem.Typography.caption2)
                .tracking(0.6)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            ProjectCompanionChooser(selection: $companion)
        }
    }
}
