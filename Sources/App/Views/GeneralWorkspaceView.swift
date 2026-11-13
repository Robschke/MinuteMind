// Purpose: GeneralWorkspaceView, the detail for the sidebar's "General" entry: the workspace repo
//          for meetings processed without a project and the knowledge the agent keeps from them,
//          plus the Jobs that run in it.
// Dependencies: Sources/App/Views/ProjectWorkspaceView.swift (editor + Claude terminal),
//               Sources/App/Views/ScheduledJobsView.swift (Jobs tab),
//               Sources/App/Services/ProjectRepositoryService.swift (generalProject)
// RBAC: None.
// Dependents: Sources/App/Views/ContentView.swift
// Notes: General is not a real project (no tasks, board or notes), so it gets a one-line header and
//        only the Workspace and Jobs sections, chosen in the sidebar like a project's
//        (ProjectContextSidebar, AppViewModel+Navigation.swift).

import SwiftUI

struct GeneralWorkspaceView: View {
    @Environment(AppViewModel.self) private var viewModel
    private var selectedTab: ProjectTab { viewModel.projectTab(for: ProjectRepositoryService.generalProjectID) }

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
