// Purpose: ProjectContextSidebar, the sidebar while a project (or General) is open: the project's
//          creature and name with the way back Home, its sections (Overview, Workspace, Jobs),
//          its agents (open Claude sessions), then its files with the branch row, and Settings
//          at the bottom. It replaces the Home sidebar (ProjectsSidebarView) for as long as the
//          project is shown.
// Dependencies: Sources/App/ViewModels/AppViewModel+Navigation.swift (go(to:), project sections),
//               Sources/App/Views/ProjectAgentsSection.swift (Agents),
//               Sources/App/Views/WorkspaceFileTreeView.swift (tree and branch row),
//               Sources/App/Supporting/WorkspaceEditorStore.swift (selection and the open file),
//               Sources/App/Components/ProjectAvatarView.swift (creature),
//               Sources/App/Components/OpenSettingsButton.swift (SidebarSettingsRow),
//               Sources/App/Components/FullScreenSidebarControls.swift (hide button in full screen)
// Used by: Sources/App/Views/ContentView.swift
// Notes: A click on a file opens it and switches to Workspace from any section. The tree shows
//        the open file selected only in Workspace; in Overview and Jobs the selection is cleared,
//        so a click on the open file itself still changes the selection and brings Workspace
//        back (the outline reports selection changes, not clicks).
//        The header goes Home; the mouse's back button goes to the previous place instead
//        (AppViewModel+Navigation.swift), and Cmd+K switches projects (ProjectSwitcherView).
//        The repo is ensured here as well as in the workspace, since the tree shows in every section.

import AppKit
import SwiftUI

struct ProjectContextSidebar: View {
    let projectID: UUID
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.fullScreenSidebarControl) private var sidebarControl
    /// Set once a file was opened in the editor; until then the tree explains how.
    @AppStorage("mm.workspaceEditorHintSeen") private var editorHintSeen = false

    private var project: Project? {
        if projectID == ProjectRepositoryService.generalProjectID { return ProjectRepositoryService.generalProject }
        return viewModel.projects.first { $0.id == projectID }
    }

    private var repo: URL { viewModel.projectRepositories.repoURL(for: projectID) }
    private var editor: WorkspaceEditorState { viewModel.workspaceEditors.state(for: projectID) }
    private var tab: ProjectTab { viewModel.projectTab(for: projectID) }

    private var selection: Binding<Set<URL>> {
        let editor = editor
        return Binding(get: { editor.selection }, set: { editor.selection = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let project {
                header(project)
                    .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                    .padding(.top, DesignSystem.Dimensions.spacingS)

                VStack(spacing: DesignSystem.Dimensions.spacingXS) {
                    ForEach(viewModel.projectTabs(of: projectID)) { section in
                        sectionRow(section)
                    }
                }
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                .padding(.top, DesignSystem.Dimensions.spacingS)

                ProjectAgentsSection(projectID: projectID)
                    .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                    .padding(.top, DesignSystem.Dimensions.spacingL)

                filesHeading
                    .padding(.horizontal, DesignSystem.Dimensions.spacingL)
                    .padding(.top, DesignSystem.Dimensions.spacingL)
                    .padding(.bottom, DesignSystem.Dimensions.spacingXS)

                WorkspaceFileTreeView(
                    project: project, terminals: viewModel.workspaceTerminals, repo: repo, selection: selection)
                    .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }

            HStack(spacing: 2) {
                SidebarSettingsRow()
                if sidebarControl.isFullScreen {
                    SidebarHideButton(action: sidebarControl.hideSidebar)
                }
            }
            .padding(.horizontal, DesignSystem.Dimensions.spacingS)
            .padding(.vertical, DesignSystem.Dimensions.spacingS)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: editor.selection) { _, urls in
            // A single click on a file opens it; multi-select (Shift/Cmd) opens nothing.
            guard urls.count == 1, let url = urls.first, editor.open(url) else { return }
            editorHintSeen = true
            if tab != .workspaces { viewModel.setProjectTab(.workspaces, for: projectID) }
        }
        .onChange(of: tab, initial: true) { _, section in
            syncSelection(to: section)
        }
        .task(id: projectID) {
            if let project, projectID != ProjectRepositoryService.generalProjectID {
                viewModel.projectRepositories.ensureRepository(for: project)
            }
        }
    }

    /// Workspace shows the open file selected; the other sections show no selection.
    private func syncSelection(to section: ProjectTab) {
        if section == .workspaces {
            if let url = editor.document?.url, editor.selection.isEmpty { editor.selection = [url] }
        } else if !editor.selection.isEmpty {
            editor.selection = []
        }
    }

    // MARK: - Parts

    private func header(_ project: Project) -> some View {
        Button {
            viewModel.go(to: .home)
        } label: {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                ProjectAvatarView(projectID: projectID, pixelSize: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Home")
                    }
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                Text("\u{2318}K")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .padding(.horizontal, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(DesignSystem.Colors.border, lineWidth: 1))
                    .help("Hold \u{2318} and press K to switch projects")
            }
            .padding(.horizontal, DesignSystem.Dimensions.spacingS)
            .padding(.vertical, DesignSystem.Dimensions.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarHoverButtonStyle())
        .contextMenu {
            if projectID != ProjectRepositoryService.generalProjectID {
                Button("Edit Project…") { viewModel.editingProjectID = projectID }
            }
        }
        .help("Back to Home")
        .accessibilityLabel("\(project.name), back to Home")
    }

    private func sectionRow(_ section: ProjectTab) -> some View {
        let selected = tab == section
        return Button {
            viewModel.setProjectTab(section, for: projectID)
        } label: {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Image(systemName: section.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(DesignSystem.Typography.callout)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, DesignSystem.Dimensions.spacingM)
            .padding(.vertical, DesignSystem.Dimensions.spacingS)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var filesHeading: some View {
        HStack {
            Text("Files")
                .font(DesignSystem.Typography.headline)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([repo])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        }
    }
}

/// A plain button that shades on hover, for the project header and the agent rows.
struct SidebarHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverShade(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct HoverShade<Label: View>: View {
        let label: Label
        let isPressed: Bool
        @State private var isHovered = false

        var body: some View {
            label
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                        .fill(isPressed
                              ? DesignSystem.Colors.textPrimary.opacity(0.1)
                              : isHovered ? DesignSystem.Colors.textPrimary.opacity(0.06) : Color.clear)
                )
                .onHover { isHovered = $0 }
        }
    }
}
