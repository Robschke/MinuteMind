// Purpose: AgentCockpitView, the agent cockpit's page: the shown space's Claude strip (tabs, splits,
//          drag and drop, as in the project's Workspace) without file tree or editor, so agents of
//          several projects can be worked with from one place. The space is picked in
//          AgentCockpitSidebar.
// Dependencies: Sources/App/Views/WorkspaceTerminalPane.swift (the strip),
//               Sources/App/ViewModels/AppViewModel+Cockpit.swift (shown space),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (sessions, windows),
//               Sources/App/Views/AgentCockpitSidebar.swift (AgentCockpitAddMenu)
// Used by: Sources/App/Views/ContentView.swift
// Notes: The strip is the project's own (key: project ID), the one its Workspace section shows, so
//        tabs, splits and focus are shared with it; only one of the two is on screen at a time.
//        No placement buttons (there is no file to place Claude beside). The pane is rebuilt per
//        space (`.id`), as the workspace is per project. While every session of the space sits
//        in torn-off windows the page says so and offers Show and Bring Back, like the
//        workspace's bar.

import SwiftUI

struct AgentCockpitView: View {
    @Environment(AppViewModel.self) private var viewModel

    private var terminals: WorkspaceTerminalStore { viewModel.workspaceTerminals }

    var body: some View {
        Group {
            if let spaceID = viewModel.cockpitShownSpaceID, let project = viewModel.cockpitProject(spaceID) {
                if terminals.sessions(for: spaceID).isEmpty {
                    inWindows(project)
                } else {
                    WorkspaceTerminalPane(project: project, terminals: terminals)
                        .id(spaceID)
                }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Nothing runs yet: how to start.
    private var empty: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingM) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 36))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text("No agents running")
                .font(DesignSystem.Typography.title3)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Start a Claude session in a project. Every running session of every project shows up here.")
                .font(DesignSystem.Typography.callout)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Menu {
                AgentCockpitAddMenu()
            } label: {
                Label("Start Agent", systemImage: "sparkle")
            }
            .menuStyle(.button)
            .fixedSize()
            .padding(.top, DesignSystem.Dimensions.spacingS)
        }
        .padding(DesignSystem.Dimensions.spacingXXXL)
    }

    /// The space's sessions are all in torn-off windows.
    private func inWindows(_ project: Project) -> some View {
        let windows = terminals.windows(rootedAt: project.id)
        return VStack(spacing: DesignSystem.Dimensions.spacingM) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 32))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text(windows.count == 1 ? "\(project.name)'s agents are in their own window" : "\(project.name)'s agents are in \(windows.count) windows")
                .font(DesignSystem.Typography.callout)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            HStack(spacing: DesignSystem.Dimensions.spacingM) {
                Button("Show") {
                    for window in windows { terminals.dropZoneView(for: window.id)?.window?.makeKeyAndOrderFront(nil) }
                }
                Button("Bring Back") { terminals.bringBack(rootID: project.id) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DesignSystem.Dimensions.spacingXXXL)
    }
}
