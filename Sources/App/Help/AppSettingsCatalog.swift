// Purpose: AppSettingsCatalog, every user-facing MinuteMind setting Claude can list and change
//          over MCP (list_settings, update_setting), in the order of the Settings window, plus the
//          stored keys that are deliberately not settings.
// Dependencies: Sources/App/Help/AppSetting.swift (entry model, value parsing),
//               Sources/App/Config/AutomationSettings.swift (most switches),
//               Sources/App/Supporting/ThemeStore.swift, Sources/App/Config/AppTheme.swift (themes),
//               Sources/App/Supporting/CompanionAppearance.swift, CompanionController.swift (companion),
//               Sources/App/Supporting/LaunchAtLogin.swift, Sources/App/Models/SharedProject.swift
//               (ContributorName), Sources/App/Services/MCP/MinuteMindMCPServer.swift (MCP settings),
//               Sources/App/ViewModels/AppViewModel.swift (meeting detection, microphone, prompts)
// Used by: Sources/App/Services/MCP/MCPHelpTools.swift, Tests/AppSettingsCatalogTests.swift
// RBAC: every MCP client with the token may change these. The MCP server's own switch and port
//       are read-only here: changing them over MCP would cut off the client that asked.
// Notes: A new setting in the Settings window gets an entry here (or a line in `internalKeys` when
//        it is not a setting), otherwise AppSettingsCatalogTests fails. Side effects the Settings
//        window performs on change (model downloads, starting the meeting radar) are repeated in
//        `write`, so a change from Claude works the same as a click.

import Foundation
import UserNotifications

@MainActor
enum AppSettingsCatalog {
    typealias Option = AppSetting.Option

