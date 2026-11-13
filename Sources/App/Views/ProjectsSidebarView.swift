// Purpose: The Home sidebar: Home, Inbox, All Transcripts and the other destinations, then the
//          projects. A click on a project enters it, and ContentView swaps this sidebar for the
//          project's own (ProjectContextSidebar). Projects can be arranged: a long press makes
//          them wiggle, dragging reorders them.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (projects, reorderProjects, setProjectStarred),
//               Sources/App/Views/CompanionView.swift (StarredProjectMark, MascotCanvas),
//               Sources/App/Supporting/CompanionCast.swift (firstFreeAvatar for the New Project sheet),
//               Sources/App/Views/ProjectSidebarArranging.swift (order maths, wiggle),
//               Sources/App/Views/SharedProjectSetupViews.swift (name sheet, Join shared form),
//               Sources/App/Views/SharedProjectStatusViews.swift (SharedProjectMark),
//               Sources/App/ViewModels/AppViewModel+SharedSetup.swift (beginMakeShared)
// Used by: Sources/App/Views/ContentView.swift
//          (Home's New Project tile opens this sidebar's sheet through `requestsNewProject`)
// Notes: Project rows take one drag gesture with no minimum distance instead of a Button, so a
//        click, a long press and the drag after it are a single gesture: a press held still for
//        `longPressDelay` starts arranging and can be dragged on without letting go, as on the
//        Home Screen. A press dragged up or down straight away starts arranging too, the way
//        Finder and Mail sidebars reorder; a sideways one does nothing. The pressed row shades
//        and sinks over the long press, so a hold visibly builds even without haptics.
//        While arranging, clicks on rows do nothing; Done, Escape (only with the sidebar
//        focused: a window-wide Esc would take it from Claude's terminals), a click on the
//        empty list or going to another sidebar destination ends it. The order is saved on
//        every drop. A cancelled gesture never calls onEnded, so `gestureActive` cleans up.
//        No autoscroll yet: a row can only be dragged within the visible part of the list.
//        General is not a project and stays first, dimmed while arranging.
//        Right click stars or unstars a project (`setProjectStarred`); a starred row shows the
//        project's own creature in tiny, or the companion's avatar without one (StarredProjectMark) and the project leads the companion's
//        project wheel (user request 2026-10-28).
//        Shared Projects: a people mark after the name (orange dot and tooltip on a sync problem);
//        "Make Shared Project…" in the context menu asks for the display name first when none is
//        set; the New Project sheet switches between Create new and Join shared.

import SwiftUI

