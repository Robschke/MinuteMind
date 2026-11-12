// Purpose: MCPHelpTools, the MCP tools that let Claude help people with MinuteMind itself: get_help
//          (the user guide: topic index, one topic, or a search), list_settings (every setting with
//          its current value, options and place in Settings) and update_setting.
// Dependencies: Sources/App/Help/HelpGuide.swift (guide), Sources/App/Help/AppSettingsCatalog.swift
//               and AppSetting.swift (settings), Sources/App/Services/ToolExecutor.swift (ToolError)
// Used by: Sources/App/Services/MCP/MinuteMindMCPServer.swift
// RBAC: none inside the app; every MCP client holding the bearer token may read the guide and the
//       settings and change the writable ones. The MCP server's own settings are read-only in the
//       catalog, so a client cannot lock itself or others out.
// Notes: Same OpenAI function shape as MCPMeetingTools. get_help answers in Markdown (it is prose
//        Claude reads), the settings tools in JSON. A topic comes with its settings and their
//        current values, so one call answers both "how does X work" and "how is X set up for me".

import Foundation

@MainActor
struct MCPHelpTools {
    let appViewModel: AppViewModel

    static let names: Set<String> = ["get_help", "list_settings", "update_setting"]

    static var definitions: [[String: Any]] {
        [
            function(
                "get_help",
                "The MinuteMind user guide. Call it first whenever the user asks how MinuteMind works, where something is, what a feature or setting does, or how to do something in the app. Without arguments: an overview and the list of topics. With topic: that topic in full plus its settings and their current values. With query: the topics and passages matching the words.",
                properties: [
                    "topic": ["type": "string", "description": "Topic id or title from the topic list, e.g. \"inbox\" or \"quick-dictation\"."],
                    "query": ["type": "string", "description": "Words to search the guide for, e.g. \"fn key dictation language\"."],
                ],
                required: []
            ),
            function(
                "list_settings",
                "List MinuteMind's settings with their current values, allowed options, what they do and where they are in the Settings window. Use before update_setting, and to answer \"how is X set\" questions.",
                properties: [
                    "query": ["type": "string", "description": "Optional words matched against id, title, place and description, e.g. \"dictation\"."],
                    "help_topic": ["type": "string", "description": "Optional guide topic id: only the settings of that topic."],
                ],
                required: []
            ),
            function(
                "update_setting",
                "Change one MinuteMind setting, the same as changing it in the Settings window (it takes effect at once). Get the id and the allowed values from list_settings. Tell the user what changed and where they find it in Settings.",
                properties: [
                    "id": ["type": "string", "description": "Setting id from list_settings, e.g. \"double_tap_to_record\"."],
                    "value": [
                        "type": ["string", "boolean", "number"],
                        "description": "New value: true/false for switches, an option value (or its label) for choices, text for text settings.",
                    ] as [String: Any],
                ],
                required: ["id", "value"]
            ),
        ]
    }

    func execute(toolName: String, arguments: [String: Any]) throws -> String {
        switch toolName {
        case "get_help": return getHelp(arguments)
        case "list_settings": return try listSettings(arguments)
        case "update_setting": return try updateSetting(arguments)
        default: throw ToolError.invalidArguments("Unknown tool \(toolName)")
        }
    }

    // MARK: - get_help

    private func getHelp(_ arguments: [String: Any]) -> String {
        if let raw = (arguments["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let topic = HelpGuide.topic(raw) { return render(topic) }
            let hits = HelpGuide.search(raw, limit: 3)
            if hits.count == 1 || (hits.first?.score ?? 0) >= 6 { return render(hits[0].topic) }
            return "No topic \"\(raw)\".\n\n" + index()
        }
        if let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            let hits = HelpGuide.search(query)
            guard !hits.isEmpty else { return "Nothing in the guide matches \"\(query)\".\n\n" + index() }
            var text = "# Guide passages for \"\(query)\"\n\nCall get_help with a topic id for the whole topic.\n"
            for hit in hits {
                text += "\n## \(hit.topic.title) (topic: \(hit.topic.id))\n\n" + hit.excerpts.joined(separator: "\n\n") + "\n"
            }
            return text
        }
        return index()
    }

