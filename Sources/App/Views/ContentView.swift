// Purpose: ContentView, the main window: the sidebar (Home's, or the open project's own) beside the
//          page of the current place, the Cmd+K project switcher over both, and the window-wide
//          sheets and alerts.
// Dependencies: Sources/App/Views/ProjectsSidebarView.swift (Home sidebar),
//               Sources/App/Views/ProjectContextSidebar.swift (project sidebar),
//               Sources/App/Views/HomeView.swift, Sources/App/Views/ProjectSwitcherView.swift,
//               Sources/App/Components/MainWindowEventMonitor.swift (mouse back and forward, Cmd+K),
//               Sources/App/ViewModels/AppViewModel+Navigation.swift (currentPlace, visits),
//               Sources/App/Components/TitlebarDragBlocker.swift (drags inside the title bar band)
// Used by: Sources/App/MinuteMindApp.swift (main window)
// Notes: The sidebar slides: Home's goes out to the left as a project's comes in from the right,
//        and back the other way; between two projects it crossfades (Reduce Motion: no slide).
//        It is clipped at its sides only, so its background reaches up under the traffic lights.
//        Every change of the current place is recorded here as a visit, whoever made it.
//        The page reaches up into the title bar band like the sidebar (the toolbar only holds the
//        system sidebar button, which sits over the sidebar). With the sidebar hidden in a
//        window the traffic lights and that button sit over the page, so it keeps the band then.
//        In the band macOS moves the window on drags over plain content, which keeps the window
//        draggable by headers and free space; views that need their drags opt out there.