/// Sidebar view showing list of projects
struct ProjectsSidebarView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.fullScreenSidebarControl) private var sidebarControl
    @State private var showingNewProjectSheet = false
    @State private var newProjectName = ""
    @State private var selectedColor = Project.defaultColors[0]
    /// The new project's creature; preset to a free one each time the sheet opens.
    @State private var newProjectCompanion: MascotAvatar?
    @State private var newProjectMode: NewProjectMode = .create
    @State private var isJoiningSharedProject = false
    /// The project "Make Shared Project…" waits on while the display name is asked for.
    @State private var projectAwaitingName: Project?

    private enum NewProjectMode: Hashable { case create, join }

    /// Projects wiggle and can be dragged into a new order.
    @State private var isArranging = false
    /// The order while arranging, ahead of the saved one during a drag.
    @State private var arrangedIDs: [UUID] = []
    @State private var draggedID: UUID?
    @State private var dragStartIndex = 0
    @State private var dragTranslation: CGFloat = 0
    /// Row height plus the gap between rows, measured.
    @State private var rowPitch: CGFloat = 34
    /// The row under the current press, and what the press has turned into so far.
    @State private var pressedID: UUID?
    @State private var pressMoved = false
    @State private var longPressTask: Task<Void, Never>?
    /// True while a press is down; resets on its own when the system cancels the gesture.
    @GestureState private var gestureActive = false

    private static let longPressDelay: Duration = .milliseconds(450)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Home: the project tiles, where the window opens.
                Button {
                    viewModel.go(to: .home)
                } label: {
                    HStack(spacing: DesignSystem.Dimensions.spacingS) {
                        Image(systemName: "house")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 18)
                        Text("Home")
                            .font(DesignSystem.Typography.callout)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, DesignSystem.Dimensions.spacingM)
                    .padding(.vertical, DesignSystem.Dimensions.spacingS)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                            .fill(viewModel.currentPlace == .home ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                .padding(.top, DesignSystem.Dimensions.spacingM)

                // Inbox: meetings waiting to be processed. Right after Home, because it is where decisions wait.
                Button {
                    viewModel.go(to: .inbox)
                } label: {
                    let count = viewModel.inboxSessions.count
                    HStack(spacing: DesignSystem.Dimensions.spacingS) {
                        Image(systemName: count > 0 ? "tray.full" : "tray")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 18)
                        Text("Inbox")
                            .font(DesignSystem.Typography.callout)
                            .lineLimit(1)
                        Spacer()
                        if count > 0 {
                            Text("\(count)")
                                .font(DesignSystem.Typography.caption1.weight(.medium))
                                .foregroundStyle(DesignSystem.Colors.textTertiary)
                        }
                    }
                    .padding(.horizontal, DesignSystem.Dimensions.spacingM)
                    .padding(.vertical, DesignSystem.Dimensions.spacingS)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                            .fill(viewModel.isShowingInbox ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                .padding(.top, DesignSystem.Dimensions.spacingS)

                // All Transcripts option
                Button {
                    viewModel.go(to: .allTranscripts)
                } label: {
                    HStack(spacing: DesignSystem.Dimensions.spacingS) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 18)

                        Text("All Transcripts")
                            .font(DesignSystem.Typography.callout)
                            .lineLimit(1)

                        Spacer()

                        Text("\(viewModel.sessions.count)")
                            .font(DesignSystem.Typography.caption1.weight(.medium))
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                    .padding(.horizontal, DesignSystem.Dimensions.spacingM)
                    .padding(.vertical, DesignSystem.Dimensions.spacingS)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                            .fill(
                                viewModel.currentPlace == .allTranscripts
                                    ? Color.accentColor.opacity(0.12) : Color.clear
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                .padding(.top, DesignSystem.Dimensions.spacingS)

                // All Tasks option
                Button {
                    viewModel.go(to: .allTasks)
                } label: {
                    HStack(spacing: DesignSystem.Dimensions.spacingS) {
                        Image(systemName: "checklist")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 18)
                    
                        Text("All Tasks")
                            .font(DesignSystem.Typography.callout)
                            .lineLimit(1)
                    
                        Spacer()
                    
                        Text("\(viewModel.tasks.filter { !$0.isCompleted }.count)")
                            .font(DesignSystem.Typography.caption1.weight(.medium))
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                    .padding(.horizontal, DesignSystem.Dimensions.spacingM)
                    .padding(.vertical, DesignSystem.Dimensions.spacingS)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                            .fill(
                                viewModel.isShowingAllTasks
                                    ? Color.accentColor.opacity(0.12) : Color.clear
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                .padding(.top, DesignSystem.Dimensions.spacingS)

                // Calendar option
                Button {
                    viewModel.go(to: .calendar)
                } label: {
                    HStack(spacing: DesignSystem.Dimensions.spacingS) {
                        Image(systemName: "calendar")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 18)
                        Text("Calendar")
                            .font(DesignSystem.Typography.callout)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, DesignSystem.Dimensions.spacingM)
                    .padding(.vertical, DesignSystem.Dimensions.spacingS)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                            .fill(viewModel.isShowingCalendar ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                .padding(.top, DesignSystem.Dimensions.spacingS)

                // Clipboard: everything said through the dictation key (dictations and Claude tasks).
                Button {
                    viewModel.go(to: .clipboard)
                } label: {
                    HStack(spacing: DesignSystem.Dimensions.spacingS) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 18)
                        Text("Clipboard")
                            .font(DesignSystem.Typography.callout)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, DesignSystem.Dimensions.spacingM)
                    .padding(.vertical, DesignSystem.Dimensions.spacingS)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                            .fill(viewModel.isShowingClipboard ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                .padding(.top, DesignSystem.Dimensions.spacingS)

                // Transcription queue indicator
                if viewModel.transcriptionQueue.activeCount > 0 {
                    HStack(spacing: DesignSystem.Dimensions.spacingS) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)

                        Text("Transcribing")
                            .font(DesignSystem.Typography.caption1)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)

                        Spacer()

                        let pending = viewModel.transcriptionQueue.pendingCount
                        let total = pending + 1
                        Text(total > 1 ? "1/\(total)" : "")
                            .font(DesignSystem.Typography.caption2.monospacedDigit())
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                    .padding(.horizontal, DesignSystem.Dimensions.spacingM)
                    .padding(.vertical, DesignSystem.Dimensions.spacingXS)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                            .fill(Color.accentColor.opacity(0.06))
                    )
                    .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                    .padding(.top, DesignSystem.Dimensions.spacingS)
                }
            }

            // Header, no divider above it: the spacing alone separates it from the navigation.
            HStack {
                Text("Projects")
                    .font(DesignSystem.Typography.headline)
                if isArranging {
                    Text("Drag to reorder")
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if isArranging {
                    Button("Done") { stopArranging() }
                        .buttonStyle(.plain)
                        .font(DesignSystem.Typography.callout.weight(.semibold))
                        .foregroundStyle(DesignSystem.Colors.accent)
                        .help("Finish arranging")
                } else {
                    Button {
                        showingNewProjectSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(DesignSystem.Colors.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Create new project")
                }
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
            .contextMenu {
                if !isArranging, viewModel.projects.count > 1 {
                    Button("Arrange Projects") { startArranging() }
                }
            }
            .padding(.horizontal, DesignSystem.Dimensions.spacingL)
            .padding(.vertical, DesignSystem.Dimensions.spacingM)


            // Projects list
            if viewModel.projects.isEmpty {
                // General exists before the first project too.
                generalRow
                    .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                    .padding(.top, DesignSystem.Dimensions.spacingM)
                VStack(spacing: DesignSystem.Dimensions.spacingM) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                    
                    VStack(spacing: DesignSystem.Dimensions.spacingXS) {
                        Text("No projects yet")
                            .font(DesignSystem.Typography.callout.weight(.medium))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        
                        Text("Create a project to organize your recordings")
                            .font(DesignSystem.Typography.caption1)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSystem.Dimensions.spacingXXXL)
            } else {
                ScrollView {
                    LazyVStack(spacing: DesignSystem.Dimensions.spacingXS) {
                        generalRow
                        ForEach(Array(displayedProjects.enumerated()), id: \.element.id) { index, project in
                            projectRow(project, index: index)
                        }
                        // A click on the empty part of the list ends arranging.
                        if isArranging {
                            Color.clear
                                .frame(minHeight: 120)
                                .contentShape(Rectangle())
                                .onTapGesture { stopArranging() }
                        }
                    }
                    .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                    .padding(.top, DesignSystem.Dimensions.spacingM)
                    .animation(DesignSystem.Animation.quick, value: displayedProjects.map(\.id))
                }
            }

            Spacer(minLength: 0)

            // Settings from every page, pinned below the projects (no divider above it). In full
            // screen the toolbar hides, so the sidebar button sits beside it.
            HStack(spacing: 2) {
                SidebarSettingsRow()
                if sidebarControl.isFullScreen {
                    SidebarHideButton(action: sidebarControl.hideSidebar)
                }
            }
                .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                .padding(.vertical, DesignSystem.Dimensions.spacingS)
        }
        // Fills the whole column: the width limits live on the split view column (ContentView).
        // A fixed max width here left the translucent column showing beside the content when the
        // sidebar was dragged wider.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.card)
        .sheet(isPresented: $showingNewProjectSheet) {
            newProjectSheet
        }
        // Home's New Project tile.
        .onChange(of: viewModel.requestsNewProject) { _, requested in
            guard requested else { return }
            viewModel.requestsNewProject = false
            showingNewProjectSheet = true
        }
        .sheet(item: $projectAwaitingName) { project in
            ContributorNameSheet { viewModel.beginMakeShared(project) }
        }
        // Not a window-wide Esc shortcut: that would take Esc from Claude's terminals.
        .onExitCommand { if isArranging { stopArranging() } }
        // Going to another sidebar destination ends arranging.
        .onChange(of: navigationKey) { _, _ in
            if isArranging { stopArranging() }
        }
        // A cancelled gesture (window lost focus, a menu opened) never calls onEnded.
        .onChange(of: gestureActive) { _, active in
            guard !active, pressedID != nil else { return }
            resetPress()
            settleDrag()
        }
        .onChange(of: dragTargetIndex) { _, _ in
            guard draggedID != nil else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        .onChange(of: viewModel.projects.map(\.id)) { _, ids in
            // Projects added or deleted meanwhile join or leave the arrangement.
            guard isArranging, draggedID == nil else { return }
            arrangedIDs = arrangedIDs.filter(ids.contains) + ids.filter { !arrangedIDs.contains($0) }
        }
    }

    /// The General workspace: meetings processed without a project and their knowledge. Always
    /// first, never a real project, shown whether or not projects exist.
    private var generalRow: some View {
        Button {
            viewModel.enterProject(ProjectRepositoryService.generalProjectID)
        } label: {
            ProjectRowView(
                project: ProjectRepositoryService.generalProject,
                isSelected: viewModel.selectedProjectID == ProjectRepositoryService.generalProjectID,
                openTaskCount: 0,
                isArranging: false
            )
        }
        .buttonStyle(.plain)
        .disabled(isArranging)
        .opacity(isArranging ? 0.45 : 1)
    }

    // MARK: - Arranging

    /// Changes whenever the user goes to another destination.
    private var navigationKey: [String] {
        [
            viewModel.selectedProjectID?.uuidString ?? "",
            "\(viewModel.isShowingHome)\(viewModel.isShowingInbox)\(viewModel.isShowingAllTasks)\(viewModel.isShowingCalendar)\(viewModel.isShowingClipboard)"
        ]
    }

    /// The projects in the order shown: saved, arranged, or with the dragged row in its new slot.
    private var displayedProjects: [Project] {
        guard isArranging else { return viewModel.projects }
        var ids = arrangedIDs
        if let draggedID, let from = ids.firstIndex(of: draggedID) {
            ids = ProjectArrangement.moved(ids, from: from, to: dragTargetIndex)
        }
        let byID = Dictionary(uniqueKeysWithValues: viewModel.projects.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    private var dragTargetIndex: Int {
        ProjectArrangement.targetIndex(
            start: dragStartIndex, translation: dragTranslation, pitch: rowPitch, count: arrangedIDs.count)
    }

    private func projectRow(_ project: Project, index: Int) -> some View {
        let isDragged = draggedID == project.id
        return ProjectRowView(
            project: project,
            isSelected: viewModel.selectedProjectID == project.id,
            openTaskCount: viewModel.tasksForProject(project.id).filter { !$0.isCompleted }.count,
            mark: viewModel.companionMark(for: project),
            syncStatus: project.isShared ? viewModel.sharedSync.status(for: project.id) : nil,
            isArranging: isArranging,
            isLifted: isDragged,
            isPressed: pressedID == project.id && !isArranging && !pressMoved
        )
        .modifier(ArrangeWiggle(active: isArranging && !isDragged, seed: project.id.hashValue & 0xFFFF))
        // The dragged row follows the pointer; its slot already moved by whole rows.
        .offset(y: isDragged ? dragTranslation - CGFloat(dragTargetIndex - dragStartIndex) * rowPitch : 0)
        .zIndex(isDragged ? 1 : 0)
        .transaction { if isDragged { $0.animation = nil } }
        .background {
            if index == 0 {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { rowPitch = geometry.size.height + DesignSystem.Dimensions.spacingXS }
                        .onChange(of: geometry.size.height) { _, height in
                            rowPitch = height + DesignSystem.Dimensions.spacingXS
                        }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(pressGesture(for: project))
        .contextMenu {
            if project.isStarred == true {
                Button("Unstar") { viewModel.setProjectStarred(project, false) }
            } else {
                Button("Star") { viewModel.setProjectStarred(project, true) }
            }
            companionMenu(for: project)
            if !project.isShared, project.id != ProjectRepositoryService.generalProjectID {
                Button("Make Shared Project…") { makeShared(project) }
            }
            if !isArranging {
                Divider()
                Button("Arrange Projects") { startArranging() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select(project) }
        .accessibilityAction(named: "Move Up") { move(project, by: -1) }
        .accessibilityAction(named: "Move Down") { move(project, by: 1) }
    }

    /// Click, long press and drag in one gesture (see the file header).
    private func pressGesture(for project: Project) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                if pressedID != project.id {
                    pressedID = project.id
                    pressMoved = false
                    longPressTask?.cancel()
                    if !isArranging {
                        longPressTask = Task { @MainActor in
                            try? await Task.sleep(for: Self.longPressDelay)
                            guard !Task.isCancelled, pressedID == project.id, !pressMoved else { return }
                            startArranging()
                        }
                    }
                }
                let distance = hypot(value.translation.width, value.translation.height)
                // Dragged straight away, Finder style: arranging starts with the drag.
                if !isArranging, !pressMoved, abs(value.translation.height) > 4,
                   abs(value.translation.height) > abs(value.translation.width) {
                    longPressTask?.cancel()
                    startArranging()
                }
                if isArranging {
                    if draggedID == nil, distance > 3, let start = arrangedIDs.firstIndex(of: project.id) {
                        draggedID = project.id
                        dragStartIndex = start
                    }
                    if draggedID == project.id { dragTranslation = value.translation.height }
                } else if distance > 4 {
                    pressMoved = true
                    longPressTask?.cancel()
                }
            }
            .onEnded { _ in
                let wasPress = !isArranging && !pressMoved
                resetPress()
                if draggedID == project.id {
                    settleDrag()
                } else if wasPress {
                    select(project)
                }
            }
    }

    /// The creature that speaks for the project's Claude sessions beside the desktop companion.
    /// Avatars already in use are named, not blocked: CompanionCast draws a second one in the
    /// project's colour.
    private func companionMenu(for project: Project) -> some View {
        Menu("Companion") {
            Picker("Companion", selection: Binding(
                get: { project.companionCreature },
                set: { viewModel.setProjectCompanion(project, $0) }
            )) {
                Text("None").tag(MascotAvatar?.none)
                Divider()
                ForEach(MascotAvatar.allCases) { avatar in
                    Text(companionLabel(avatar, for: project)).tag(MascotAvatar?.some(avatar))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private func companionLabel(_ avatar: MascotAvatar, for project: Project) -> String {
        if avatar == CompanionAppearance.shared.avatar { return "\(avatar.name) (your companion)" }
        let others = viewModel.projects.filter { $0.id != project.id && $0.companionCreature == avatar }.map(\.name)
        return others.isEmpty ? avatar.name : "\(avatar.name) (used by \(others.joined(separator: ", ")))"
    }

    /// Asks for the display name first when none is set (it goes into published folder names).
    private func makeShared(_ project: Project) {
        if ContributorName.current == nil {
            projectAwaitingName = project
        } else {
            viewModel.beginMakeShared(project)
        }
    }

    /// Enters the project: the sidebar turns into its ProjectContextSidebar.
    private func select(_ project: Project) {
        viewModel.enterProject(project.id)
    }

    private func startArranging() {
        guard !isArranging else { return }
        arrangedIDs = viewModel.projects.map(\.id)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        withAnimation(DesignSystem.Animation.quick) { isArranging = true }
    }

    private func stopArranging() {
        resetPress()
        settleDrag()
        withAnimation(DesignSystem.Animation.quick) { isArranging = false }
    }

    private func resetPress() {
        longPressTask?.cancel()
        longPressTask = nil
        pressedID = nil
        pressMoved = false
    }

    /// Drops the dragged row into its slot, saving the order.
    private func settleDrag() {
        guard draggedID != nil else { return }
        let order = displayedProjects.map(\.id)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            arrangedIDs = order
            draggedID = nil
            dragTranslation = 0
        }
        viewModel.reorderProjects(order)
    }

    /// Keyboard and VoiceOver: one place up or down, saved at once.
    private func move(_ project: Project, by step: Int) {
        var ids = isArranging ? arrangedIDs : viewModel.projects.map(\.id)
        guard let from = ids.firstIndex(of: project.id) else { return }
        let to = min(max(from + step, 0), ids.count - 1)
        ids = ProjectArrangement.moved(ids, from: from, to: to)
        if isArranging { arrangedIDs = ids }
        viewModel.reorderProjects(ids)
    }

    private var newProjectSheet: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingXL) {
            Text("New Project")
                .font(DesignSystem.Typography.title2)

            Picker("", selection: $newProjectMode) {
                Text("Create new").tag(NewProjectMode.create)
                Text("Join shared").tag(NewProjectMode.join)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(isJoiningSharedProject)

            switch newProjectMode {
            case .create:
                createProjectForm
            case .join:
                JoinSharedProjectForm(
                    onCancel: { showingNewProjectSheet = false },
                    onJoined: { project in
                        showingNewProjectSheet = false
                        select(project)
                    },
                    isJoining: $isJoiningSharedProject)
            }
        }
        .padding(DesignSystem.Dimensions.spacingXXXL)
        .frame(width: 380)
        .interactiveDismissDisabled(isJoiningSharedProject)
        .onAppear {
            newProjectMode = .create
            newProjectCompanion = firstFreeCompanion
        }
    }

    /// Today's New Project form: name, colour, companion.
    private var createProjectForm: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingXL) {
            VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingS) {
                Text("PROJECT NAME")
                    .font(DesignSystem.Typography.caption2)
                    .tracking(0.6)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                
                TextField("Enter project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignSystem.Typography.body)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingM) {
                Text("COLOR")
                    .font(DesignSystem.Typography.caption2)
                    .tracking(0.6)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                
                HStack(spacing: DesignSystem.Dimensions.spacingM) {
                    ForEach(Project.defaultColors, id: \.self) { colorHex in
                        Button {
                            selectedColor = colorHex
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: colorHex))
                                    .frame(width: 32, height: 32)
                                
                                if selectedColor == colorHex {
                                    Circle()
                                        .strokeBorder(Color.white, lineWidth: 2)
                                        .frame(width: 32, height: 32)
                                        .shadow(color: .black.opacity(0.2), radius: 2)
                                    
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(selectedColor == colorHex ? 1.1 : 1.0)
                        .animation(DesignSystem.Animation.quick, value: selectedColor)
                    }
                }
            }

            companionChooser

            HStack(spacing: DesignSystem.Dimensions.spacingM) {
                Button("Cancel") {
                    showingNewProjectSheet = false
                    newProjectName = ""
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

                Spacer()

                Button("Create") {
                    viewModel.createProject(name: newProjectName, colorHex: selectedColor, companion: newProjectCompanion)
                    showingNewProjectSheet = false
                    newProjectName = ""
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// The first creature no project and not the home companion wears.
    private var firstFreeCompanion: MascotAvatar? {
        CompanionCast.firstFreeAvatar(
            used: Set(viewModel.projects.compactMap(\.companionCreature)), homeAvatar: CompanionAppearance.shared.avatar)
    }

    /// The new project's creature: None, then every avatar as a tile, drawn the way it will stand
    /// beside the companion (CompanionCast colours, with the chosen project colour).
    private var companionChooser: some View {
        let draft: Project = {
            var project = Project(name: newProjectName, colorHex: selectedColor)
            project.companionAvatar = newProjectCompanion?.rawValue
            return project
        }()
        return VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingM) {
            Text("COMPANION")
                .font(DesignSystem.Typography.caption2)
                .tracking(0.6)
                .foregroundStyle(DesignSystem.Colors.textTertiary)

            HStack(alignment: .top, spacing: DesignSystem.Dimensions.spacingS) {
                companionTile(nil, draft: draft) {
                    Text("None")
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(Self.companionTileSize), spacing: DesignSystem.Dimensions.spacingS), count: 5),
                    alignment: .leading, spacing: DesignSystem.Dimensions.spacingS
                ) {
                    ForEach(MascotAvatar.allCases) { avatar in
                        companionTile(avatar, draft: draft) {
                            MascotCanvas(
                                frame: AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: nil, avatar: avatar, animated: false)),
                                avatar: avatar, pixelSize: 2, bodyColor: tileColor(avatar, draft: draft))
                        }
                    }
                }
            }
        }
    }

    private static let companionTileSize: CGFloat = 40

    /// The colour `avatar` would have on the new project, which lands first in the sidebar.
    private func tileColor(_ avatar: MascotAvatar, draft: Project) -> Color? {
        var candidate = draft
        candidate.companionAvatar = avatar.rawValue
        return viewModel.companionMark(
            for: candidate, among: [candidate] + viewModel.projects.sorted(by: Project.isOrderedBefore)).color
    }

    private func companionTile(_ avatar: MascotAvatar?, draft: Project, @ViewBuilder content: () -> some View) -> some View {
        let isSelected = newProjectCompanion == avatar
        return Button {
            newProjectCompanion = avatar
        } label: {
            content()
                .frame(width: Self.companionTileSize, height: Self.companionTileSize)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? DesignSystem.Colors.accent.opacity(0.15) : Color.primary.opacity(0.04)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? DesignSystem.Colors.accent : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(avatar.map { companionLabel($0, for: draft) } ?? "No companion")
        .accessibilityLabel(avatar.map { companionLabel($0, for: draft) } ?? "No companion")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Individual project row in the sidebar. The parent decides how it is clicked.
private struct ProjectRowView: View {
    let project: Project
    let isSelected: Bool
    let openTaskCount: Int
    /// The starred mark's creature (the project's own, or nil for the home companion).
    var mark: (avatar: MascotAvatar?, color: Color?) = (nil, nil)
    /// Set for a Shared Project: shows the people mark (with a dot on a sync problem).
    var syncStatus: SharedSyncStatus?
    /// Arranging: a grabber replaces the task count and hover stays off.
    let isArranging: Bool
    /// Being dragged: raised above the others.
    var isLifted = false
    /// The mouse is down on it: shaded, and sinking a little while a long press builds.
    var isPressed = false

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingS) {
            Circle()
                .fill(Color(hex: project.colorHex))
                .frame(width: 10, height: 10)
                .shadow(color: Color(hex: project.colorHex).opacity(0.3), radius: 2)

            Text(project.name)
                .font(DesignSystem.Typography.callout)
                .lineLimit(1)

            if let syncStatus {
                SharedProjectMark(status: syncStatus)
            }

            if project.isStarred == true {
                StarredProjectMark(avatar: mark.avatar, bodyColor: mark.color)
            }

            Spacer()

            if isArranging {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .accessibilityHidden(true)
            } else {
                Text("\(openTaskCount)")
                    .font(DesignSystem.Typography.caption1.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingM)
        .padding(.vertical, DesignSystem.Dimensions.spacingS)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                .fill(
                    isLifted
                    ? DesignSystem.Colors.card
                    : isSelected
                    ? Color.accentColor.opacity(0.12)
                    : isPressed
                    ? DesignSystem.Colors.pressedOverlay
                    : (isHovering && !isArranging ? DesignSystem.Colors.hoverOverlay : Color.clear)
                )
                .shadow(color: .black.opacity(isLifted ? 0.18 : 0), radius: 6, y: 2)
        )
        .scaleEffect(isLifted ? 1.03 : (isPressed ? 0.98 : 1))
        .contentShape(Rectangle())
        .animation(DesignSystem.Animation.quick, value: isSelected)
        .animation(DesignSystem.Animation.quick, value: isLifted)
        // As long as the long press, so the row visibly sinks towards arranging.
        .animation(isPressed ? .easeIn(duration: 0.45) : DesignSystem.Animation.quick, value: isPressed)
        .animation(DesignSystem.Animation.quick, value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 3:  // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
