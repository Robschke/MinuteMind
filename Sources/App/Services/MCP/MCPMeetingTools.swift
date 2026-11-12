// Purpose: MCPMeetingTools, the MCP-only tools for recorded meetings (list, read, rename, delete)
//          and knowledge base search, which the in-app assistant's ToolExecutor does not cover.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (sessions, projects, renameSession,
//               deleteSession, minutesURL, knowledgeStore),
//               Sources/App/Services/KnowledgeBaseTool.swift (search_knowledge_base schema + search)
// Used by: Sources/App/Services/MCP/MinuteMindMCPServer.swift
// RBAC: none inside the app. Every MCP client holding the bearer token gets full access,
//       including delete_meeting, as chosen by the user. Destructive tools are flagged with
//       destructiveHint so MCP clients ask before running them.
// Notes: Definitions use the same OpenAI function shape as AgentToolRegistry so the server can
//        convert both sources the same way. Results are JSON strings.

import Foundation

@MainActor
struct MCPMeetingTools {
    let appViewModel: AppViewModel

    static let names: Set<String> = [
        "list_meetings", "get_meeting", "rename_meeting", "delete_meeting", KnowledgeBaseTool.name,
        "list_inbox_meetings", "process_meetings",
        "list_dictionary", "add_dictionary_entry", "delete_dictionary_entry",
    ]

    static var definitions: [[String: Any]] {
        [
            function(
                "list_meetings",
                "List recorded meetings (newest first) with title, date, duration, project and whether a transcript and summary exist. Filter by project, date range or a text query that matches the title and transcript.",
                properties: [
                    "project_id": ["type": "string", "description": "Optional project UUID (see list_projects)."],
                    "query": ["type": "string", "description": "Optional case-insensitive text matched against title and transcript."],
                    "start_date": ["type": "string", "description": "Optional ISO8601 lower bound for the recording date."],
                    "end_date": ["type": "string", "description": "Optional ISO8601 upper bound for the recording date."],
                    "limit": ["type": "integer", "description": "Maximum number of meetings to return. Default 50."],
                ],
                required: []
            ),
            function(
                "get_meeting",
                "Get one meeting with its metadata, speakers, full transcript and AI summary (meeting minutes, Markdown).",
                properties: [
                    "meeting_id": ["type": "string", "description": "Meeting UUID from list_meetings."],
                    "include_transcript": ["type": "boolean", "description": "Include the transcript text. Default true."],
                    "include_minutes": ["type": "boolean", "description": "Include the AI summary. Default true."],
                ],
                required: ["meeting_id"]
            ),
            function(
                "list_inbox_meetings",
                "List meetings in the inbox: recorded or transcribed but not processed yet (no transcript cleanup, summary or knowledge). Use before process_meetings when the user asks to process their meetings.",
                properties: [:],
                required: []
            ),
            function(
                "process_meetings",
                "Process meetings: Claude cleans the transcript, then the summary, title, todos and knowledge are generated. Runs in the background inside MinuteMind; check progress with list_inbox_meetings.",
                properties: [
                    "meeting_ids": ["type": "array", "items": ["type": "string"], "description": "Meeting UUIDs. Omit to process every inbox meeting."],
                ],
                required: []
            ),
            function(
                "list_dictionary",
                "List the user's dictionary: terms MinuteMind must spell right and the forms speech recognition mishears them as.",
                properties: [:],
                required: []
            ),
            function(
                "add_dictionary_entry",
                "Add a term to the dictionary, optionally with misheard forms that should become it in transcripts (for example term 'Auth0', variants ['aus SEO']). Adding an existing term merges the variants.",
                properties: [
                    "term": ["type": "string", "description": "Correct spelling."],
                    "variants": ["type": "array", "items": ["type": "string"], "description": "Misheard forms to replace with the term."],
                ],
                required: ["term"]
            ),
            function(
                "delete_dictionary_entry",
                "Remove a term from the dictionary.",
                properties: [
                    "term": ["type": "string", "description": "The term to remove (case-insensitive)."],
                ],
                required: ["term"]
            ),
            function(
                "rename_meeting",
                "Rename a meeting. Also renames its export folder when the project exports files.",
                properties: [
                    "meeting_id": ["type": "string", "description": "Meeting UUID."],
                    "title": ["type": "string", "description": "New title."],
                ],
                required: ["meeting_id", "title"]
            ),
            function(
                "delete_meeting",
                "Permanently delete a meeting including its audio, transcript and summary. This cannot be undone.",
                properties: [
                    "meeting_id": ["type": "string", "description": "Meeting UUID."],
                ],
                required: ["meeting_id"]
            ),
            [
                "type": "function",
                "function": [
                    "name": KnowledgeBaseTool.name,
                    "description": "Search the MinuteMind knowledge base (facts, decisions and context extracted from meetings, notes and documents). Returns matching text chunks with their document title and category.",
                    "parameters": KnowledgeBaseTool.parametersSchema,
                ] as [String: Any],
            ],
        ]
    }

