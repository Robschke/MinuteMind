// Purpose: AgentCockpitSidebar, the sidebar while the agent cockpit is open: the way back Home and
//          the "+" menu in the header, then every space (project or General) with a running
//          Claude session, its sessions nested below it, and Settings at the bottom. It replaces
//          the Home sidebar (ProjectsSidebarView) for as long as the cockpit is shown.
// Dependencies: Sources/App/ViewModels/AppViewModel+Cockpit.swift (spaces, starting and showing
//               sessions, collapsed spaces), Sources/App/Components/AgentStatusCreatureView.swift
//               (creatures), Sources/App/Views/ProjectAgentsSection.swift (AgentSessionState),
//               Sources/App/Views/NewProjectSheet.swift, Sources/App/Views/ProjectContextSidebar.swift
//               (SidebarHoverButtonStyle), Sources/App/Components/OpenSettingsButton.swift
//               (SidebarSettingsRow), Sources/App/Components/FullScreenSidebarControls.swift
// Used by: Sources/App/Views/ContentView.swift, Sources/App/Views/AgentCockpitView.swift
//          (AgentCockpitAddMenu)
// Notes: Laid out like herdr: spaces with their agents nested, each space foldable. A space row
//        shows the project's creature with the state of all its sessions (as Home's tiles do), a
//        session row the creature in that session's state (as the project sidebar's Agents
//        section does); the creature is the only status sign. A folded space shows how many
//        agents it holds. The "+" on a space row shows on hover and starts an Opus session there
//        (right click: Sonnet). The header's "+" offers the spaces without a session and New
//        Project…, which creates the project and starts a session in it without leaving the
//        cockpit. A space leaves the list when its last Claude session closes.
//        Sessions in a torn-off window are listed with a window mark; a click brings that window
//        forward instead of moving the session into the cockpit.
//        Home's New Project request (`requestsNewProject`) is answered here while the cockpit
//        is open, so the empty cockpit page can offer New Project… too.

import SwiftUI

struct AgentCockpitSidebar: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.fullScreenSidebarControl) private var sidebarControl
    @State private var showingNewProjectSheet = false

    var body: some View {
        let spaces = viewModel.cockpitSpaceIDs
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                .padding(.top, DesignSystem.Dimensions.spacingS)

            if spaces.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingXS) {
                    Text("No agents running")
                        .font(DesignSystem.Typography.callout)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text("Start one in a project with +.")
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                .padding(.horizontal, DesignSystem.Dimensions.spacingL)
                .padding(.top, DesignSystem.Dimensions.spacingL)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: .space(2)) {
                        ForEach(spaces, id: \.self) { spaceID in
                            space(spaceID, first: spaceID == spaces.first)
                        }
                    }
                    .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                    .padding(.vertical, DesignSystem.Dimensions.spacingS)
                }
                .frame(maxHeight: .infinity)
            }

            HStack(spacing: .space(2)) {
                SidebarSettingsRow()
                if sidebarControl.isFullScreen {
                    SidebarHideButton(action: sidebarControl.hideSidebar)
                }
            }
            .padding(.horizontal, DesignSystem.Dimensions.spacingS)
            .padding(.vertical, DesignSystem.Dimensions.spacingS)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.card)
        .sheet(isPresented: $showingNewProjectSheet) {
            NewProjectSheet(isPresented: $showingNewProjectSheet) { project in
                viewModel.startCockpitSession(in: project.id)
            }
            .environment(viewModel)
        }
        .onChange(of: viewModel.requestsNewProject, initial: true) { _, requested in
            guard requested else { return }
            viewModel.requestsNewProject = false
            showingNewProjectSheet = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingXS) {
            Button {
                viewModel.go(to: .home)
            } label: {
                HStack(spacing: DesignSystem.Dimensions.spacingS) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.themed(size: 18))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 24, height: 32)
                    VStack(alignment: .leading, spacing: .space(1)) {
                        Text("Cockpit")
                            .font(.themed(size: 14, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: .space(2)) {
                            Image(systemName: "chevron.left")
                                .font(.themed(size: 9, weight: .semibold))
                            Text("Home")
                        }
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                .padding(.vertical, DesignSystem.Dimensions.spacingXS)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarHoverButtonStyle())
            .help("Back to Home")
            .accessibilityLabel("Cockpit, back to Home")

            Menu {
                AgentCockpitAddMenu()
            } label: {
                Image(systemName: "plus")
                    .font(.themed(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, DesignSystem.Dimensions.spacingS)
            .help("Add a space")
            .accessibilityLabel("Add a space")
        }
    }

    // MARK: - Spaces

    @ViewBuilder
    private func space(_ spaceID: UUID, first: Bool) -> some View {
        if let project = viewModel.cockpitProject(spaceID) {
            let sessions = viewModel.cockpitSessions(in: spaceID)
            let collapsed = viewModel.cockpitCollapsedIDs.contains(spaceID)
            let shown = viewModel.cockpitShownSpaceID == spaceID
            CockpitSpaceRow(
                project: project, sessions: sessions, isCollapsed: collapsed,
                isSelected: shown && collapsed)
            .padding(.top, first ? 0 : DesignSystem.Dimensions.spacingXS)
            if !collapsed {
                let focusedID = viewModel.workspaceTerminals.focusedID(in: spaceID)
                ForEach(sessions) { session in
                    CockpitAgentRow(
                        spaceID: spaceID, session: session,
                        isSelected: shown && session.id == focusedID)
                }
            }
        }
    }
}

