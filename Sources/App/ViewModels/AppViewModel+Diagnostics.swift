// Purpose: AppViewModel+Diagnostics, gathers the app's health into a DiagnosticsSnapshot for
//          get_app_status and runs the repairs Claude may trigger (run_repair): installing or
//          verifying speech models, asking for permissions, retrying a transcription, syncing a
//          Shared Project, rebuilding the search index.
// Dependencies: Sources/App/Help/AppDiagnostics.swift (snapshot, RepairAction),
//               Sources/App/ViewModels/AppViewModel.swift (Parakeet state, recentErrors, sessions,
//               queues, recordingsFreeDiskBytes), Sources/App/Services/ClaudeCodeService.swift,
//               Sources/App/Supporting/OnboardingPermissions.swift (permission state and request),
//               Sources/App/Services/SpeakerDiarizationModelStore.swift, Sources/App/Supporting/ScheduledJobStore.swift,
//               Sources/App/ViewModels/AppViewModel+SharedSync.swift (syncSharedProjectNow)
// Used by: Sources/App/Services/MCP/MCPDiagnosticsTools.swift
// Notes: Downloads and the index rebuild start in the background and the repair returns at once:
//        an MCP request should not wait minutes. Claude follows progress with get_app_status. The
//        Claude Code lookup that may start a login shell and `claude --version` run off the main
//        thread with a time limit.

import AppKit
import Foundation

extension AppViewModel {
    // MARK: - Snapshot

