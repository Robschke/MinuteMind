// Purpose: AutomationSettingsView — Full "Automation" tab content for the Settings sheet.
//          Displays grouped sections: Startup (open at login), Auto-recording, Live and Quick
//          Dictation, Parakeet, Pipeline, Task Review Reminders, Reminders Sync.
// Dependencies: Sources/App/Config/AutomationSettings.swift (appViewModel.automationSettings),
//               Sources/App/Supporting/LaunchAtLogin.swift (Startup switch),
//               Sources/App/ViewModels/AppViewModel.swift (appViewModel.teamsCallDetectionEnabled)
// RBAC: None — user settings, no access control.
// Dependents: Sources/App/Views/MeetingMinutesSettingsView.swift (Automation tab)
// Notes: Notification permission is requested lazily when the user adds their first reminder time.
//        Reminder scheduling clears all mm.taskReview.* pending notifications and re-schedules
//        the full stored list on every add/delete, so cancellations are always consistent.
//        automationSettings is accessed via @EnvironmentObject AutomationSettings injected by
//        MeetingMinutesSettingsView, which calls .environmentObject(appViewModel.automationSettings).
//        This avoids going through AppViewModel.$automationSettings (which is a let constant and
//        produces read-only bindings).

import SwiftUI
import UserNotifications

struct AutomationSettingsView: View {
    @Environment(AppViewModel.self) var appViewModel
    /// Injected by MeetingMinutesSettingsView via .environmentObject(appViewModel.automationSettings).
    @EnvironmentObject var settings: AutomationSettings

    // MARK: - Local state

    /// Whether the "add reminder time" date picker row is expanded inline.
    @State private var isAddingReminder = false
    /// The pending time selection in the inline date picker (defaults to 9:00 AM).
    @State private var pendingReminderDate: Date = {
        var components = DateComponents()
        components.hour = 9
        components.minute = 0
        return Calendar.current.date(from: components) ?? Date()
    }()
    /// Shown when notification permission has been denied.
    @State private var showPermissionDeniedBanner = false
    @State private var isConfirmingParakeetDelete = false