    static func setting(_ id: String) -> AppSetting? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == wanted }
    }

    static var all: [AppSetting] {
        automation + audio + appearance + ai + integrations
    }

    /// Stored keys that are not settings (window state, one-time hints, data kept elsewhere),
    /// with the reason. Prefixes end with ".".
    static let internalKeys: [String: String] = [
        "mm.autoPipelineEnabled": "declared in AutomationSettings but read nowhere and not shown in Settings",
        "mm.companionCoachSeen": "one-time hint",
        "mm.companionLastColor": "remembers the last own colour for the companion colour switch",
        "mm.companionPosition": "where the companion was dragged",
        "mm.companionDocked": "set by dragging the companion out of or into the window corner",
        "mm.dailyBriefingLastShown": "once-a-day briefing bookkeeping",
        "mm.generalTab": "window state",
        "mm.inboxSince": "start date of the Inbox",
        "mm.jobRun": "notification category id",
        "mm.lastProjectTab": "window state",
        "mm.launchAtLoginInitialized": "one-time switch-on of open at login",
        "mm.onboardingCompleted": "first-launch setup bookkeeping",
        "mm.onboardingScreenRecordingRequested": "first-launch setup bookkeeping",
        "mm.onboardingSelectGeneral": "first-launch setup bookkeeping",
        "mm.onboardingStep": "first-launch setup bookkeeping",
        "mm.pendingProjectID": "the record picker's project (start_recording takes a project instead)",
        "mm.processWithoutAsking": "old key, replaced by mm.processOnceAssigned",
        "mm.recordingConsentAcknowledged": "one-time recording notice",
        "mm.taskReview.": "notification id prefix",
        "mm.themeCustom": "custom theme colours, edited in Settings > Appearance",
        "mm.themeProfiles": "saved theme profiles, edited in Settings > Appearance",
        "mm.todoBrief": "cached task brief",
        "mm.wheelHintCount": "one-time hint",
        "mm.workspaceClaudeBelow": "workspace layout",
        "mm.workspaceEditorHeight": "workspace layout",
        "mm.workspaceEditorHintSeen": "one-time hint",
        "mm.workspaceEditorWidth": "workspace layout",
        "mm.workspaceTreeCollapsed": "workspace layout",
        "mm.workspaceTreeWidth": "workspace layout",
    ]

    // MARK: - Automation

    private static let startup = "Settings > Automation > Startup"
    private static let autoRecording = "Settings > Automation > Auto-recording"
    private static let quickDictation = "Settings > Automation > Quick Dictation"
    private static let pipeline = "Settings > Automation > Pipeline"

    private static var automation: [AppSetting] {
        [
            AppSetting(
                id: "launch_at_login", title: "Open MinuteMind at login", location: startup,
                summary: "Starts MinuteMind when you log in. Jobs and meeting detection only run while the app is open.",
                helpTopic: "settings", storageKeys: [], kind: .toggle,
                read: { _ in .bool(LaunchAtLogin.shared.isEnabled || LaunchAtLogin.shared.needsApproval) },
                write: { _, value in
                    let launch = LaunchAtLogin.shared
                    launch.setEnabled(value.flag)
                    if let error = launch.lastError { throw AppSetting.ParseError.invalid("macOS refused: \(error)") }
                    return launch.needsApproval
                        ? "macOS waits for the user to allow it in System Settings > General > Login Items." : nil
                }),
            AppSetting(
                id: "detect_meetings", title: "Detect Meetings", location: "All Transcripts > Detect Meetings switch",
                summary: "Notices calls in Teams, Zoom, Meet, Webex, Slack, FaceTime and browsers and offers to record them beside the companion.",
                helpTopic: "meeting-detection", storageKeys: ["mm.meetingRadarEnabled"], kind: .toggle,
                read: { .bool($0.meetingDetectionEnabled) },
                write: { vm, value in vm.setMeetingDetection(value.flag); return nil }),
            automationToggle(
                "auto_record_calendar_events", "Start recording automatically at event time", autoRecording,
                "Records calendar events that have auto-record switched on, at their start time.",
                topic: "calendar", key: "mm.autoStartEnabled", \.autoStartEnabled),
            AppSetting(
                id: "meeting_over_question_after_silence", title: "Ask \"Meeting over?\" after silence",
                location: autoRecording,
                summary: "Seconds of silence after which the companion asks whether the meeting is over. It never stops a recording by itself.",
                helpTopic: "recording", storageKeys: ["mm.autoStopSilenceThreshold"], kind: .choice,
                options: { _ in [15, 30, 60, 120].map { Option(value: "\($0)", label: "\($0) s") } },
                read: { .string(AppSetting.text(NSNumber(value: $0.automationSettings.autoStopSilenceThreshold))) },
                write: { vm, value in
                    vm.automationSettings.autoStopSilenceThreshold = Double(value.string) ?? 30
                    return nil
                }),
            automationToggle(
                "meeting_over_question_for_manual_recordings", "Also apply to manual recordings", autoRecording,
                "Asks \"Meeting over?\" after silence for recordings you started yourself too.",
                topic: "recording", key: "mm.manualRecordingSilenceEnabled", \.manualRecordingSilenceEnabled),
            AppSetting(
                id: "detect_teams_calls", title: "Detect Microsoft Teams calls (best effort)", location: autoRecording,
                summary: "Older detection that starts recording by itself while a Teams call is active. Detect Meetings replaces it for most people.",
                helpTopic: "meeting-detection", storageKeys: ["mm.teamsDetectionEnabled"], kind: .toggle,
                read: { .bool($0.teamsCallDetectionEnabled) },
                write: { vm, value in vm.teamsCallDetectionEnabled = value.flag; return nil }),
            automationChoice(
                "default_language", "Default language", "Settings > Automation > Live Dictation",
                "Language for transcribing recordings and for live dictation. Calendar series can override it.",
                topic: "transcription", key: "mm.liveDictationLanguage", \.liveDictationLanguage,
                [("auto", "Auto-detect"), ("en-US", "English (US)"), ("de-DE", "Deutsch")]),
            automationToggle(
                "quick_dictation", "Enable quick dictation", quickDictation,
                "Dictate into any app with the trigger key; the text is typed at the cursor.",
                topic: "quick-dictation", key: "mm.quickDictationEnabled", \.quickDictationEnabled),
            automationChoice(
                "quick_dictation_trigger", "How to trigger it", quickDictation,
                "Key for quick dictation. The hold keys also give double tap to record and fn + Control for the voice assistant.",
                topic: "quick-dictation", key: "mm.quickDictationMode", \.quickDictationMode,
                [("holdFn", "Hold fn, release to insert"), ("holdRightOption", "Hold the right Option key, release to insert"),
                 ("toggle", "Press Ctrl+Opt+D to start, again to insert")]),
            automationChoice(
                "quick_dictation_language", "Dictation language", quickDictation,
                "Language for quick dictation.",
                topic: "quick-dictation", key: "mm.quickDictationLanguage", \.quickDictationLanguage,
                [("auto", "Follow system language"), ("de-DE", "German"), ("en-US", "English (US)")]),
            automationToggle(
                "double_tap_to_record", "Double tap to record", quickDictation,
                "Double tap the hold key to start a quick recording, press once more to stop. Needs a hold key.",
                topic: "quick-dictation", key: "mm.quickRecordingEnabled", \.quickRecordingEnabled),
            automationToggle(
                "voice_assistant", "Enable Claude mini tasks", quickDictation + " > Claude",
                "The voice assistant: hold the dictation key with Control, speak, release, and Claude acts or answers.",
                topic: "voice-assistant", key: "mm.claudeTaskEnabled", \.claudeTaskEnabled),
            automationChoice(
                "voice_assistant_model", "Model", quickDictation + " > Claude",
                "Claude model for the voice assistant.",
                topic: "voice-assistant", key: "mm.claudeTaskModel", \.claudeTaskModel,
                ClaudeTaskService.models.map { ($0.alias, $0.name) }),
            automationToggle(
                "voice_assistant_terminal", "Let Claude run terminal commands", quickDictation + " > Claude",
                "Off limits the voice assistant to MinuteMind and the web.",
                topic: "voice-assistant", key: "mm.claudeTaskAllowsTerminal", \.claudeTaskAllowsTerminal),
            AppSetting(
                id: "voice_assistant_instructions", title: "Your instructions for every task",
                location: quickDictation + " > Claude",
                summary: "Standing instructions sent with every voice assistant task (tone, language, who you are).",
                helpTopic: "voice-assistant", storageKeys: ["mm.claudeTaskPrompt"], kind: .text,
                read: { .string($0.automationSettings.claudeTaskPrompt) },
                write: { vm, value in vm.automationSettings.claudeTaskPrompt = value.string; return nil }),
            automationToggle(
                "process_automatically", "Process meetings once they have a project", pipeline,
                "Starts processing (correction, summary, title, todos, knowledge) as soon as a meeting has a project and a transcript. Off: only when the user clicks Process.",
                topic: "inbox", key: "mm.processOnceAssigned", \.processOnceAssigned),
            automationChoice(
                "transcription_engine", "Transcription engine", pipeline,
                "Engine for every recording. Parakeet must be installed (Settings > Automation > Parakeet), otherwise Apple Speech is used.",
                topic: "transcription", key: "mm.defaultTranscriptionModel", \.defaultTranscriptionModel,
                [("parakeet", "Parakeet (on-device)"), ("appleSpeech", "Apple Speech")]),
            automationToggle(
                "clean_audio", "Clean audio before transcription", pipeline,
                "Filters rumble, evens out quiet recordings and softens background noise before transcribing.",
                topic: "transcription", key: "mm.audioPreprocessingEnabled", \.audioPreprocessingEnabled),
            automationToggle(
                "correct_names", "Correct names from calendar & project", pipeline,
                "Fixes near-miss spellings of participant names, the project and the meeting title after transcribing.",
                topic: "transcription", key: "mm.properNounCorrectionEnabled", \.properNounCorrectionEnabled),
            AppSetting(
                id: "identify_speakers", title: "Identify speakers (Speaker 1, 2, ...)", location: pipeline,
                summary: "Splits the call audio into separate speakers on the Mac. Switching it on downloads the models it needs.",
                helpTopic: "speakers", storageKeys: ["mm.speakerDiarizationEnabled"], kind: .toggle,
                read: { .bool($0.automationSettings.speakerDiarizationEnabled) },
                write: { vm, value in
                    vm.automationSettings.speakerDiarizationEnabled = value.flag
                    let store = vm.speakerDiarizationModels
                    guard value.flag, !store.isInstalled, !store.isDownloading else { return nil }
                    Task { await store.downloadModels() }
                    return "The speaker models are downloading now."
                }),
            AppSetting(
                id: "speaker_engine", title: "Engine", location: pipeline + " > Identify speakers",
                summary: "Speaker separation engine. Nemotron 3 separates up to 8 speakers and is more accurate; choosing it downloads it (about 190 MB).",
                helpTopic: "speakers", storageKeys: ["mm.diarizationEngine"], kind: .choice,
                options: { _ in [Option(value: "nemotron3", label: "Nemotron 3 (NVIDIA)"), Option(value: "fluidAudio", label: "Standard")] },
                read: { .string($0.automationSettings.diarizationEngine) },
                write: { vm, value in
                    vm.automationSettings.diarizationEngine = value.string
                    let store = vm.speakerDiarizationModels
                    guard value.string == "nemotron3", !store.isNemotronInstalled, !store.isDownloadingNemotron else { return nil }
                    Task { await store.downloadNemotronModels() }
                    return "Nemotron 3 is downloading now; the standard engine is used until it is installed."
                }),
            automationToggle(
                "identify_speakers_on_microphone", "Also identify speakers on the microphone (in-person meetings)", pipeline,
                "For several people sharing this Mac's microphone. Off, the microphone is always labelled with the user's name.",
                topic: "speakers", key: "mm.diarizeMicrophone", \.diarizeMicrophone),
            automationToggle(
                "auto_accept_extracted_tasks", "Auto-accept extracted tasks", pipeline,
                "On: todos from meetings go straight into the project's tasks. Off: they wait on the recording card for review. Projects can override it.",
                topic: "tasks", key: "mm.autoAcceptExtractedTasks", \.autoAcceptExtractedTasks),
            AppSetting(
                id: "task_review_reminder_times", title: "Task Review Reminders",
                location: "Settings > Automation > Task Review Reminders",
                summary: "Times of day when MinuteMind sends a short brief of open tasks, written like \"09:00, 14:30\"; empty for none.",
                helpTopic: "tasks", storageKeys: ["mm.reviewReminderTimes"], kind: .timesOfDay,
                read: { .string(AppSetting.timesOfDayText($0.automationSettings.reviewReminderTimes)) },
                write: { vm, value in
                    let times = AppSetting.timesOfDay(value.string) ?? []
                    vm.automationSettings.reviewReminderTimes = times
                    guard !times.isEmpty else { return nil }
                    // The Settings page asks for notification permission when the first time is added.
                    Task {
                        let center = UNUserNotificationCenter.current()
                        if await center.notificationSettings().authorizationStatus == .notDetermined {
                            _ = try? await center.requestAuthorization(options: [.alert, .sound])
                        }
                    }
                    return nil
                }),
            automationToggle(
                "sync_tasks_to_reminders", "Sync tasks to Apple Reminders by default",
                "Settings > Automation > Reminders Sync",
                "New tasks also go to Apple Reminders unless the task says otherwise.",
                topic: "tasks", key: "mm.remindersSyncDefault", \.remindersSyncDefault),
        ]
    }

    // MARK: - Audio

    private static var audio: [AppSetting] {
        [
            AppSetting(
                id: "microphone", title: "Microphone", location: "Settings > Audio",
                summary: "Microphone for recordings and dictation. System Default follows macOS; a chosen one stays even when headphones connect. Switching during a recording moves the recording over.",
                helpTopic: "recording", storageKeys: ["mm.inputDeviceUID"], kind: .choice,
                options: { vm in
                    vm.audioDeviceManager.refreshDevices()
                    return [Option(value: "system_default", label: "System Default")]
                        + vm.audioDeviceManager.inputDevices.map { Option(value: $0.name, label: $0.name) }
                },
                read: { vm in
                    let manager = vm.audioDeviceManager
                    guard let id = manager.selectedInputDeviceID,
                          let device = manager.inputDevices.first(where: { $0.id == id }) else { return .string("system_default") }
                    return .string(device.name)
                },
                write: { vm, value in
                    let device = vm.audioDeviceManager.inputDevices.first { $0.name == value.string }
                    vm.selectMicrophone(device?.id)
                    return nil
                }),
            AppSetting(
                id: "your_name", title: "Your name", location: "Settings > Audio",
                summary: "How the user appears in transcripts instead of \"You\".",
                helpTopic: "speakers", storageKeys: ["mm.ownSpeakerName"], kind: .text,
                read: { .string($0.automationSettings.ownSpeakerName) },
                write: { vm, value in vm.automationSettings.ownSpeakerName = value.string; return nil }),
        ]
    }

    // MARK: - Appearance

    private static let companionPlace = "Settings > Appearance > Companion"

    private static var appearance: [AppSetting] {
        [
            AppSetting(
                id: "theme", title: "Theme", location: "Settings > Appearance",
                summary: "Colour theme of the app. Custom uses the colours set in Settings; saved profiles are listed by name.",
                helpTopic: "appearance", storageKeys: ["mm.theme"], kind: .choice,
                options: { _ in
                    AppTheme.builtIn.map { Option(value: $0.id, label: $0.name) }
                        + ThemeStore.shared.profiles.map { Option(value: $0.themeID, label: $0.name) }
                        + [Option(value: AppTheme.customID, label: "Custom")]
                },
                read: { _ in .string(ThemeStore.shared.themeID) },
                write: { _, value in ThemeStore.shared.themeID = value.string; return nil }),
            AppSetting(
                id: "appearance_mode", title: "Mode", location: "Settings > Appearance",
                summary: "Light, dark, or follow macOS.",
                helpTopic: "appearance", storageKeys: ["mm.appearanceMode"], kind: .choice,
                options: { _ in ThemeStore.AppearanceMode.allCases.map { Option(value: $0.rawValue, label: $0.label) } },
                read: { _ in .string(ThemeStore.shared.appearanceMode.rawValue) },
                write: { _, value in
                    ThemeStore.shared.appearanceMode = ThemeStore.AppearanceMode(rawValue: value.string) ?? .system
                    return nil
                }),
            AppSetting(
                id: "companion_shown", title: "Show the companion", location: companionPlace,
                summary: "Shows or hides the desktop companion (Window > Show Companion brings it back too).",
                helpTopic: "companion", storageKeys: ["mm.companionHidden"], kind: .toggle,
                read: { .bool(!$0.companion.model.isHiddenByUser) },
                write: { vm, value in vm.companion.setHidden(!value.flag); return nil }),
            AppSetting(
                id: "companion_creature", title: "Companion", location: companionPlace,
                summary: "Which creature the companion is.",
                helpTopic: "companion", storageKeys: ["mm.companionAvatar"], kind: .choice,
                options: { _ in MascotAvatar.allCases.map { Option(value: $0.rawValue, label: $0.name) } },
                read: { _ in .string(CompanionAppearance.shared.avatar.rawValue) },
                write: { _, value in
                    if let avatar = MascotAvatar(rawValue: value.string) { CompanionAppearance.shared.avatar = avatar }
                    return nil
                }),
            AppSetting(
                id: "companion_size", title: "Size", location: companionPlace,
                summary: "Size of the companion.",
                helpTopic: "companion", storageKeys: ["mm.companionSize"], kind: .choice,
                options: { _ in CompanionAppearance.Size.allCases.map { Option(value: $0.rawValue, label: $0.label) } },
                read: { _ in .string(CompanionAppearance.shared.size.rawValue) },
                write: { _, value in
                    if let size = CompanionAppearance.Size(rawValue: value.string) { CompanionAppearance.shared.size = size }
                    return nil
                }),
            AppSetting(
                id: "companion_colour", title: "Colour", location: companionPlace,
                summary: "\"default\" (the theme's accent for the blob, the natural colour for the others) or an own colour like \"#FF8800\" for the body.",
                helpTopic: "companion", storageKeys: ["mm.companionColor"], kind: .colour,
                read: { _ in
                    guard let colour = CompanionAppearance.shared.customColor else { return .string("default") }
                    return .string(String(format: "#%06X", colour))
                },
                write: { _, value in
                    CompanionAppearance.shared.customColor = AppSetting.hexColour(value.string)
                    return nil
                }),
            AppSetting(
                id: "companion_comes_on_shake", title: "Come to the pointer when I shake the mouse", location: companionPlace,
                summary: "Shaking the mouse brings the companion to the pointer.",
                helpTopic: "companion", storageKeys: ["mm.companionComesOnShake"], kind: .toggle,
                read: { _ in .bool(CompanionAppearance.shared.comesOnShake) },
                write: { _, value in CompanionAppearance.shared.comesOnShake = value.flag; return nil }),
            AppSetting(
                id: "companion_in_screen_shares", title: "Show the companion in screen shares", location: companionPlace,
                summary: "On: others see the companion when the screen is shared, and it stays on screen meanwhile. Off: it hides during screen shares.",
                helpTopic: "companion", storageKeys: ["mm.companionVisibleInScreenShares"], kind: .toggle,
                read: { _ in .bool(CompanionAppearance.shared.visibleInScreenShares) },
                write: { _, value in CompanionAppearance.shared.visibleInScreenShares = value.flag; return nil }),
            AppSetting(
                id: "companion_claude_done_notices", title: "Notify When Claude Finishes",
                location: "Companion right-click menu",
                summary: "The companion says when a Claude session finishes a turn of 30 seconds or more.",
                helpTopic: "companion", storageKeys: [CompanionController.doneNoticesKey], kind: .toggle,
                read: { _ in .bool(CompanionController.doneNoticesEnabled) },
                write: { _, value in
                    UserDefaults.standard.set(value.flag, forKey: CompanionController.doneNoticesKey)
                    return nil
                }),
        ]
    }

    // MARK: - AI

    private static var ai: [AppSetting] {
        [
            automationChoice(
                "claude_model", "Model", "Settings > AI > Claude",
                "Claude model for summaries, titles, todos and knowledge. Transcript correction always uses Sonnet.",
                topic: "summaries", key: "mm.claudeModel", \.claudeModel,
                AIClient.models.map { ($0, $0.capitalized) }),
            AppSetting(
                id: "summary_prompt", title: "Summary Prompts", location: "Settings > AI > Summary Prompts",
                summary: "The prompt used for new summaries. Prompts themselves are added and edited in Settings.",
                helpTopic: "summaries", storageKeys: [], kind: .choice,
                options: { vm in vm.summaryPrompts.map { Option(value: $0.id.uuidString, label: $0.title) } },
                read: { vm in .string(vm.summaryPrompts.first { $0.isSelected }?.id.uuidString ?? "") },
                write: { vm, value in
                    if let prompt = vm.summaryPrompts.first(where: { $0.id.uuidString == value.string }) { vm.selectPrompt(prompt) }
                    return nil
                }),
        ]
    }

    // MARK: - Integrations

    private static let mcpReadOnly = "It is MinuteMind's connection to Claude: change it in Settings > Integrations."

    private static var integrations: [AppSetting] {
        [
            AppSetting(
                id: "mcp_server", title: "Allow MCP clients on this Mac to access MinuteMind",
                location: "Settings > Integrations > MCP server",
                summary: "The local MCP server Claude uses to reach MinuteMind.",
                helpTopic: "claude-integration", storageKeys: ["mm.mcpServerEnabled"], kind: .toggle,
                readOnlyReason: mcpReadOnly,
                read: { .bool($0.mcpServer.isEnabled) }),
            AppSetting(
                id: "mcp_server_port", title: "Port", location: "Settings > Integrations > MCP server",
                summary: "Port of the local MCP server (47821 by default).",
                helpTopic: "claude-integration", storageKeys: ["mm.mcpServerPort"], kind: .text,
                readOnlyReason: mcpReadOnly,
                read: { .string(String($0.mcpServer.port)) }),
            AppSetting(
                id: "display_name", title: "Your name", location: "Settings > Integrations > Shared Projects",
                summary: "Display name in Shared Projects: shown to teammates and added to the folders you publish. Changing it keeps existing folders.",
                helpTopic: "shared-projects", storageKeys: [ContributorName.defaultsKey], kind: .text,
                read: { _ in .string(ContributorName.current ?? "") },
                write: { _, value in ContributorName.current = value.string.isEmpty ? nil : value.string; return nil }),
        ]
    }

    // MARK: - Builders

    private static func automationToggle(
        _ id: String, _ title: String, _ location: String, _ summary: String,
        topic: String, key: String, _ keyPath: ReferenceWritableKeyPath<AutomationSettings, Bool>
    ) -> AppSetting {
        AppSetting(
            id: id, title: title, location: location, summary: summary, helpTopic: topic,
            storageKeys: [key], kind: .toggle,
            read: { .bool($0.automationSettings[keyPath: keyPath]) },
            write: { vm, value in vm.automationSettings[keyPath: keyPath] = value.flag; return nil })
    }

    private static func automationChoice(
        _ id: String, _ title: String, _ location: String, _ summary: String,
        topic: String, key: String, _ keyPath: ReferenceWritableKeyPath<AutomationSettings, String>,
        _ choices: [(value: String, label: String)]
    ) -> AppSetting {
        let options = choices.map { Option(value: $0.value, label: $0.label) }
        return AppSetting(
            id: id, title: title, location: location, summary: summary, helpTopic: topic,
            storageKeys: [key], kind: .choice,
            options: { _ in options },
            read: { .string($0.automationSettings[keyPath: keyPath]) },
            write: { vm, value in vm.automationSettings[keyPath: keyPath] = value.string; return nil })
    }
}

extension AppSetting.Value {
    /// The flag of a toggle (false for text).
    var flag: Bool {
        if case .bool(let flag) = self { return flag }
        return false
    }

    /// The text of a choice or text setting ("" for a toggle).
    var string: String {
        if case .string(let text) = self { return text }
        return ""
    }
}
