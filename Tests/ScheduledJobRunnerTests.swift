// Purpose: Tests for the scheduled job command line: which built-in, MinuteMind and connector tools
//          each access level allows or blocks, and the rules handed to Claude.
// Dependencies: Sources/App/Services/ScheduledJobRunner.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("ScheduledJobRunner Tests")
struct ScheduledJobRunnerTests {
    private let tools = ["list_meetings", "get_meeting", "search_knowledge_base", "create_project_task", "delete_meeting", "delete_job", "run_job_now"]
    private let config = URL(fileURLWithPath: "/tmp/claude-mcp.json")

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
    }

    @Test("Read only: no writing tools, only MinuteMind's list/get/search tools, nothing unlisted runs")
    func readOnly() {
        let args = ScheduledJobRunner.arguments(access: .readOnly, model: "haiku", systemPrompt: "rules", mcpConfig: config, minuteMindTools: tools)
        #expect(value(after: "--tools", in: args) == "Read,Glob,Grep,WebSearch,WebFetch")
        let allowed = value(after: "--allowedTools", in: args) ?? ""
        #expect(allowed.contains("mcp__minutemind__list_meetings"))
        #expect(allowed.contains("mcp__minutemind__search_knowledge_base"))
        #expect(!allowed.contains("create_project_task"))
        #expect(!allowed.contains("run_job_now"))
        #expect(!allowed.contains("mcp__minutemind,"))
        #expect(value(after: "--permission-mode", in: args) == "dontAsk")
        #expect(value(after: "--disallowedTools", in: args)
            == "mcp__minutemind__create_project_task,mcp__minutemind__delete_job,mcp__minutemind__delete_meeting,mcp__minutemind__run_job_now")
        #expect(value(after: "--model", in: args) == "haiku")
    }

    @Test("Standard: files and MinuteMind writable, deletes blocked, no shell")
    func standard() {
        let args = ScheduledJobRunner.arguments(access: .standard, model: "sonnet", systemPrompt: "rules", mcpConfig: config, minuteMindTools: tools)
        #expect(value(after: "--tools", in: args) == "Read,Glob,Grep,WebSearch,WebFetch,Edit,Write")
        #expect(value(after: "--permission-mode", in: args) == "acceptEdits")
        #expect(value(after: "--allowedTools", in: args)?.hasSuffix("mcp__minutemind") == true)
        #expect(value(after: "--disallowedTools", in: args) == "mcp__minutemind__delete_job,mcp__minutemind__delete_meeting")
    }

    @Test("Full: shell and every MinuteMind tool")
    func full() {
        let args = ScheduledJobRunner.arguments(access: .full, model: "opus", systemPrompt: "rules", mcpConfig: config, minuteMindTools: tools)
        #expect(value(after: "--tools", in: args)?.hasSuffix("Bash") == true)
        #expect(!args.contains("--disallowedTools"))
        #expect(value(after: "--mcp-config", in: args) == config.path)
    }

    @Test("Without the MCP server no MinuteMind tools are configured")
    func withoutMCP() {
        let args = ScheduledJobRunner.arguments(access: .standard, model: "sonnet", systemPrompt: "rules", mcpConfig: nil, minuteMindTools: tools)
        #expect(!args.contains("--mcp-config"))
        #expect(!args.contains("--disallowedTools"))
        #expect(value(after: "--allowedTools", in: args)?.contains("mcp__") == false)
    }

    @Test("Every level loads the user settings for the connectors, with the gate hook and an explicit mode")
    func connectorsLoad() throws {
        for access in [ScheduledJob.Access.readOnly, .standard, .full] {
            let args = ScheduledJobRunner.arguments(access: access, model: "sonnet", systemPrompt: "rules", mcpConfig: config, minuteMindTools: tools)
            #expect(value(after: "--setting-sources", in: args) == "user")
            #expect(!args.contains("--strict-mcp-config"))
            #expect(args.contains("--permission-mode"))
            let settings = try #require(value(after: "--settings", in: args))
            let object = try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any]
            let hooks = object?["hooks"] as? [String: Any]
            let entry = (hooks?["PreToolUse"] as? [[String: Any]])?.first
            #expect(entry?["matcher"] as? String == "mcp__.*")
        }
    }

    /// Runs the gate hook like Claude Code does: the PreToolUse payload on stdin. Returns the
    /// decision, or nil when the hook leaves the tool to the normal permission rules.
    private func gate(_ tool: String, _ access: ScheduledJob.Access) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ScheduledJobRunner.connectorGateCommand(access: access)]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse", "tool_name": tool,
            "tool_input": ["text": "\"tool_name\": \"mcp__claude_ai_Slack__slack_read_channel\""],
        ]
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !data.isEmpty else { return nil }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String
    }

    @Test("Read only: connector tools that read are allowed, writing and unknown ones denied")
    func readOnlyConnectorGate() throws {
        for tool in [
            "mcp__claude_ai_Microsoft_365__outlook_email_search", "mcp__claude_ai_Microsoft_365__get_me",
            "mcp__claude_ai_Microsoft_365__teams_list_chats", "mcp__claude_ai_Microsoft_365__read_resource",
            "mcp__claude_ai_Slack__slack_read_channel", "mcp__claude_ai_Slack__slack_search_public_and_private",
            "mcp__claude_ai_Slack__slack_get_reactions",
        ] {
            #expect(try gate(tool, .readOnly) == "allow", "\(tool)")
        }
        for tool in [
            "mcp__claude_ai_Slack__slack_send_message", "mcp__claude_ai_Slack__slack_send_message_draft",
            "mcp__claude_ai_Slack__slack_schedule_message", "mcp__claude_ai_Slack__slack_get_file_upload_url",
            "mcp__claude_ai_Slack__slack_update_canvas", "mcp__claude_ai_Slack__slack_add_reaction",
            "mcp__claude_ai_Gmail__create_draft", "mcp__claude_ai_Figma__use_figma",
        ] {
            #expect(try gate(tool, .readOnly) == "deny", "\(tool)")
        }
    }

    @Test("Standard and Full: every connector tool; other MCP servers never; MinuteMind left to the lists")
    func connectorGateByLevel() throws {
        for access in [ScheduledJob.Access.standard, .full] {
            #expect(try gate("mcp__claude_ai_Slack__slack_send_message", access) == "allow")
        }
        for access in [ScheduledJob.Access.readOnly, .standard, .full] {
            #expect(try gate("mcp__atlassian__createJiraIssue", access) == "deny")
            #expect(try gate("mcp__plugin_x_server__search", access) == "deny")
            #expect(try gate("mcp__minutemind__delete_meeting", access) == nil)
        }
    }

    @Test("The rules name the job, the workspace, the access and where the result goes")
    func systemPrompt() {
        var job = ScheduledJob(id: "daily-brief", title: "Daily Brief", prompt: "p")
        job.access = .readOnly
        let id = UUID()
        let prompt = ScheduledJobRunner.systemPrompt(job: job, workspaceName: "Acme", projectID: id, isGeneral: false, now: Date())
        #expect(prompt.contains("\"Daily Brief\""))
        #expect(prompt.contains("project \"Acme\" (project id \(id.uuidString))"))
        #expect(prompt.contains("You may only read"))
        #expect(prompt.contains("connected services"))
        #expect(prompt.contains("jobs/daily-brief/runs/"))
        let general = ScheduledJobRunner.systemPrompt(job: job, workspaceName: "General", projectID: id, isGeneral: true, now: Date())
        #expect(general.contains("General workspace"))
    }
}