    var body: some View {
        @Bindable var appViewModel = appViewModel
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                startupSection
                Divider()
                autoRecordingSection
                Divider()
                liveDictationSection
                Divider()
                quickDictationSection
                Divider()
                parakeetModelSection
                Divider()
                pipelineSection
                Divider()
                taskReviewRemindersSection
                Divider()
                remindersSyncSection
                Spacer(minLength: 20)
            }
            .padding(24)
        }
    }

    // MARK: - Section: Startup

    private var startupSection: some View {
        let launch = LaunchAtLogin.shared
        return GroupBox(label: sectionLabel("Startup", systemImage: "power")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Open MinuteMind at login",
                    isOn: Binding(get: { launch.isEnabled || launch.needsApproval }, set: { launch.setEnabled($0) })
                )
                Text("Jobs and meeting detection only run while the app is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if launch.needsApproval {
                    HStack(spacing: 6) {
                        Text("macOS waits for you to allow it in Login Items.")
                            .font(.caption)
                            .foregroundStyle(DesignSystem.Colors.warning)
                        Button("Open Login Items") { launch.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
                if let error = launch.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.error)
                }
            }
            .padding(.top, 8)
        }
        .onAppear { launch.refresh() }
    }

    // MARK: - Section 1: Auto-recording

    private var autoRecordingSection: some View {
        @Bindable var appViewModel = appViewModel
        return GroupBox(label: sectionLabel("Auto-recording", systemImage: "record.circle")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(
                    "Start recording automatically at event time",
                    isOn: $settings.autoStartEnabled
                )

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Ask \"Meeting over?\" after silence")
                        .font(.subheadline)
                    Picker("Ask after silence", selection: $settings.autoStopSilenceThreshold) {
                        Text("15 s").tag(15.0)
                        Text("30 s").tag(30.0)
                        Text("60 s").tag(60.0)
                        Text("120 s").tag(120.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Toggle(
                        "Also apply to manual recordings",
                        isOn: $settings.manualRecordingSilenceEnabled
                    )
                    Text("Ask for manually started recordings too. Recordings only stop when you stop them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Detect Microsoft Teams calls (best effort)",
                        isOn: $appViewModel.teamsCallDetectionEnabled
                    )
                    Text("Automatically starts recording when a call is active. When the call ends, the pill asks whether the meeting is over.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Section: Live Dictation

    private var liveDictationSection: some View {
        GroupBox(label: sectionLabel("Live Dictation", systemImage: "waveform")) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default language")
                        .font(.subheadline)
                    Picker("Default language", selection: $settings.liveDictationLanguage) {
                        Text("Auto-detect").tag("auto")
                        Text("English (US)").tag("en-US")
                        Text("Deutsch").tag("de-DE")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)

                    Text("Default language for all transcriptions — both normal recordings and live dictation (Shift+Cmd+D). You can still switch language during dictation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    private var quickDictationSection: some View {
        GroupBox(label: sectionLabel("Quick Dictation", systemImage: "mic.badge.plus")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Dictate into any app: press the shortcut, speak, and the text is inserted wherever your cursor is — no need to switch to MinuteMind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appViewModel.parakeetModelInstalled {
                    Label(
                        "Using Parakeet on-device — same engine as recordings",
                        systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label(
                        "Using Apple Speech. Install Parakeet below for noticeably better accuracy.",
                        systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Enable quick dictation", isOn: $settings.quickDictationEnabled)

                VStack(alignment: .leading, spacing: 6) {
                    Text("How to trigger it")
                        .font(.subheadline)
                    Picker("How to trigger it", selection: $settings.quickDictationMode) {
                        Text("Hold fn (🌐), release to insert").tag("holdFn")
                        Text("Hold the right ⌥ key, release to insert").tag("holdRightOption")
                        Text("Press ⌃⌥D to start, again to insert").tag("toggle")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(!settings.quickDictationEnabled)

                    if settings.quickDictationMode == "holdFn" {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("For the fn key to be free, set “Press 🌐 key to” to “Do Nothing” in Keyboard settings. Otherwise macOS also switches input source, opens the emoji picker, or starts its own dictation.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Open Keyboard Settings") {
                                if let url = URL(
                                    string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
                                ) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Dictation language")
                        .font(.subheadline)
                    Picker("Dictation language", selection: $settings.quickDictationLanguage) {
                        Text("Follow system language").tag("auto")
                        Text("German").tag("de-DE")
                        Text("English (US)").tag("en-US")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                    .disabled(!settings.quickDictationEnabled)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Double tap to record", isOn: $settings.quickRecordingEnabled)
                        .disabled(!settings.quickDictationEnabled || settings.quickDictationMode == "toggle")
                    Text(settings.quickDictationMode == "toggle"
                        ? "Needs a hold key (fn or right \u{2325})."
                        : "Tap twice to record, once more to stop. Assign a project on the card to file it under recordings/ in its workspace. Recordings started with the mouse stop only with the mouse.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if settings.quickDictationMode == "holdFn" {
                        Text("If macOS dictation starts too, set its shortcut away from \u{201C}Press \u{1F310} twice\u{201D} (Keyboard settings, Dictation).")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                ClaudeTaskSettingsView()

                Divider()

                accessibilityStatusRow
            }
            .padding(.top, 8)
        }
    }

    /// Quick dictation cannot deliver text without Accessibility permission, so its state is
    /// surfaced here rather than failing silently at the moment of use.
    @ViewBuilder
    private var accessibilityStatusRow: some View {
        if TextInsertionService.isTrusted {
            Label("Accessibility permission granted", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Accessibility permission required", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("macOS needs to allow MinuteMind to type into other apps. Without it, dictated text is copied to the clipboard instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Request Permission…") {
                        TextInsertionService.requestPermission()
                    }
                    .controlSize(.small)
                    Button("Open System Settings") {
                        if let url = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var speakerDiarizationSection: some View {
        let store = appViewModel.speakerDiarizationModels
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Identify speakers (Speaker 1, 2, …)", isOn: $settings.speakerDiarizationEnabled)
                .onChange(of: settings.speakerDiarizationEnabled) { _, isOn in
                    // Enabling the feature should make it work — fetch the models it needs rather
                    // than leaving the user with a switch that does nothing.
                    guard isOn, !store.isInstalled, !store.isDownloading else { return }
                    Task { await store.downloadModels() }
                }
            Text("Splits the meeting audio into separate speakers using on-device CoreML models (Neural Engine), labeling them Speaker 1, Speaker 2, … Currently applies to Apple transcription on macOS 26. Download the models once below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Picker("Engine", selection: $settings.diarizationEngine) {
                    Text("Standard").tag("fluidAudio")
                    Text("Nemotron 3 (NVIDIA)").tag("nemotron3")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .disabled(!settings.speakerDiarizationEnabled)
                .onChange(of: settings.diarizationEngine) { _, engine in
                    // Choosing Nemotron should make it work right away, like the toggle above.
                    guard engine == "nemotron3", !store.isNemotronInstalled, !store.isDownloadingNemotron else { return }
                    Task { await store.downloadNemotronModels() }
                }
                Text("Nemotron 3 separates up to 8 speakers and is markedly more accurate in NVIDIA's and FluidAudio's benchmarks. It is new, so the standard engine stays the default. Speaker names you taught MinuteMind work with both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.diarizationEngine == "nemotron3" {
                    if store.isDownloadingNemotron {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(store.nemotronStatusMessage ?? "Downloading Nemotron 3\u{2026}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if store.isNemotronInstalled {
                        Label("Nemotron 3 installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 8) {
                            Button("Download Nemotron 3 (about 190 MB)") {
                                Task { await store.downloadNemotronModels() }
                            }
                            .controlSize(.small)
                            if let message = store.nemotronStatusMessage {
                                Text(message).font(.caption).foregroundStyle(.red)
                            }
                        }
                        Text("Until it is installed, the standard engine is used.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Toggle(
                "Also identify speakers on the microphone (in-person meetings)",
                isOn: $settings.diarizeMicrophone
            )
            .disabled(!settings.speakerDiarizationEnabled)
            Text("Turn on when several people share this Mac's microphone in the same room. Off, the microphone is always labeled \"You\". If only one person is detected, \"You\" is kept either way.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // A toggle that is on while the models are missing would silently do nothing, so the
            // gap is called out explicitly rather than failing quietly at transcription time.
            if settings.speakerDiarizationEnabled && !store.isInstalled && !store.isDownloading {
                Label(
                    "Speaker identification is on, but its models are not installed yet — download them below, otherwise transcripts keep a single \"Other\" label.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if store.isInstalled {
                Label("Speaker models installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if store.isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: store.downloadProgress)
                        .frame(maxWidth: 160)
                    Text(store.statusMessage ?? "Downloading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Download speaker models") {
                    Task { await store.downloadModels() }
                }
                .controlSize(.small)
                if let msg = store.statusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Divider()
                .padding(.vertical, 4)

            VoiceLibrarySettingsView()
        }
    }

    /// NVIDIA Parakeet (on-device via FluidAudio), the default transcription engine. Multilingual
    /// (25 European languages including German), runs on the Apple Neural Engine. While installed, the
    /// page checks once per launch for a newer model or revision; Update downloads it beside the working
    /// one. Status sits above its own button row so long offers wrap at full width; Delete stays apart
    /// from Update on the leading side and asks first, since it moves recordings to Apple Speech.
    @ViewBuilder
    private var parakeetModelSection: some View {
        GroupBox(label: sectionLabel("Parakeet (on-device · default)", systemImage: "bolt.fill")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Runs on-device on the Apple Neural Engine: fast, private, 25 European languages including German. The default transcription model. Without it, recordings use Apple Speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appViewModel.isInstallingParakeet {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: appViewModel.parakeetDownloadProgress)
                            .progressViewStyle(.linear)
                        Text(parakeetProgressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if appViewModel.parakeetModelInstalled {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            if case .available(.newModel) = appViewModel.parakeetUpdateState {
                                Label(appViewModel.parakeetModelName ?? "Installed", systemImage: "arrow.down.circle")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                            } else {
                                Label(appViewModel.parakeetModelName ?? "Installed", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.green)
                            }
                            HStack(spacing: 6) {
                                if appViewModel.parakeetUpdateState == .checking {
                                    ProgressView().controlSize(.mini)
                                }
                                Text(parakeetUpdateText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack(spacing: 8) {
                            Button("Delete Model…", role: .destructive) {
                                isConfirmingParakeetDelete = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                            switch appViewModel.parakeetUpdateState {
                            case .available(let status):
                                Button(status == .newModel ? "Update to Ultra" : "Update") {
                                    Task { await appViewModel.installParakeetModel() }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            default:
                                Button(appViewModel.parakeetUpdateState == .failed ? "Try Again" : "Check for Updates") {
                                    Task { await appViewModel.checkParakeetUpdate() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(appViewModel.parakeetUpdateState == .checking)
                            }
                        }
                    }
                    .task {
                        if appViewModel.parakeetUpdateState == .unknown { await appViewModel.checkParakeetUpdate() }
                    }
                    .confirmationDialog(
                        "Delete \(appViewModel.parakeetModelName ?? "Parakeet")?",
                        isPresented: $isConfirmingParakeetDelete
                    ) {
                        Button("Delete", role: .destructive) { appViewModel.deleteParakeetModel() }
                    } message: {
                        Text("Recordings will use Apple Speech until you install it again (about 600 MB).")
                    }
                } else {
                    HStack(spacing: 8) {
                        Label("Not installed", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Install (about 600 MB)") {
                            Task { await appViewModel.installParakeetModel() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    /// Progress line while Parakeet downloads; an update says the current model keeps working.
    private var parakeetProgressText: String {
        let message = appViewModel.parakeetLoadingMessage ?? "Installing…"
        guard appViewModel.parakeetModelInstalled else { return message }
        let percent = Int(appViewModel.parakeetDownloadProgress * 100)
        return "Updating to Parakeet Ultra… \(percent)%. Transcription keeps using the current model."
    }

    /// Status line under the installed Parakeet model.
    private var parakeetUpdateText: String {
        switch appViewModel.parakeetUpdateState {
        case .unknown:
            return "Not checked for updates yet"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            if let date = appViewModel.parakeetInstalledAt {
                return "Up to date (downloaded \(date.formatted(date: .abbreviated, time: .omitted)))"
            }
            return "Up to date"
        case .available(.newModel):
            return "Parakeet Ultra is available: fewer errors, same speed. About 600 MB; the current model keeps working until it is done."
        case .available:
            return "An update to Parakeet Ultra is available."
        case .failed:
            return "Couldn't check for updates. Check your internet connection."
        }
    }

    // MARK: - Section 3: Pipeline

    private var pipelineSection: some View {
        GroupBox(label: sectionLabel("Pipeline", systemImage: "arrow.triangle.2.circlepath")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(
                    "Process meetings once they have a project",
                    isOn: $settings.processOnceAssigned
                )
                Text("Recordings are always transcribed. A meeting is processed when it has a project and every speaker has a name. Off: only when you click Process.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcription engine")
                        .font(.subheadline)
                    Picker("Transcription engine", selection: $settings.defaultTranscriptionModel) {
                        Text("Parakeet (on-device)").tag("parakeet")
                        Text("Apple Speech").tag("appleSpeech")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)

                    Text("Used by the Transcribe button on every recording and by automatic transcription. There is no per-recording choice. This is the engine for all recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // The engine silently falls back to Apple Speech when its model is missing.
                    // Saying so here is the difference between "it works" and "it works, but not
                    // with what you picked".
                    if let note = appViewModel.transcriptionEngineFallbackNote {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Clean audio before transcription",
                        isOn: $settings.audioPreprocessingEnabled
                    )
                    Text("Applies a high-pass filter (removes low-frequency rumble/hum), normalizes quiet recordings to a consistent level, and gently attenuates background noise between speech. Improves accuracy on quiet or noisy meetings. Turn off if a recording sounds worse after processing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Correct names from calendar & project",
                        isOn: $settings.properNounCorrectionEnabled
                    )
                    Text("After transcribing, fixes near-miss spellings of participant names, the project and the meeting title (e.g. \"Anna Schmitt\" → \"Anna Schmid\"). Only clear near-misses are changed — text that already matches is never touched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                speakerDiarizationSection

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Auto-accept extracted tasks",
                        isOn: $settings.autoAcceptExtractedTasks
                    )
                    Text("When on, tasks extracted from meeting minutes are added directly to the project task list. When off, they appear on the recording card for review first. Can be overridden per project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Section 3: Task Review Reminders

    private var taskReviewRemindersSection: some View {
        GroupBox(label: sectionLabel("Task Review Reminders", systemImage: "bell")) {
            VStack(alignment: .leading, spacing: 14) {

                if showPermissionDeniedBanner {
                    permissionDeniedBanner
                }

                let times = settings.reviewReminderTimes

                if times.isEmpty && !isAddingReminder {
                    Text("No reminders configured.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(times.enumerated()), id: \.offset) { index, components in
                        HStack {
                            Text(formattedTime(components))
                                .font(.subheadline)
                            Spacer()
                            Button(role: .destructive) {
                                deleteReminder(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this reminder")
                        }
                        .padding(.vertical, 2)
                        if index < times.count - 1 {
                            Divider()
                        }
                    }
                }

                if isAddingReminder {
                    addReminderInline
                } else {
                    Button {
                        isAddingReminder = true
                    } label: {
                        Label("Add reminder time", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.top, 8)
        }
    }

    private var addReminderInline: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker(
                "Reminder time",
                selection: $pendingReminderDate,
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .datePickerStyle(.field)

            HStack(spacing: 10) {
                Button("Add") {
                    Task { await confirmAddReminder() }
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    isAddingReminder = false
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.top, 4)
    }

    private var permissionDeniedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Notification permission required. Enable in System Settings > Notifications.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
        )
    }

    // MARK: - Section 4: Reminders Sync

    private var remindersSyncSection: some View {
        GroupBox(label: sectionLabel("Reminders Sync", systemImage: "checklist")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Sync tasks to Apple Reminders by default",
                    isOn: $settings.remindersSyncDefault
                )
                Text("New tasks will default to this setting. You can override per-task in the review UI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private func formattedTime(_ components: DateComponents) -> String {
        let cal = Calendar.current
        guard let date = cal.date(from: components) else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Notification Scheduling

    private func confirmAddReminder() async {
        let center = UNUserNotificationCenter.current()
        let notifSettings = await center.notificationSettings()

        if notifSettings.authorizationStatus == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if !granted {
                showPermissionDeniedBanner = true
                isAddingReminder = false
                return
            }
        } else if notifSettings.authorizationStatus == .denied {
            showPermissionDeniedBanner = true
            isAddingReminder = false
            return
        }

        // Build DateComponents from the selected Date (hour + minute only)
        let cal = Calendar.current
        var components = DateComponents()
        components.hour = cal.component(.hour, from: pendingReminderDate)
        components.minute = cal.component(.minute, from: pendingReminderDate)

        // Append to stored list and reschedule
        var updatedTimes = settings.reviewReminderTimes
        updatedTimes.append(components)
        settings.reviewReminderTimes = updatedTimes
        await rescheduleAllReminders(updatedTimes)

        isAddingReminder = false
        showPermissionDeniedBanner = false
    }

    private func deleteReminder(at index: Int) {
        var times = settings.reviewReminderTimes
        guard times.indices.contains(index) else { return }
        times.remove(at: index)
        settings.reviewReminderTimes = times
        Task { await rescheduleAllReminders(times) }
    }

    /// Removes any legacy static mm.taskReview.* notifications that were scheduled before
    /// AI-powered briefs replaced them. The reminder times themselves are still saved and
    /// consumed by AutomationCoordinator to trigger the AI brief.
    private func rescheduleAllReminders(_ times: [DateComponents]) async {
        await clearAllReminders()
        // Static notifications are no longer scheduled here.
        // AutomationCoordinator fires an AI-powered brief at each configured time instead.
    }

    private func clearAllReminders() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.filter { $0.identifier.hasPrefix("mm.taskReview.") }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
