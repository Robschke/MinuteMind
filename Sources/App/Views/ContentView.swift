import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var isFullScreen = false

    /// Full screen hides the toolbar's sidebar button; the page then offers its own way back.
    private var showsSidebarCornerButton: Bool {
        isFullScreen && sidebarVisibility == .detailOnly
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
            ProjectsSidebarView()
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
                } else {
                    AllTranscriptsView()
                        .environment(viewModel)
                }
            }
            // The page background follows the theme (Studio: the window background, as before).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignSystem.Colors.surface)
            .environment(\.sidebarCornerButtonInset, showsSidebarCornerButton ? SidebarShowCornerButton.inset : 0)
            .overlay(alignment: .bottomLeading) {
                if showsSidebarCornerButton {
                    SidebarShowCornerButton { withAnimation { sidebarVisibility = .all } }
                }
            }
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