import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var isFullScreen = false
    @State private var updateChecker = AppUpdateChecker.shared
    @State private var switcher = ProjectSwitcherModel()
    @State private var eventMonitor = MainWindowEventMonitor()

    /// Full screen hides the toolbar's sidebar button; the page then offers its own way back.
    private var showsSidebarCornerButton: Bool {
        isFullScreen && sidebarVisibility == .detailOnly
    }

    /// The page reaches up under the title bar while the sidebar holds the traffic lights and
    /// the sidebar button, and in full screen, where the toolbar slides away. With the sidebar
    /// hidden in a window they sit over the page, so it keeps the band free for them.
    private var pageReachesTitleBar: Bool {
        isFullScreen || sidebarVisibility != .detailOnly
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        Group {
            // The first-launch setup takes the whole window until it is done (OnboardingFlow).
            if !OnboardingFlow.shared.isPrepared {
                Color.clear
            } else if OnboardingFlow.shared.isActive {
                OnboardingView()
                    .environment(viewModel)
            } else {
                splitView
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(WindowFullScreenReader(isFullScreen: $isFullScreen))
        // No toolbar band of its own: in full screen it was a dark bar above the page.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear {
            OnboardingFlow.shared.prepare(for: viewModel)
            viewModel.runOnboardingLaunchWork()
        }
        .task {
            await viewModel.loadSessions()
        }
        // Lets the desktop companion open the Claude windows from outside any view.
        .onAppear { viewModel.openWindowAction = openWindow }
        .onChange(of: viewModel.selectedMinutesSession) { _, newSession in
            if let session = newSession {
                openWindow(id: "meeting-minutes", value: session.id)
                // Reset, or pressing Summary again for the same session is no change and the
                // closed window never reopens.
                viewModel.selectedMinutesSession = nil
            }
        }
        .alert("Issue", isPresented: bindingForError()) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = viewModel.errorMessage {
                Text(message)
            }
        }
        .sheet(isPresented: $viewModel.showTodoBriefSheet) {
            if let brief = viewModel.pendingTodoBrief {
                TodoBriefSheetView(isPresented: $viewModel.showTodoBriefSheet, brief: brief)
                    .environment(viewModel)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("Brief no longer available")
                        .font(.headline)
                    Text("The task brief has expired. It will regenerate at the next scheduled reminder time.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Close") { viewModel.showTodoBriefSheet = false }
                        .padding(.top, 4)
                }
                .padding(32)
                .frame(width: 360)
            }
        }
        // A newer release, offered only while nothing records or processes (AppUpdateChecker).
        .onAppear {
            let model = self.viewModel
            AppUpdateChecker.shared.start { [weak model] in
                guard let model else { return true }
                return model.updateBlockedReason != nil || OnboardingFlow.shared.isActive
            }
        }
        .sheet(isPresented: updateSheetBinding()) {
            if let release = updateChecker.offeredRelease {
                AppUpdateSheet(release: release, checker: updateChecker)
            }
        }
        .alert("Recording Consent Required", isPresented: $viewModel.showTeamsConsentInfo) {
            Button("I Understand", role: .cancel) {}
        } message: {
            Text(
                "Before recording any call, always ask all participants for their consent.\n\nRecording without consent may violate privacy laws and company policies."
            )
        }
    }

    /// The app itself: sidebar and the selected page.
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar
                .environment(viewModel)
                .environment(\.fullScreenSidebarControl, FullScreenSidebarControl(
                    isFullScreen: isFullScreen,
                    hideSidebar: { withAnimation { sidebarVisibility = .detailOnly } }
                ))
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 360)
        } detail: {
            Group {
                if viewModel.isShowingInbox {
                    InboxView()
                        .environment(viewModel)
                } else if viewModel.isShowingClipboard {
                    DictationHistoryView()
                        .environment(viewModel)
                } else if viewModel.isShowingAllTasks {
                    AllTasksView()
                        .environment(viewModel)
                } else if viewModel.isShowingCalendar {
                    CalendarView()
                        .environment(viewModel)
                } else if viewModel.selectedProjectID == ProjectRepositoryService.generalProjectID {
                    GeneralWorkspaceView()
                        .environment(viewModel)
                } else if let project = viewModel.selectedProject {
                    ProjectDetailView(project: project)
                        .environment(viewModel)
                } else if viewModel.isShowingHome {
                    HomeView()
                        .environment(viewModel)
                } else {
                    AllTranscriptsView()
                        .environment(viewModel)
                }
            }
            // No empty toolbar band above the page: its top (tab strip, headers) sits beside the
            // traffic lights, like the sidebar. Views that take drags up there keep them with
            // excludedFromWindowDrag() (TitlebarDragBlocker).
            .ignoresSafeArea(.container, edges: pageReachesTitleBar ? .top : [])
            // The page background follows the theme (Studio: the window background, as before).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignSystem.Colors.surface)
            .overlay(alignment: .bottomLeading) {
                if showsSidebarCornerButton {
                    SidebarShowCornerButton { withAnimation { sidebarVisibility = .all } }
                }
            }
        }
        .overlay {
            if switcher.isShown {
                ProjectSwitcherView(model: switcher)
                    .environment(viewModel)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: switcher.isShown)
        .onChange(of: viewModel.currentPlace) { old, new in
            viewModel.recordNavigation(from: old, to: new)
        }
        .onAppear { eventMonitor.start(viewModel: viewModel, switcher: switcher) }
        .onDisappear { eventMonitor.stop() }
    }

    /// Home's sidebar, or the open project's own; they slide past each other.
    private var sidebar: some View {
        let projectID = viewModel.currentPlace.projectID
        return ZStack {
            if let projectID {
                // The inner stack crossfades between projects; the outer one slides in and out.
                ZStack {
                    ProjectContextSidebar(projectID: projectID)
                        .id(projectID)
                        .transition(.opacity)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            } else {
                ProjectsSidebarView()
                    .transition(reduceMotion ? .opacity : .move(edge: .leading))
            }
        }
        .clipShape(SidesOnlyClip())
        .animation(.smooth(duration: 0.3), value: projectID != nil)
        .animation(.easeOut(duration: 0.15), value: projectID)
    }

    /// Shown while the checker offers a release; closing it any other way counts as Later.
    private func updateSheetBinding() -> Binding<Bool> {
        Binding(
            get: { updateChecker.offeredRelease != nil },
            set: { shown in
                if !shown, updateChecker.offeredRelease != nil, !updateChecker.isUpdating {
                    updateChecker.later()
                }
            }
        )
    }

    /// Clips the sliding sidebars at their sides only. A plain clip also cut their backgrounds
    /// off at the top of the column's content, so the band under the traffic lights showed the
    /// bare sidebar material above the sidebar's own colour.
    private struct SidesOnlyClip: Shape {
        func path(in rect: CGRect) -> Path {
            Path(rect.insetBy(dx: 0, dy: -rect.height))
        }
    }

    private func bindingForError() -> Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.errorMessage = nil
                }
            }
        )
    }
}
