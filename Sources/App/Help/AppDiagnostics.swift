// Purpose: AppDiagnostics, what Claude needs to debug MinuteMind for the user: a snapshot of the
//          app's health (Claude Code, permissions, speech models, recording, queues, failures, sync,
//          jobs, MCP server) and the rules that turn it into issues, each with a plain fix and,
//          where the app can do it, a repair action for run_repair.
// Dependencies: Sources/App/Supporting/OnboardingPermissions.swift (permission states),
//               Sources/App/Services/ParakeetTranscriptionService.swift (InstallDiagnostics),
//               Sources/App/Supporting/OnboardingClaudeSetup.swift (install command)
// Used by: Sources/App/ViewModels/AppViewModel+Diagnostics.swift (fills the snapshot, runs repairs),
//          Sources/App/Services/MCP/MCPDiagnosticsTools.swift (get_app_status, run_repair),
//          Tests/AppDiagnosticsTests.swift
// Notes: The snapshot is plain values and `issues(in:)` is a pure function, so every rule is
//        testable without a running app. Fix texts are written for the user (where to click),
//        because Claude passes them on; the help topic "troubleshooting" explains the same cases.
//        A new failure mode the app can detect gets a rule here and a line in that topic.

import Foundation

struct AppErrorRecord: Equatable, Sendable {
    let date: Date
    let message: String
}

enum RepairAction: String, CaseIterable, Sendable {
    case installParakeet = "install_parakeet"
    case verifyParakeet = "verify_parakeet"
    case checkParakeetUpdate = "check_parakeet_update"
    case installSpeakerModels = "install_speaker_models"
    case installNemotron = "install_nemotron"
    case requestPermission = "request_permission"
    case retryTranscription = "retry_transcription"
    case syncSharedProject = "sync_shared_project"
    case rebuildSearchIndex = "rebuild_search_index"
    case refreshMicrophones = "refresh_microphones"

    var summary: String {
        switch self {
        case .installParakeet: "Download and install Parakeet (also repairs a broken install and installs updates). Runs in the background; progress shows in get_app_status."
        case .verifyParakeet: "Load the installed Parakeet model from disk to prove it works; reports the error if not."
        case .checkParakeetUpdate: "Ask Hugging Face whether a newer Parakeet revision exists."
        case .installSpeakerModels: "Download the standard speaker separation models."
        case .installNemotron: "Download Nemotron 3 (about 190 MB) for speaker separation."
        case .requestPermission: "Ask macOS for a permission (needs `permission`): shows the system prompt, or opens the right System Settings pane when it was refused. The user must click there."
        case .retryTranscription: "Transcribe a meeting again with the configured engine (needs `meeting_id`); processing follows when it has a project."
        case .syncSharedProject: "Sync a Shared Project now (needs `project_id`)."
        case .rebuildSearchIndex: "Rebuild the knowledge search index from the workspace files."
        case .refreshMicrophones: "Re-read the connected microphones."
        }
    }
}

struct DiagnosticsSnapshot: Sendable {
    struct FailedMeeting: Equatable, Sendable {
        var id: UUID
        var title: String
        var date: Date
        var error: String?
        var hasAudio: Bool
    }

    struct SharedProjectSync: Equatable, Sendable {
        var id: UUID
        var name: String
        /// "idle", "syncing" or the problem text.
        var state: String
        var problem: String?
        var lastSynced: Date?
    }

    struct FailedJobRun: Equatable, Sendable {
        var projectName: String
        var jobID: String
        var jobTitle: String
        var finished: Date
        var headline: String
    }

    // App
    var appVersion = "dev"
    var appPath = ""
    var builtAt: Date?
    var launchAtLogin = false
    var mcpStatus = "running"
    var mcpPort = 47821
    var mcpToolCount = 0

    // Claude Code
    /// The CLI the app found at launch (it keeps that answer until it restarts).
    var claudePathAtLaunch: String?
    /// The CLI found now.
    var claudePathNow: String?
    var claudeVersion: String?
    var claudeModel = "sonnet"

    // Permissions, keyed by OnboardingPermission raw value.
    var permissions: [String: OnboardingPermissionState] = [:]

