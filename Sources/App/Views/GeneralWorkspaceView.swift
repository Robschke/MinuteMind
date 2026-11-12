// Purpose: GeneralWorkspaceView, the detail for the sidebar's "General" entry: the workspace repo
//          for meetings processed without a project and the knowledge the agent keeps from them,
//          plus the Jobs that run in it.
// Dependencies: Sources/App/Views/ProjectWorkspaceView.swift (file tree + Claude terminal),
//               Sources/App/Views/ScheduledJobsView.swift (Jobs tab),
//               Sources/App/Services/ProjectRepositoryService.swift (generalProject)
// RBAC: None.
// Dependents: Sources/App/Views/ContentView.swift
// Notes: General is not a real project (no tasks, board or notes), so it gets a one-line header and
//        only the Workspace and Jobs tabs of ProjectDetailView, with the same switch. Requests for
//        a tab (a job notification, a run opened in the workspace) are honoured like on a project.

import SwiftUI

struct GeneralWorkspaceView: View {
    @Environment(AppViewModel.self) private var viewModel
    @SceneStorage("mm.generalTab") private var selectedTabRaw: String = ProjectTab.workspaces.rawValue

    private static let tabs: [ProjectTab] = [.workspaces, .jobs]

    private var selectedTab: ProjectTab {
        ProjectTab(rawValue: selectedTabRaw).flatMap { Self.tabs.contains($0) ? $0 : nil } ?? .workspaces
    }

    private var selectedTabBinding: Binding<ProjectTab> {
        Binding(get: { selectedTab }, set: { selectedTabRaw = $0.rawValue })
    }

    private func applyRequestedTab() {
        guard let tab = viewModel.requestedProjectTab else { return }
        if Self.tabs.contains(tab) { selectedTabRaw = tab.rawValue }
        viewModel.requestedProjectTab = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text("General")
                    .font(DesignSystem.Typography.title3)
                Text("Meetings processed without a project, and the knowledge kept from them")
                    .font(DesignSystem.Typography.footnote)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            // Same switch as on a project page, below the header.
            Picker("", selection: selectedTabBinding) {
                ForEach(Self.tabs) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .onAppear(perform: applyRequestedTab)
            .onChange(of: viewModel.requestedProjectTab) { _, _ in applyRequestedTab() }
            Divider()
            switch selectedTab {
            case .jobs:
                ScheduledJobsView(projectID: ProjectRepositoryService.generalProjectID)
            default:
                ProjectWorkspaceView(project: ProjectRepositoryService.generalProject, terminals: viewModel.workspaceTerminals)
            }
        }
    }
}
