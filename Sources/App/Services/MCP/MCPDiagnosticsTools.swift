// Purpose: MCPDiagnosticsTools, the MCP tools Claude uses to debug MinuteMind for the user:
//          get_app_status (health report with detected issues, fixes and repair actions),
//          get_app_log (MinuteMind's own recent log lines) and run_repair.
// Dependencies: Sources/App/Help/AppDiagnostics.swift (snapshot, issue rules, RepairAction),
//               Sources/App/Help/AppLogReader.swift (log lines),
//               Sources/App/ViewModels/AppViewModel+Diagnostics.swift (snapshot, repairs),
//               Sources/App/Services/ToolExecutor.swift (ToolError)
// Used by: Sources/App/Services/MCP/MinuteMindMCPServer.swift
// RBAC: none inside the app; every MCP client holding the bearer token may read the report and the
//       log and run repairs. Repairs only (re)install models, ask macOS for permissions, retry
//       work or sync; none deletes data.
// Notes: Same OpenAI function shape as MCPMeetingTools. The report leads with `issues` so Claude
//        sees what is wrong before the raw state. Paths are included on purpose: they tell Claude
//        (and the user) which build and which model folder are in use.

import Foundation

@MainActor
struct MCPDiagnosticsTools {
    let appViewModel: AppViewModel

    static let names: Set<String> = ["get_app_status", "get_app_log", "run_repair"]

    static let sections = ["app", "claude", "permissions", "transcription", "speakers", "recording", "activity"]

    static var definitions: [[String: Any]] {
        [
            function(
                "get_app_status",
                "Health check of MinuteMind for debugging: detected issues first (each with severity, the problem, the fix to tell the user, and a run_repair action when the app can fix it itself), then the state behind them: app build, Claude Code, macOS permissions, Parakeet and speaker models (install files, download progress, last error), microphone, disk space, transcription and processing queues, failed meetings, Shared Project sync, failed jobs, recent error messages. Call it whenever something in MinuteMind does not work.",
                properties: [
                    "section": ["type": "string", "enum": sections, "description": "Optional: only this part of the state (issues are always included)."],
                ],
                required: []
            ),
            function(
                "get_app_log",
                "MinuteMind's own log lines from this run of the app (newest last). Many failures are only logged (knowledge curation, model loading, sync), so read it when get_app_status does not explain a problem.",
                properties: [
                    "since_minutes": ["type": "integer", "description": "How far back, 1 to 1440 minutes. Default 30."],
                    "contains": ["type": "string", "description": "Optional case-insensitive text the line must contain, e.g. \"parakeet\" or \"KnowledgeCurator\"."],
                    "errors_only": ["type": "boolean", "description": "Only errors and lines that read like failures. Default false."],
                    "limit": ["type": "integer", "description": "Maximum lines, 1 to 1000. Default 200."],
                ],
                required: []
            ),
            function(
                "run_repair",
                "Let MinuteMind fix a problem itself, usually one get_app_status suggested. Actions: "
                    + RepairAction.allCases.map { "\($0.rawValue): \($0.summary)" }.joined(separator: " ")
                    + " Tell the user what you started; downloads continue in the background.",
                properties: [
                    "action": ["type": "string", "enum": RepairAction.allCases.map(\.rawValue)],
                    "permission": [
                        "type": "string", "enum": OnboardingPermission.allCases.map(\.rawValue),
                        "description": "For request_permission.",
                    ] as [String: Any],
                    "meeting_id": ["type": "string", "description": "For retry_transcription: meeting UUID."],
                    "project_id": ["type": "string", "description": "For sync_shared_project: project UUID."],
                ],
                required: ["action"]
            ),
        ]
    }