    // Transcription
    var transcriptionEngine = "parakeet"
    var parakeetInstalledFlag = false
    var parakeet = ParakeetTranscriptionService.InstallDiagnostics(
        markerPresent: false, version: nil, folder: nil, folderExists: false, filesComplete: false,
        revision: nil, installedAt: nil, loadedInMemory: false)
    var parakeetInstalling = false
    var parakeetProgress: Double = 0
    var parakeetMessage: String?
    var parakeetLastError: String?
    /// "unknown", "checking", "up to date", "update available" or "check failed".
    var parakeetUpdate = "unknown"

    // Speakers
    var diarizationEnabled = false
    var diarizationEngine = "nemotron3"
    var speakerModelsInstalled = false
    var speakerModelsDownloading = false
    var speakerModelsMessage: String?
    var nemotronInstalled = false
    var nemotronDownloading = false
    var nemotronMessage: String?

    // Dictation and recording
    var quickDictationEnabled = false
    var quickDictationMode = "holdFn"
    var voiceAssistantEnabled = false
    var isRecording = false
    var recordingTitle: String?
    var microphone = "System Default"
    var chosenMicrophoneMissing = false
    var microphones: [String] = []
    var meetingDetection = false
    var freeDiskBytes: Int64?

    // Work in progress and failures
    var transcribingNow: String?
    var transcriptionsQueued = 0
    var processing: [String: String] = [:]
    var failedMeetings: [FailedMeeting] = []
    var knowledgeJobsPending = 0
    var knowledgeJobRunning = false
    var sharedProjects: [SharedProjectSync] = []
    var jobRunning: String?
    var jobsQueued = 0
    var failedJobRuns: [FailedJobRun] = []
    var recentErrors: [AppErrorRecord] = []
}

struct DiagnosticIssue: Equatable, Sendable {
    enum Severity: String, Sendable, Comparable {
        case error, warning, info