    func diagnosticsSnapshot() async -> DiagnosticsSnapshot {
        var s = DiagnosticsSnapshot()
        let bundle = Bundle.main
        s.appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        s.appPath = bundle.bundlePath
        s.builtAt = (try? bundle.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        LaunchAtLogin.shared.refresh()
        s.launchAtLogin = LaunchAtLogin.shared.isEnabled || LaunchAtLogin.shared.needsApproval
        s.mcpStatus = switch mcpServer.status {
        case .running: "running"
        case .starting: "starting"
        case .stopped: "stopped"
        case .failed(let message): "failed (\(message))"
        }
        s.mcpPort = mcpServer.port
        s.mcpToolCount = mcpServer.toolCount

        s.claudePathAtLaunch = ClaudeCodeService.locate()?.executableURL.path
        let claude = await Task.detached { () -> (String?, String?) in
            guard let url = ClaudeCodeService.findBinary() else { return (nil, nil) }
            return (url.path, Self.commandOutput(url, ["--version"], timeout: 5))
        }.value
        s.claudePathNow = claude.0
        s.claudeVersion = claude.1
        s.claudeModel = automationSettings.claudeModel

        for permission in OnboardingPermission.allCases {
            s.permissions[permission.rawValue] = await OnboardingPermissionCheck.state(of: permission)
        }

        s.transcriptionEngine = automationSettings.defaultTranscriptionModel
        s.parakeetInstalledFlag = parakeetModelInstalled
        s.parakeet = parakeetInstallDiagnostics
        s.parakeetInstalling = isInstallingParakeet
        s.parakeetProgress = parakeetDownloadProgress
        s.parakeetMessage = parakeetLoadingMessage
        s.parakeetLastError = parakeetLastError
        s.parakeetUpdate = switch parakeetUpdateState {
        case .unknown: "unknown"
        case .checking: "checking"
        case .upToDate: "up to date"
        case .available: "update available"
        case .failed: "check failed"
        }

        let speakers = speakerDiarizationModels
        speakers.refreshInstalledState()
        s.diarizationEnabled = automationSettings.speakerDiarizationEnabled
        s.diarizationEngine = automationSettings.diarizationEngine
        s.speakerModelsInstalled = speakers.isInstalled
        s.speakerModelsDownloading = speakers.isDownloading
        s.speakerModelsMessage = speakers.statusMessage
        s.nemotronInstalled = speakers.isNemotronInstalled
        s.nemotronDownloading = speakers.isDownloadingNemotron
        s.nemotronMessage = speakers.nemotronStatusMessage

        s.quickDictationEnabled = automationSettings.quickDictationEnabled
        s.quickDictationMode = automationSettings.quickDictationMode
        s.voiceAssistantEnabled = automationSettings.claudeTaskEnabled
        s.isRecording = isRecording
        s.recordingTitle = isRecording ? currentSession?.title : nil
        let devices = audioDeviceManager
        devices.refreshDevices()
        s.microphones = devices.inputDevices.map(\.name)
        s.microphone = devices.selectedInputDeviceID.flatMap { id in devices.inputDevices.first { $0.id == id }?.name } ?? "System Default"
        s.chosenMicrophoneMissing = MicrophonePreference.uid != nil && MicrophonePreference.resolvedDeviceID() == nil
        s.meetingDetection = meetingDetectionEnabled
        s.freeDiskBytes = recordingsFreeDiskBytes

        s.transcribingNow = transcriptionQueue.currentJob?.sessionTitle
        s.transcriptionsQueued = transcriptionQueue.pendingCount
        for (id, stage) in processingStage {
            s.processing[sessions.first { $0.id == id }?.title ?? id.uuidString] = stage.rawValue
        }
        let monthAgo = Date().addingTimeInterval(-30 * 86_400)
        s.failedMeetings = sessions
            .filter { $0.status == .failed && $0.createdAt > monthAgo }
            .sorted { $0.createdAt > $1.createdAt }
            .map {
                .init(id: $0.id, title: $0.title, date: $0.createdAt, error: $0.lastErrorMessage,
                      hasAudio: $0.micFileName != nil || $0.systemFileName != nil)
            }
        s.knowledgeJobsPending = knowledgeCurator.pending.count
        s.knowledgeJobRunning = knowledgeCurator.isRunning

        for project in projects where project.isShared {
            let status = sharedSync.status(for: project.id)
            var sync = DiagnosticsSnapshot.SharedProjectSync(
                id: project.id, name: project.name, state: "idle", problem: nil, lastSynced: status.lastSynced)
            switch status.state {
            case .idle: sync.state = "idle"
            case .syncing: sync.state = "syncing"
            case .problem(let text):
                sync.state = "problem"
                sync.problem = text
            }
            s.sharedProjects.append(sync)
        }

        let jobs = scheduledJobs
        if let running = jobs.running {
            s.jobRunning = jobTitle(running.key) + " (\(projectName(running.key.projectID)))"
        }
        s.jobsQueued = jobs.queue.count
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        s.failedJobRuns = jobs.latestRuns
            .filter { $0.value.status == .failed && $0.value.finished > weekAgo }
            .sorted { $0.value.finished > $1.value.finished }
            .map {
                .init(projectName: projectName($0.key.projectID), jobID: $0.key.jobID, jobTitle: jobTitle($0.key),
                      finished: $0.value.finished, headline: $0.value.headline)
            }
        s.recentErrors = recentErrors
        return s
    }

    private func projectName(_ id: UUID) -> String {
        id == ProjectRepositoryService.generalProjectID ? "General" : projects.first { $0.id == id }?.name ?? id.uuidString
    }

    private func jobTitle(_ key: ScheduledJobKey) -> String {
        scheduledJobs.jobsByProject[key.projectID]?.first { $0.id == key.jobID }?.title ?? key.jobID
    }

    /// First line a command prints, nil when it fails or takes longer than `timeout` seconds.
    nonisolated static func commandOutput(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Repairs

    enum RepairError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let message): message
            }
        }
    }

    /// Runs one repair and says what happened; long ones are started and reported as started.
    func runRepair(_ action: RepairAction, arguments: [String: String]) async throws -> String {
        switch action {
        case .installParakeet:
            guard !isInstallingParakeet else {
                return "Parakeet is already being installed (\(Int(parakeetDownloadProgress * 100)) %)."
            }
            Task { await installParakeetModel() }
            return "Started the Parakeet download (about 600 MB). Check progress and the result with get_app_status."
        case .verifyParakeet:
            guard parakeetInstallDiagnostics.markerPresent else {
                throw RepairError.failed("Parakeet is not installed; run install_parakeet.")
            }
            if let problem = await verifyParakeetModel() {
                throw RepairError.failed("Parakeet does not load: \(problem). Reinstall it with install_parakeet.")
            }
            return "Parakeet loads fine and is used for transcription."
        case .checkParakeetUpdate:
            guard parakeetModelInstalled else { throw RepairError.failed("Parakeet is not installed; run install_parakeet.") }
            await checkParakeetUpdate()
            return switch parakeetUpdateState {
            case .upToDate: "Parakeet is up to date."
            case .available: "A newer Parakeet is available; install_parakeet installs it."
            case .failed: "The update check failed (Hugging Face not reachable?)."
            default: "The update check did not finish."
            }
        case .installSpeakerModels:
            let store = speakerDiarizationModels
            guard !store.isDownloading else { return "The speaker models are already downloading." }
            Task { await store.downloadModels() }
            return "Started the speaker model download. Check get_app_status for the result."
        case .installNemotron:
            let store = speakerDiarizationModels
            guard !store.isDownloadingNemotron else { return "Nemotron 3 is already downloading." }
            Task { await store.downloadNemotronModels() }
            return "Started the Nemotron 3 download (about 190 MB). Check get_app_status for the result."
        case .requestPermission:
            guard let raw = arguments["permission"], let permission = OnboardingPermission(rawValue: raw) else {
                throw RepairError.failed("permission must be one of \(OnboardingPermission.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            NSApp.activate(ignoringOtherApps: true)
            let state = await OnboardingPermissionCheck.request(permission, calendarService: calendarService)
            return switch state {
            case .granted: "\(permission.title) is granted."
            case .pendingRestart: "macOS asked for \(permission.title). After the user allows it in System Settings, MinuteMind must be quit and reopened."
            case .denied: "\(permission.title) was refused before, so System Settings > Privacy & Security > \(permission.title) is open now: the user has to switch MinuteMind on there."
            case .notDetermined: "macOS shows its prompt for \(permission.title) (or System Settings); the user has to allow it there."
            }
        case .retryTranscription:
            guard let raw = arguments["meeting_id"], let id = UUID(uuidString: raw),
                  let session = sessions.first(where: { $0.id == id }) else {
                throw RepairError.failed("meeting_id must be the UUID of a meeting (see list_meetings).")
            }
            guard !session.status.isActive else { throw RepairError.failed("\"\(session.title)\" is recording or transcribing right now.") }
            guard session.micFileName != nil || session.systemFileName != nil else {
                throw RepairError.failed("\"\(session.title)\" has no audio left to transcribe.")
            }
            transcribeWithConfiguredEngine(sessionID: id)
            return "Queued \"\(session.title)\" for transcription with \(automationSettings.defaultTranscriptionModel); processing follows when it has a project."
        case .syncSharedProject:
            guard let raw = arguments["project_id"], let id = UUID(uuidString: raw),
                  let project = projects.first(where: { $0.id == id }), project.isShared else {
                throw RepairError.failed("project_id must be the UUID of a Shared Project (see list_projects).")
            }
            syncSharedProjectNow(id)
            return "Sync of \"\(project.name)\" started; get_app_status shows the result in a few seconds."
        case .rebuildSearchIndex:
            Task { await rebuildKnowledgeBase() }
            return "Rebuilding the knowledge search index in the background."
        case .refreshMicrophones:
            audioDeviceManager.refreshDevices()
            return "Microphones: " + audioDeviceManager.inputDevices.map(\.name).joined(separator: ", ")
        }
    }
}