/// The "+" menu's entries: the spaces without a running session, then New Project….
struct AgentCockpitAddMenu: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        let addable = viewModel.cockpitAddableIDs.compactMap { viewModel.cockpitProject($0) }
        ForEach(addable) { project in
            Button(project.name) { viewModel.startCockpitSession(in: project.id) }
        }
        if !addable.isEmpty { Divider() }
        Button("New Project…") { viewModel.requestsNewProject = true }
    }
}

/// A space: fold chevron, creature with the state of all its sessions, name, and on hover a
/// "+" that starts another session there.
private struct CockpitSpaceRow: View {
    let project: Project
    let sessions: [WorkspaceTerminalSession]
    let isCollapsed: Bool
    let isSelected: Bool
    @Environment(AppViewModel.self) private var viewModel
    @State private var isHovered = false

    private var canAdd: Bool { viewModel.workspaceTerminals.canAddSession(in: project.id) }

    var body: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingXS) {
            Button {
                viewModel.setCockpitSpaceCollapsed(project.id, !isCollapsed)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.themed(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(project.name)" : "Collapse \(project.name)")

            Button {
                viewModel.showCockpitSpace(project.id)
            } label: {
                HStack(spacing: DesignSystem.Dimensions.spacingS) {
                    AgentStatusCreatureView(projectID: project.id, sessions: sessions, pixelSize: 1)
                        .frame(width: 18)
                    Text(project.name)
                        .font(DesignSystem.Typography.callout.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isCollapsed {
                        Text("(\(sessions.count))")
                            .font(DesignSystem.Typography.caption1)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: .row(26))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(project.name)
            .accessibilityLabel(spaceLabel)

            Button {
                viewModel.startCockpitSession(in: project.id)
            } label: {
                Image(systemName: "plus")
                    .font(.themed(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .opacity(isHovered ? 1 : 0)
            .contextMenu {
                Button("New Opus Session") { viewModel.startCockpitSession(in: project.id, model: "opus") }
                Button("New Sonnet Session") { viewModel.startCockpitSession(in: project.id, model: "sonnet") }
            }
            .help(canAdd ? "New Claude session (right click for Sonnet)" : "\(WorkspaceTerminalStore.maxSessions) sessions is the limit")
            .accessibilityLabel("New Claude session in \(project.name)")
        }
        .padding(.leading, DesignSystem.Dimensions.spacingXS)
        .padding(.trailing, DesignSystem.Dimensions.spacingS)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.12)
                      : isHovered ? DesignSystem.Colors.textPrimary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    private var spaceLabel: String {
        let count = sessions.count == 1 ? "1 agent" : "\(sessions.count) agents"
        return "\(project.name), \(count)"
    }
}

/// A session of a space: the project's creature in the session's state and the session's name.
private struct CockpitAgentRow: View {
    let spaceID: UUID
    let session: WorkspaceTerminalSession
    let isSelected: Bool
    @Environment(AppViewModel.self) private var viewModel

    private var inWindow: Bool {
        let terminals = viewModel.workspaceTerminals
        guard let groupID = terminals.groupID(of: session) else { return false }
        return terminals.group(groupID)?.isWindow == true
    }

    var body: some View {
        let state = AgentSessionState(session.status, finishedUnseen: session.finishedUnseen)
        Button {
            viewModel.showCockpitSession(session)
        } label: {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                AgentStatusCreatureView(projectID: spaceID, sessions: [session], pixelSize: 1)
                    .frame(width: 18)
                Text(session.displayName)
                    .font(DesignSystem.Typography.callout)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: DesignSystem.Dimensions.spacingXS)
                if inWindow {
                    Image(systemName: "macwindow")
                        .font(.themed(size: 10))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .help("In its own window")
                }
            }
            // Indented under the space's creature (chevron column plus its gap).
            .padding(.leading, .space(28))
            .padding(.trailing, DesignSystem.Dimensions.spacingS)
            .frame(height: .row(26))
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarHoverButtonStyle())
        .help("\(session.displayName), \(state.label)")
        .accessibilityLabel("\(session.displayName), \(state.label)")
        .accessibilityHint(inWindow ? "Brings its window forward" : "Shows this session")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