    func execute(toolName: String, arguments: [String: Any]) async throws -> String {
        switch toolName {
        case "get_app_status":
            let snapshot = await appViewModel.diagnosticsSnapshot()
            return try json(Self.report(snapshot, section: arguments["section"] as? String))
        case "get_app_log":
            var query = AppLogReader.Query()
            query.sinceMinutes = min(max(Self.int(arguments["since_minutes"]) ?? 30, 1), 1440)
            query.limit = min(max(Self.int(arguments["limit"]) ?? 200, 1), 1000)
            query.contains = arguments["contains"] as? String
            query.errorsOnly = arguments["errors_only"] as? Bool ?? false
            let frozen = query
            let lines = try await Task.detached { try AppLogReader.read(frozen) }.value
            guard !lines.isEmpty else { return "No matching log lines in the last \(query.sinceMinutes) minutes." }
            return "\(lines.count) line(s), oldest first:\n" + lines.joined(separator: "\n")
        case "run_repair":
            guard let raw = arguments["action"] as? String, let action = RepairAction(rawValue: raw) else {
                throw ToolError.invalidArguments("action must be one of \(RepairAction.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let strings = arguments.compactMapValues { $0 as? String }
            return try await appViewModel.runRepair(action, arguments: strings)
        default:
            throw ToolError.invalidArguments("Unknown tool \(toolName)")
        }
    }

    // MARK: - Report

    static func report(_ s: DiagnosticsSnapshot, section: String?) -> [String: Any] {
        let found = AppDiagnostics.issues(in: s)
        let issues = found.map { issue -> [String: Any] in
            var entry: [String: Any] = [
                "id": issue.id, "severity": issue.severity.rawValue, "problem": issue.problem, "fix": issue.fix,
            ]
            if let repair = issue.repair {
                entry["repair"] = ["action": repair.rawValue].merging(issue.repairArguments) { first, _ in first }
            }
            return entry
        }
        var sections: [String: Any] = [
            "app": [
                "version": s.appVersion, "path": s.appPath, "built": iso(s.builtAt),
                "open_at_login": s.launchAtLogin,
                "mcp_server": ["status": s.mcpStatus, "port": s.mcpPort, "tools": s.mcpToolCount],
            ] as [String: Any],
            "claude": [
                "path_used_by_app": s.claudePathAtLaunch ?? "not found at launch",
                "path_now": s.claudePathNow ?? "not found",
                "version": s.claudeVersion ?? "unknown",
                "model_for_summaries": s.claudeModel,
            ],
            "permissions": s.permissions.mapValues { state -> String in
                switch state {
                case .granted: "granted"
                case .denied: "denied"
                case .notDetermined: "not asked yet"
                case .pendingRestart: "requested, needs restart or the switch in System Settings"
                }
            },
            "transcription": [
                "engine": s.transcriptionEngine,
                "parakeet": [
                    "usable": s.parakeetInstalledFlag,
                    "marker_present": s.parakeet.markerPresent,
                    "version": s.parakeet.version ?? "none",
                    "folder": s.parakeet.folder ?? "none",
                    "folder_exists": s.parakeet.folderExists,
                    "files_complete": s.parakeet.filesComplete,
                    "revision": s.parakeet.revision ?? "unknown",
                    "installed_at": iso(s.parakeet.installedAt),
                    "loaded_in_memory": s.parakeet.loadedInMemory,
                    "installing": s.parakeetInstalling,
                    "download_progress": s.parakeetProgress,
                    "status_message": s.parakeetMessage ?? "",
                    "last_install_error": s.parakeetLastError ?? "",
                    "update": s.parakeetUpdate,
                ] as [String: Any],
            ] as [String: Any],
            "speakers": [
                "identify_speakers": s.diarizationEnabled, "engine": s.diarizationEngine,
                "standard_models_installed": s.speakerModelsInstalled, "standard_models_downloading": s.speakerModelsDownloading,
                "standard_models_message": s.speakerModelsMessage ?? "",
                "nemotron_installed": s.nemotronInstalled, "nemotron_downloading": s.nemotronDownloading,
                "nemotron_message": s.nemotronMessage ?? "",
            ] as [String: Any],
            "recording": [
                "recording_now": s.isRecording, "recording_title": s.recordingTitle ?? "",
                "microphone": s.microphone, "chosen_microphone_missing": s.chosenMicrophoneMissing,
                "microphones_connected": s.microphones, "meeting_detection": s.meetingDetection,
                "quick_dictation": s.quickDictationEnabled, "quick_dictation_trigger": s.quickDictationMode,
                "voice_assistant": s.voiceAssistantEnabled,
                "free_disk_mb": s.freeDiskBytes.map { Int($0 / 1_000_000) } ?? -1,
            ] as [String: Any],
            "activity": [
                "transcribing_now": s.transcribingNow ?? "",
                "transcriptions_queued": s.transcriptionsQueued,
                "processing": s.processing,
                "failed_meetings_last_30_days": s.failedMeetings.map {
                    ["id": $0.id.uuidString, "title": $0.title, "date": iso($0.date), "error": $0.error ?? "", "has_audio": $0.hasAudio] as [String: Any]
                },
                "knowledge_jobs_pending": s.knowledgeJobsPending, "knowledge_job_running": s.knowledgeJobRunning,
                "shared_projects": s.sharedProjects.map {
                    ["id": $0.id.uuidString, "name": $0.name, "state": $0.state, "problem": $0.problem ?? "", "last_synced": iso($0.lastSynced)]
                },
                "job_running": s.jobRunning ?? "", "jobs_queued": s.jobsQueued,
                "failed_job_runs_last_7_days": s.failedJobRuns.map {
                    ["project": $0.projectName, "job_id": $0.jobID, "title": $0.jobTitle, "finished": iso($0.finished), "headline": $0.headline]
                },
                "recent_errors": s.recentErrors.map { ["date": iso($0.date), "message": $0.message] },
            ] as [String: Any],
        ]
        if let section, let only = sections[section] { sections = [section: only] }
        var report: [String: Any] = [
            "issues": issues,
            "summary": found.isEmpty
                ? "No problems detected."
                : "\(found.filter { $0.severity == .error }.count) error(s), \(found.filter { $0.severity == .warning }.count) warning(s), \(found.filter { $0.severity == .info }.count) note(s).",
        ]
        report.merge(sections) { first, _ in first }
        return report
    }

    private static func iso(_ date: Date?) -> String {
        date.map { ISO8601DateFormatter().string(from: $0) } ?? ""
    }

    private static func int(_ raw: Any?) -> Int? {
        (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap { Int($0) }
    }

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func function(
        _ name: String, _ description: String, properties: [String: Any], required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": ["type": "object", "properties": properties, "required": required] as [String: Any],
            ] as [String: Any],
        ]
    }
}