        private var rank: Int {
            switch self {
            case .error: 0
            case .warning: 1
            case .info: 2
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    var id: String
    var severity: Severity
    var problem: String
    var fix: String
    var repair: RepairAction?
    /// Arguments the repair needs (permission, meeting_id, project_id).
    var repairArguments: [String: String] = [:]
}

@MainActor
enum AppDiagnostics {
    static let lowDiskWarningBytes: Int64 = 2_000_000_000
    static let lowDiskErrorBytes: Int64 = 500_000_000

    /// Every problem the snapshot shows, most severe first.
    static func issues(in s: DiagnosticsSnapshot, now: Date = Date()) -> [DiagnosticIssue] {
        var issues: [DiagnosticIssue] = []
        issues += claudeIssues(s)
        issues += permissionIssues(s)
        issues += parakeetIssues(s)
        issues += speakerIssues(s)
        issues += recordingIssues(s)
        issues += failureIssues(s, now: now)
        if s.mcpStatus != "running" {
            issues.append(.init(
                id: "mcp_server", severity: .error, problem: "The MCP server is \(s.mcpStatus).",
                fix: "Settings > Integrations > MCP server: switch it off and on, or pick another port if this one is taken."))
        }
        if !s.launchAtLogin {
            issues.append(.init(
                id: "launch_at_login", severity: .info,
                problem: "MinuteMind does not open at login, so jobs and meeting detection stop while it is closed.",
                fix: "Settings > Automation > Startup > Open MinuteMind at login (update_setting launch_at_login true)."))
        }
        return issues.enumerated()
            .sorted { $0.element.severity == $1.element.severity ? $0.offset < $1.offset : $0.element.severity < $1.element.severity }
            .map(\.element)
    }

    private static func claudeIssues(_ s: DiagnosticsSnapshot) -> [DiagnosticIssue] {
        switch (s.claudePathAtLaunch, s.claudePathNow) {
        case (nil, nil):
            return [.init(
                id: "claude_missing", severity: .error,
                problem: "Claude Code is not installed (or not found), so summaries, titles, todos, knowledge, transcript correction, jobs and the voice assistant are off.",
                fix: "Install it in Terminal with `\(OnboardingClaudeSetup.installCommand)`, sign in by running `claude` once, then restart MinuteMind.")]
        case (nil, .some(let path)):
            return [.init(
                id: "claude_found_after_launch", severity: .warning,
                problem: "Claude Code was installed after MinuteMind started (now at \(path)); the app still treats it as missing.",
                fix: "Quit and reopen MinuteMind.")]
        default:
            return []
        }
    }

    private static func permissionIssues(_ s: DiagnosticsSnapshot) -> [DiagnosticIssue] {
        var issues: [DiagnosticIssue] = []
        func add(_ permission: OnboardingPermission, _ severity: DiagnosticIssue.Severity, _ effect: String) {
            guard let state = s.permissions[permission.rawValue], state != .granted else { return }
            let problem: String
            let fix: String
            switch state {
            case .pendingRestart:
                problem = "\(permission.title) was requested but is not active yet. \(effect)"
                fix = "Allow MinuteMind in System Settings > Privacy & Security > \(permission.title), then quit and reopen MinuteMind."
            case .denied:
                problem = "\(permission.title) permission was refused. \(effect)"
                fix = "Switch MinuteMind on in System Settings > Privacy & Security > \(permission.title) (run_repair request_permission opens that pane)."
            default:
                problem = "\(permission.title) permission is not granted. \(effect)"
                fix = "Grant it when macOS asks (run_repair request_permission shows the prompt)."
            }
            issues.append(.init(
                id: "permission_\(permission.rawValue)", severity: severity, problem: problem, fix: fix,
                repair: .requestPermission, repairArguments: ["permission": permission.rawValue]))
        }
        add(.microphone, .error, "Nothing can be recorded or dictated.")
        add(.screenRecording, .warning, "Recordings only capture this Mac's microphone, not the other side of calls.")
        if s.quickDictationEnabled || s.voiceAssistantEnabled {
            add(.accessibility, .warning, "Dictated text goes to the clipboard instead of being typed, and the dictation keys may not work in other apps.")
        }
        add(.calendar, .info, "The calendar, auto-record and name correction from events do not work.")
        add(.notifications, .info, "MinuteMind cannot tell you when summaries or jobs are done.")
        let usesAppleSpeech = s.transcriptionEngine == "appleSpeech" || !s.parakeet.filesComplete
        add(.speechRecognition, usesAppleSpeech ? .warning : .info, "Apple Speech (live dictation, and transcription while Parakeet is missing) does not work.")
        return issues
    }

    private static func parakeetIssues(_ s: DiagnosticsSnapshot) -> [DiagnosticIssue] {
        let p = s.parakeet
        if s.parakeetInstalling {
            let percent = Int((s.parakeetProgress * 100).rounded())
            return [.init(
                id: "parakeet_installing", severity: .info,
                problem: "Parakeet is being installed (\(percent) %\(s.parakeetMessage.map { ", \($0)" } ?? "")).",
                fix: "Wait; MinuteMind uses it as soon as the download is complete.")]
        }
        var issues: [DiagnosticIssue] = []
        let usesParakeet = s.transcriptionEngine == "parakeet"
        if p.markerPresent && !p.filesComplete {
            let detail = p.folderExists
                ? "its folder \(p.folder ?? "") is incomplete"
                : "its folder \(p.folder ?? "") is missing"
            issues.append(.init(
                id: "parakeet_broken", severity: usesParakeet ? .error : .warning,
                problem: "The Parakeet install is broken: \(detail). Transcription falls back to Apple Speech.",
                fix: "Reinstall it (run_repair install_parakeet, or Settings > Automation > Parakeet > Install).",
                repair: .installParakeet))
        } else if !p.markerPresent && usesParakeet {
            var problem = "Parakeet is not installed, so recordings are transcribed with Apple Speech (less accurate)."
            if let error = s.parakeetLastError { problem += " The last install failed: \(error)" }
            issues.append(.init(
                id: "parakeet_missing", severity: s.parakeetLastError == nil ? .warning : .error,
                problem: problem,
                fix: "Install it (run_repair install_parakeet, or Settings > Automation > Parakeet > Install). It downloads about 600 MB from Hugging Face; check the internet connection if it fails again.",
                repair: .installParakeet))
        } else if let error = s.parakeetLastError {
            issues.append(.init(
                id: "parakeet_update_failed", severity: .warning,
                problem: "The last Parakeet download failed (\(error)); the installed model keeps working.",
                fix: "Try again later (run_repair install_parakeet).", repair: .installParakeet))
        }
        if p.filesComplete && !s.parakeetInstalledFlag {
            issues.append(.init(
                id: "parakeet_state_stale", severity: .warning,
                problem: "Parakeet's files are complete but MinuteMind does not use them yet.",
                fix: "Run run_repair verify_parakeet, or restart MinuteMind.", repair: .verifyParakeet))
        }
        if s.parakeetUpdate == "update available" {
            issues.append(.init(
                id: "parakeet_update", severity: .info, problem: "A newer Parakeet model is available.",
                fix: "Install it (run_repair install_parakeet, or Settings > Automation > Parakeet > Update).",
                repair: .installParakeet))
        }
        return issues
    }

    private static func speakerIssues(_ s: DiagnosticsSnapshot) -> [DiagnosticIssue] {
        guard s.diarizationEnabled else { return [] }
        var issues: [DiagnosticIssue] = []
        if !s.speakerModelsInstalled && !s.speakerModelsDownloading {
            issues.append(.init(
                id: "speaker_models_missing", severity: .warning,
                problem: "Identify speakers is on but its models are not installed, so transcripts keep a single \"Other\" label for the call audio.\(s.speakerModelsMessage.map { " Last message: \($0)" } ?? "")",
                fix: "Install them (run_repair install_speaker_models, or the speaker section of Settings > Automation).",
                repair: .installSpeakerModels))
        }
        if s.diarizationEngine == "nemotron3" && !s.nemotronInstalled && !s.nemotronDownloading {
            issues.append(.init(
                id: "nemotron_missing", severity: .warning,
                problem: "The speaker engine is Nemotron 3 but it is not installed, so the standard engine is used.\(s.nemotronMessage.map { " Last message: \($0)" } ?? "")",
                fix: "Install it (run_repair install_nemotron), or choose the standard engine (update_setting speaker_engine fluidAudio).",
                repair: .installNemotron))
        }
        return issues
    }

    private static func recordingIssues(_ s: DiagnosticsSnapshot) -> [DiagnosticIssue] {
        var issues: [DiagnosticIssue] = []
        if s.chosenMicrophoneMissing {
            issues.append(.init(
                id: "microphone_missing", severity: .warning,
                problem: "The microphone chosen in Settings > Audio is not connected; the system default is used.",
                fix: "Connect it, or pick another microphone (list_settings microphone).", repair: .refreshMicrophones))
        }
        if let free = s.freeDiskBytes, free < lowDiskWarningBytes {
            issues.append(.init(
                id: "low_disk", severity: free < lowDiskErrorBytes ? .error : .warning,
                problem: "Only \(free / 1_000_000) MB free on the disk with the recordings; long recordings can fail.",
                fix: "Free up space, or archive old recordings in Settings > Storage."))
        }
        return issues
    }

    private static func failureIssues(_ s: DiagnosticsSnapshot, now: Date) -> [DiagnosticIssue] {
        var issues: [DiagnosticIssue] = []
        for meeting in s.failedMeetings.prefix(5) {
            issues.append(.init(
                id: "meeting_failed_\(meeting.id.uuidString)", severity: .warning,
                problem: "\"\(meeting.title)\" failed\(meeting.error.map { ": \($0)" } ?? ".")",
                fix: meeting.hasAudio
                    ? "Transcribe it again (run_repair retry_transcription), or Retry in the Inbox."
                    : "Its audio is gone, so it cannot be transcribed again.",
                repair: meeting.hasAudio ? .retryTranscription : nil,
                repairArguments: meeting.hasAudio ? ["meeting_id": meeting.id.uuidString] : [:]))
        }
        for project in s.sharedProjects {
            guard let problem = project.problem else { continue }
            issues.append(.init(
                id: "sync_\(project.id.uuidString)", severity: .warning,
                problem: "Shared Project \"\(project.name)\" cannot sync: \(problem)",
                fix: "Check the internet connection and the git login for the project's repository (`gh auth status` in Terminal), make sure the workspace is on main, then sync again.",
                repair: .syncSharedProject, repairArguments: ["project_id": project.id.uuidString]))
        }
        for run in s.failedJobRuns.prefix(5) {
            issues.append(.init(
                id: "job_failed_\(run.jobID)", severity: .info,
                problem: "Job \"\(run.jobTitle)\" in \(run.projectName) failed: \(run.headline)",
                fix: "Read the run with list_job_runs / get_job_run, fix the prompt or access level with update_job, and try run_job_now."))
        }
        let recent = s.recentErrors.filter { now.timeIntervalSince($0.date) < 3600 }
        if !recent.isEmpty {
            issues.append(.init(
                id: "recent_errors", severity: .info,
                problem: "MinuteMind showed \(recent.count) error message(s) in the last hour, latest: \(recent[0].message)",
                fix: "See recent_errors in the report, and get_app_log for details."))
        }
        return issues
    }
}
