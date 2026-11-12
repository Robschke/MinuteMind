import SwiftUI
import UserNotifications

@main
struct MinuteMindApp: App {
    @State private var viewModel = AppViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // A fixed scene ID keeps the saved frame's key stable ("main-AppWindow-1"). Without it
        // SwiftUI derives the key from the view type, which contains a per-build address, so every
        // new build forgot the window size and opened at the minimum.
        WindowGroup(id: "main") {
            ContentView()
                .environment(viewModel)
                .themedWindow()
                .onAppear {
                    ThemeStore.shared.applyAppearance()
                    appDelegate.viewModel = viewModel
                    appDelegate.setupHotkeys(viewModel: viewModel)
                    // Only set notification delegate when running as proper app bundle
                    if Bundle.main.bundleIdentifier != nil {
                        UNUserNotificationCenter.current().delegate = appDelegate
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)
        .commands {
            // Import an existing audio file (Voice Memo, call export, …) as a transcript card.
            CommandGroup(after: .newItem) {
                Button("Import Audio\u{2026}") {
                    Task { await viewModel.importAudioFromPicker() }
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(viewModel.isImportingAudio)
            }

            // View > Show/Hide Sidebar (Ctrl+Cmd+S), also in full screen where the toolbar hides.
            SidebarCommands()

            // The one Settings window, also opened by the gear at the bottom of the sidebar.
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton()
            }

            // Dismissing the briefing hides it until tomorrow, so there has to be a way back to it.
            CommandGroup(after: .toolbar) {
                Button("Record Today\u{2019}s Meetings\u{2026}") {
                    appDelegate.showDailyBriefing()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            // The first-launch setup and tour, again, in the main window.
            CommandGroup(after: .help) {
                Button("Show Welcome Tour") {
                    OnboardingFlow.shared.showAgain()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .disabled(OnboardingFlow.shared.isActive)
            }

            // The desktop companion can be hidden from its own menu; this brings it back.
            CommandGroup(after: .windowArrangement) {
                Button(viewModel.companion.model.isHiddenByUser ? "Show Companion" : "Hide Companion") {
                    viewModel.companion.setHidden(!viewModel.companion.model.isHiddenByUser)
                }
            }
        }

        // Claude Code in the General workspace, opened by a click on the desktop companion.
        Window("Claude (General)", id: "claude-assistant") {
            ClaudeAssistantWindowView()
                .environment(viewModel)
                .themedWindow()
        }
        .defaultSize(width: 760, height: 620)

        // Claude tabs dragged out of a workspace or another Claude window (value: the window's
        // strip ID in WorkspaceTerminalStore).
        WindowGroup("Claude", id: "workspace-claude", for: UUID.self) { $groupID in
            if let groupID {
                WorkspaceClaudeWindowView(groupID: groupID)
                    .environment(viewModel)
                    .themedWindow()
            }
        }
        .defaultSize(width: 760, height: 620)

        Window("Settings", id: "settings") {
            MeetingMinutesSettingsView()
                .environment(viewModel)
                .padding()
                .frame(minWidth: 900, minHeight: 650)
                .themedWindow()
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)
        // Opened from the app menu's Settings… and the sidebar, not listed in the Window menu.
        .commandsRemoved()

        WindowGroup(id: "meeting-minutes", for: UUID.self) { $sessionID in
            if let id = sessionID {
                MeetingMinutesWindowView(sessionID: id)
                    .environment(viewModel)
                    .navigationTitle("Summary")
                    .themedWindow()
            } else {
                Text("Select a session")
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var viewModel: AppViewModel?
    private let hotkeyService = HotkeyService()
    private let taskCommanderController = TaskCommanderController()
    let liveDictationController = LiveDictationController()
    var liveDictationControllerRef: LiveDictationController { liveDictationController }
    private let quickDictationController = QuickDictationController()
    private let dailyBriefingPanel = DailyBriefingPanel()
    private let fullScreenToolbar = FullScreenToolbarAutoHide()
    private var hotkeysInstalled = false

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.projectStore.flushPendingSaves()
    }

    /// Whether this hold key is the one the user selected for quick dictation.
    private func isActiveHoldKey(_ key: HotkeyService.HoldKey) -> Bool {
        guard let settings = viewModel?.automationSettings, settings.quickDictationEnabled else {
            return false
        }
        switch settings.quickDictationMode {
        case "holdFn": return key == .fn
        // "hold" is the legacy value from before fn was offered.
        case "holdRightOption", "hold": return key == .rightOption
        default: return false
        }
    }

    /// Opens the daily briefing on demand, bypassing the once-a-day rule.
    func showDailyBriefing() {
        dailyBriefingPanel.showNow()
    }

    func setupHotkeys(viewModel: AppViewModel) {
        guard !hotkeysInstalled else { return }
        hotkeysInstalled = true

        fullScreenToolbar.start()
        taskCommanderController.configure(viewModel: viewModel)
        liveDictationController.configure(viewModel: viewModel)
        quickDictationController.configure(viewModel: viewModel)
        dailyBriefingPanel.configure(viewModel: viewModel)

        // Ask once a day, shortly after launch — the calendar needs a moment to authorise and the
        // question is pointless before we can read today's meetings.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.dailyBriefingPanel.showIfDue()
        }

        // Shift+Cmd+T → Task Commander
        hotkeyService.register(key: "t", modifiers: [.shift, .command]) { [weak self] in
            self?.taskCommanderController.toggle()
        }

        // Shift+Cmd+R → Start recording. When the meeting pill offers a detected meeting, this
        // records exactly that meeting (with its calendar data and project). It never stops a
        // recording (user decision 2026-10-08): the hotkey service watches keys in every app, so
        // Shift+Cmd+R pressed elsewhere (a hard reload in a browser) could end a meeting.
        hotkeyService.register(key: "r", modifiers: [.shift, .command]) { [weak self] in
            guard let vm = self?.viewModel else { return }
            Task { @MainActor in
                guard !vm.isRecording else {
                    vm.meetingPill.flashRecordingHint("Already recording")
                    return
                }
                if vm.meetingPill.hotkeyRecord() { return }
                await vm.startRecording()
            }
        }

        // Ctrl+Opt+P → Process the meeting the pill just saved.
        hotkeyService.register(key: "p", modifiers: [.control, .option]) { [weak self] in
            guard let vm = self?.viewModel else { return }
            Task { @MainActor in vm.meetingPill.hotkeyProcess() }
        }

        // Shift+Cmd+D → Live Dictation overlay
        hotkeyService.register(key: "d", modifiers: [.shift, .command]) { [weak self] in
            self?.liveDictationController.toggle()
        }

        // Ctrl+Opt+D → Quick dictation: speak, and the text lands at the cursor of whatever app
        // is frontmost. Held-key mode is registered separately below.
        hotkeyService.register(key: "d", modifiers: [.control, .option]) { [weak self] in
            guard let self, let vm = self.viewModel,
                vm.automationSettings.quickDictationEnabled,
                vm.automationSettings.quickDictationMode == "toggle"
            else { return }
            self.quickDictationController.toggle()
        }

        // Hold-to-dictate; with Control held too, the Claude quick action. Both keys are
        // registered; the setting decides which one is live, so switching modes needs no
        // re-registration.
        for holdKey in HotkeyService.HoldKey.allCases {
            hotkeyService.registerHold(
                holdKey,
                onDown: { [weak self] withControl in
                    guard let self, self.isActiveHoldKey(holdKey) else { return }
                    self.quickDictationController.pressBegan(withControl: withControl)
                },
                onUp: { [weak self] in
                    guard let self, self.isActiveHoldKey(holdKey) else { return }
                    self.quickDictationController.pressEnded()
                },
                onControl: { [weak self] in
                    guard let self, self.isActiveHoldKey(holdKey) else { return }
                    self.quickDictationController.controlPressed()
                })
        }

        hotkeyService.install()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        // Extract Sendable string values before crossing into the Task.
        let rawUserInfo = response.notification.request.content.userInfo
        let safeUserInfo: [String: String] = rawUserInfo.reduce(into: [:]) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                result[key] = value
            }
        }
        Task { @MainActor in
            await MainActor.run {
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.viewModel?.handleNotificationAction(
                        actionIdentifier, userInfo: safeUserInfo, category: category)
                }
            }
        }
        completionHandler()
    }

    // Show notifications even when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