    private func index() -> String {
        var text = """
        # MinuteMind help

        MinuteMind is a Mac app that records meetings, transcribes them on the Mac and has Claude write summaries, titles, todos and project knowledge, with a Claude Code workspace per project and a desktop companion for recording, dictation and Claude.

        Besides this guide you can: list_settings / update_setting to read and change settings, open_in_app to show the user a place in the app (a Settings page, Inbox, a project tab), start_recording / stop_recording, get_app_status / get_app_log / run_repair to find and fix problems, and the data tools (meetings, tasks, calendar, knowledge, jobs, dictionary). When the user asks how to do something, explain it, and offer to do it for them when a tool can. When something does not work, start with get_app_status.

        ## Topics (call get_help with the id)

        """
        for topic in HelpGuide.topics {
            text += "- `\(topic.id)`: **\(topic.title)**. \(topic.summary)\n"
        }
        return text
    }

    private func render(_ topic: HelpGuideTopic) -> String {
        var text = "# \(topic.title)\n\n\(topic.body)\n"
        let settings = AppSettingsCatalog.all.filter { $0.helpTopic == topic.id }
        if !settings.isEmpty {
            text += "\n## Settings for this topic (current values)\n\n"
            for setting in settings {
                let value = describe(setting.read(appViewModel), of: setting)
                let lock = setting.isWritable ? "" : " (read-only: \(setting.readOnlyReason ?? "not changeable here"))"
                text += "- `\(setting.id)` \"\(setting.title)\" (\(setting.location)): \(value)\(lock)\n"
            }
            text += "\nChange one with update_setting; list_settings shows the options.\n"
        }
        return text
    }

    private func describe(_ value: AppSetting.Value, of setting: AppSetting) -> String {
        switch value {
        case .bool(let flag): return flag ? "on" : "off"
        case .string(let text):
            if setting.kind == .choice, let option = setting.options?(appViewModel).first(where: { $0.value == text }) {
                return option.label == option.value ? option.label : "\(option.label) (\(option.value))"
            }
            return text.isEmpty ? "(empty)" : "\"\(text)\""
        }
    }

    // MARK: - Settings

    private func listSettings(_ arguments: [String: Any]) throws -> String {
        var settings = AppSettingsCatalog.all
        if let topic = (arguments["help_topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
            settings = settings.filter { $0.helpTopic == topic }
        }
        if let query = arguments["query"] as? String {
            let words = HelpGuide.searchWords(query)
            if !words.isEmpty {
                settings = settings.filter { setting in
                    let haystack = [setting.id, setting.title, setting.location, setting.summary, setting.helpTopic]
                        .joined(separator: " ").lowercased()
                    return words.contains { haystack.contains($0) }
                }
            }
        }
        return try json([
            "count": settings.count,
            "settings": settings.map(entry),
            "note": "Change one with update_setting(id, value). Not listed: dictionary entries (dictionary tools), summary prompt texts, custom theme colours, the voice library and model installs (Settings window).",
        ])
    }

    private func entry(_ setting: AppSetting) -> [String: Any] {
        var entry: [String: Any] = [
            "id": setting.id,
            "title": setting.title,
            "location": setting.location,
            "description": setting.summary,
            "help_topic": setting.helpTopic,
            "type": typeName(setting.kind),
            "value": setting.read(appViewModel).jsonValue,
            "writable": setting.isWritable,
        ]
        if let options = setting.options?(appViewModel) {
            entry["options"] = options.map { ["value": $0.value, "label": $0.label] }
        }
        if let reason = setting.readOnlyReason { entry["read_only_reason"] = reason }
        return entry
    }

    private func typeName(_ kind: AppSetting.Kind) -> String {
        switch kind {
        case .toggle: "boolean"
        case .choice: "choice"
        case .text: "text"
        case .timesOfDay: "times of day (\"09:00, 14:30\")"
        case .colour: "\"default\" or \"#RRGGBB\""
        }
    }

    private func updateSetting(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments["id"] as? String, !id.isEmpty else { throw ToolError.invalidArguments("id is required") }
        guard let raw = arguments["value"], !(raw is NSNull) else { throw ToolError.invalidArguments("value is required") }
        guard let setting = AppSettingsCatalog.setting(id) else {
            throw ToolError.invalidArguments("No setting \"\(id)\". Call list_settings for the ids.")
        }
        guard setting.isWritable, let write = setting.write else {
            throw ToolError.custom("\(setting.title) cannot be changed by Claude. \(setting.readOnlyReason ?? "")")
        }
        let value = try setting.parse(raw, choices: setting.options?(appViewModel) ?? [])
        let previous = setting.read(appViewModel)
        let note = try write(appViewModel, value)
        let current = setting.read(appViewModel)
        var result: [String: Any] = [
            "id": setting.id,
            "title": setting.title,
            "location": setting.location,
            "previous_value": previous.jsonValue,
            "value": current.jsonValue,
            "changed": previous != current,
        ]
        if let note { result["note"] = note }
        return try json(result)
    }

    // MARK: - Helpers

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
