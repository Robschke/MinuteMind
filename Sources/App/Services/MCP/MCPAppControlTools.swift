// Purpose: MCPAppControlTools, MCP tools that act on the running app: open_in_app (bring a Settings
//          page, a sidebar destination or a project tab to the front) and start_recording /
//          stop_recording.
// Dependencies: Sources/App/ViewModels/AppViewModel+AppControl.swift (show, startRecordingFromClaude,
//               stopRecordingFromClaude), Sources/App/Views/MeetingMinutesSettingsView.swift (Tab),
//               Sources/App/Views/ProjectDetailView.swift (ProjectTab),
//               Sources/App/Services/ToolExecutor.swift (ToolError)
// Used by: Sources/App/Services/MCP/MinuteMindMCPServer.swift
// RBAC: none inside the app; every MCP client holding the bearer token may use them. Recording
//       follows the same rules as the record button (a project needs an export folder or the
//       opt-out), and stop_recording only ends a recording, it never deletes one.
// Notes: Same OpenAI function shape as MCPMeetingTools. Settings pages and project tabs are matched
//        by their visible names, case-insensitively, so "Integrations" and "integrations" both work.

import Foundation

@MainActor
struct MCPAppControlTools {
    let appViewModel: AppViewModel

    static let names: Set<String> = ["open_in_app", "start_recording", "stop_recording"]

    static let places = ["settings", "all_transcripts", "inbox", "all_tasks", "calendar", "clipboard", "project", "general"]

    static var definitions: [[String: Any]] {
        [
            function(
                "open_in_app",
                "Bring MinuteMind to the front on a place, to show the user where something is: a Settings page, a sidebar destination, a project (optionally on a tab) or General. Pair it with explanations (\"I opened Settings > Automation for you\").",
                properties: [
                    "place": ["type": "string", "enum": places, "description": "Where to go."],
                    "settings_page": [
                        "type": "string",
                        "enum": MeetingMinutesSettingsView.Tab.allCases.map(\.rawValue),
                        "description": "With place settings: the page. Default Automation.",
                    ] as [String: Any],
                    "project_id": ["type": "string", "description": "With place project: project UUID (see list_projects)."],
                    "project_tab": [
                        "type": "string",
                        "enum": ProjectTab.allCases.map(\.rawValue),
                        "description": "With place project or general: the tab (General has Workspace and Jobs).",
                    ] as [String: Any],
                ],
                required: ["place"]
            ),
            function(
                "start_recording",
                "Start recording a meeting now (microphone and system audio), like the record button. Only when the user asks for it. Fails when a recording is already running or the project has no export folder set up.",
                properties: [
                    "project_id": ["type": "string", "description": "Optional project UUID (see list_projects) to file the meeting to; omit to use the record picker's current choice."],
                    "title": ["type": "string", "description": "Optional meeting title."],
                ],
                required: []
            ),
            function(
                "stop_recording",
                "Stop the running recording, like the Stop button. Transcription starts by itself; processing follows once it has a project.",
                properties: [:],
                required: []
            ),
        ]
    }

    func execute(toolName: String, arguments: [String: Any]) async throws -> String {
        switch toolName {
        case "open_in_app": return try openInApp(arguments)
        case "start_recording":
            let projectID = try (arguments["project_id"] as? String).map(uuid)
            let session = try await appViewModel.startRecordingFromClaude(projectID: projectID, title: arguments["title"] as? String)
            return try json([
                "recording": true, "meeting_id": session.id.uuidString, "title": session.title,
                "project": projectName(session) ?? "none",
            ])
        case "stop_recording":
            let session = try await appViewModel.stopRecordingFromClaude()
            return try json([
                "recording": false, "meeting_id": session.id.uuidString, "title": session.title,
                "project": projectName(session) ?? "none",
                "note": session.projectID == nil && session.assignedToGeneral != true
                    ? "The meeting has no project yet: the companion asks the user, or assign one in the Inbox." : "Transcription and processing follow by themselves.",
            ])
        default: throw ToolError.invalidArguments("Unknown tool \(toolName)")
        }
    }

    private func openInApp(_ arguments: [String: Any]) throws -> String {
        let place = (arguments["place"] as? String ?? "").lowercased()
        let destination: AppViewModel.AppDestination
        switch place {
        case "settings":
            let raw = arguments["settings_page"] as? String ?? MeetingMinutesSettingsView.Tab.automation.rawValue
            guard let tab = MeetingMinutesSettingsView.Tab.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) else {
                throw ToolError.invalidArguments("Unknown settings_page \(raw).")
            }
            destination = .settings(tab)
        case "all_transcripts": destination = .allTranscripts
        case "inbox": destination = .inbox
        case "all_tasks": destination = .allTasks
        case "calendar": destination = .calendar
        case "clipboard": destination = .clipboard
        case "project", "general":
            let id: UUID
            if place == "general" {
                id = ProjectRepositoryService.generalProjectID
            } else {
                guard let raw = arguments["project_id"] as? String else { throw ToolError.invalidArguments("project_id is required for place project") }
                id = try uuid(raw)
            }
            destination = .project(id, try projectTab(arguments["project_tab"] as? String))
        default:
            throw ToolError.invalidArguments("place must be one of \(Self.places.joined(separator: ", ")).")
        }
        try appViewModel.show(destination)
        return try json(["opened": place, "ok": true])
    }

    private func projectTab(_ raw: String?) throws -> ProjectTab? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let tab = ProjectTab.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) else {
            throw ToolError.invalidArguments("project_tab must be one of \(ProjectTab.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return tab
    }

    private func projectName(_ session: RecordingSession) -> String? {
        if session.assignedToGeneral == true { return "General" }
        return session.projectID.flatMap { id in appViewModel.projects.first { $0.id == id }?.name }
    }

    private func uuid(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else { throw ToolError.invalidArguments("\(raw) is not a valid UUID") }
        return id
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