    func execute(toolName: String, arguments: [String: Any]) async throws -> String {
        switch toolName {
        case "list_meetings": return try listMeetings(arguments)
        case "get_meeting": return try getMeeting(arguments)
        case "rename_meeting": return try renameMeeting(arguments)
        case "delete_meeting": return try deleteMeeting(arguments)
        case KnowledgeBaseTool.name: return try await searchKnowledge(arguments)
        case "list_inbox_meetings": return try listInbox()
        case "process_meetings": return try processMeetings(arguments)
        case "list_dictionary":
            let entries = appViewModel.vocabulary.entries.map { ["term": $0.term, "variants": $0.variants] as [String: Any] }
            return try json(["count": entries.count, "entries": entries])
        case "add_dictionary_entry":
            guard let term = arguments["term"] as? String,
                  let entry = appViewModel.vocabulary.add(term: term, variants: arguments["variants"] as? [String] ?? [])
            else { throw ToolError.invalidArguments("term is required") }
            return try json(["success": true, "term": entry.term, "variants": entry.variants])
        case "delete_dictionary_entry":
            guard let term = arguments["term"] as? String,
                  let entry = appViewModel.vocabulary.entries.first(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame })
            else { throw ToolError.invalidArguments("No dictionary entry for that term") }
            appViewModel.vocabulary.delete(entry.id)
            return try json(["success": true, "deleted": entry.term])
        default: throw ToolError.invalidArguments("Unknown tool \(toolName)")
        }
    }

    // MARK: - Tools

    private func listMeetings(_ args: [String: Any]) throws -> String {
        var sessions = appViewModel.sessions
        if let raw = args["project_id"] as? String {
            let projectID = try uuid(raw, field: "project_id")
            sessions = sessions.filter { $0.projectID == projectID }
        }
        if let raw = args["start_date"] as? String {
            let start = try date(raw, field: "start_date")
            sessions = sessions.filter { $0.createdAt >= start }
        }
        if let raw = args["end_date"] as? String {
            let end = try date(raw, field: "end_date")
            sessions = sessions.filter { $0.createdAt <= end }
        }
        if let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            sessions = sessions.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || ($0.transcript?.text.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        let limit = max(1, (args["limit"] as? Int) ?? 50)
        let result = sessions.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map(summary)
        return try json(["count": result.count, "meetings": Array(result)])
    }

    private func getMeeting(_ args: [String: Any]) throws -> String {
        let session = try session(args)
        var result = summary(session)
        let speakers = (session.speakerProfiles ?? []).map { ["label": $0.label, "name": $0.name ?? NSNull()] as [String: Any] }
        if !speakers.isEmpty { result["speakers"] = speakers }
        if session.calendarNotes?.isEmpty == false { result["calendar_notes"] = session.calendarNotes }
        if (args["include_transcript"] as? Bool) ?? true {
            result["transcript"] = session.transcript?.text ?? NSNull()
        }
        if (args["include_minutes"] as? Bool) ?? true {
            let minutes = appViewModel.minutesURL(for: session).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            result["minutes"] = minutes ?? NSNull()
        }
        return try json(result)
    }

    private func renameMeeting(_ args: [String: Any]) throws -> String {
        let session = try session(args)
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw ToolError.invalidArguments("title must not be empty")
        }
        appViewModel.renameSession(session, newTitle: title)
        return try json(["success": true, "meeting_id": session.id.uuidString, "title": title])
    }

    private func deleteMeeting(_ args: [String: Any]) throws -> String {
        let session = try session(args)
        guard !session.status.isActive else {
            throw ToolError.invalidArguments("Meeting is recording or transcribing right now and cannot be deleted.")
        }
        appViewModel.deleteSession(session)
        return try json(["success": true, "deleted_meeting_id": session.id.uuidString, "title": session.title])
    }

    private func searchKnowledge(_ args: [String: Any]) async throws -> String {
        guard let store = appViewModel.knowledgeStore else {
            throw ToolError.invalidArguments("Knowledge base is not available.")
        }
        guard let query = args["query"] as? String, !query.isEmpty else {
            throw ToolError.invalidArguments("query is required")
        }
        let projectID = try (args["projectID"] as? String).map { try uuid($0, field: "projectID") }
        let results = try await KnowledgeBaseTool.execute(query: query, projectID: projectID, store: store)
        let items: [[String: Any]] = results.map { entry in
            [
                "document_id": entry.document.id.map { $0 as Any } ?? NSNull(),
                "title": entry.document.title,
                "category": entry.document.category,
                "project_id": entry.document.projectID?.uuidString ?? NSNull(),
                "content": entry.chunk.content,
            ]
        }
        return try json(["count": items.count, "results": items])
    }

    private func listInbox() throws -> String {
        let meetings: [[String: Any]] = appViewModel.inboxSessions.map { session in
            var item = summary(session)
            item["processing"] = appViewModel.processingStage[session.id]?.rawValue ?? NSNull()
            return item
        }
        return try json(["count": meetings.count, "meetings": meetings])
    }

    private func processMeetings(_ args: [String: Any]) throws -> String {
        let ids: [UUID]
        if let raw = args["meeting_ids"] as? [String], !raw.isEmpty {
            ids = try raw.map { try uuid($0, field: "meeting_ids") }
            for id in ids where !appViewModel.sessions.contains(where: { $0.id == id }) {
                throw ToolError.invalidArguments("No meeting with id \(id.uuidString)")
            }
            ids.forEach(appViewModel.processMeeting)
        } else {
            ids = appViewModel.inboxSessions.map(\.id)
            appViewModel.processAllInbox()
        }
        return try json(["started": ids.count, "meeting_ids": ids.map(\.uuidString)])
    }

    // MARK: - Helpers

    private func summary(_ session: RecordingSession) -> [String: Any] {
        let project = session.projectID.flatMap { id in appViewModel.projects.first { $0.id == id } }
        var result: [String: Any] = [
            "id": session.id.uuidString,
            "title": session.title,
            "recorded_at": ISO8601DateFormatter().string(from: session.createdAt),
            "status": session.status.rawValue,
            "has_transcript": session.transcript != nil,
            "has_minutes": session.meetingMinutesFileName != nil,
        ]
        if let duration = session.duration { result["duration_minutes"] = Int((duration / 60).rounded()) }
        if let project {
            result["project_id"] = project.id.uuidString
            result["project_name"] = project.name
        }
        if let event = session.calendarEventTitle { result["calendar_event"] = event }
        if let attendees = session.calendarAttendees, !attendees.isEmpty { result["attendees"] = attendees }
        return result
    }

    private func session(_ args: [String: Any]) throws -> RecordingSession {
        guard let raw = args["meeting_id"] as? String else { throw ToolError.invalidArguments("meeting_id is required") }
        let id = try uuid(raw, field: "meeting_id")
        guard let session = appViewModel.sessions.first(where: { $0.id == id }) else {
            throw ToolError.invalidArguments("No meeting with id \(raw)")
        }
        return session
    }

    private func uuid(_ raw: String, field: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else { throw ToolError.invalidArguments("\(field) is not a valid UUID") }
        return id
    }

    private func date(_ raw: String, field: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withFullDate]
        if let date = formatter.date(from: raw) { return date }
        throw ToolError.invalidArguments("\(field) is not an ISO8601 date")
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
