// Purpose: ClaudeAssistantService, the voice assistant behind a triple tap of the dictation key:
//          Claude Code runs headless as a small agent with MinuteMind's tools, the web and (if
//          allowed) the terminal, decides itself whether to answer or to act, and reports back in a
//          tiny protocol (PASTE, DONE, ASK) the app turns into an insert, a result card or a
//          question bubble. Questions continue the same Claude session.
// Dependencies: Sources/App/Services/ClaudeCodeService.swift (runs the CLI, JSON output),
//               Sources/App/Services/ClaudeTaskService.swift (model list, chat links)
// Used by: Sources/App/Supporting/QuickDictationController.swift (runs requests, answers questions)
// Notes: User request 2026-10-13: the mini task should not just paste what Claude printed. It
//        should act when the request is an action ("write down this todo") and only hand text back
//        when text is wanted; selected text comes along as context; when Claude needs something it
//        asks through a bubble at the companion. Decisions:
//        - One run per request, no separate routing step: Claude sees the request and its tools
//          and decides. Its final message ends in exactly one marker line, PASTE: (text for the
//          cursor), DONE: (what it did) or ASK: (a question); anything without a marker counts as
//          text to hand back.
//        - Tools: the MinuteMind MCP server (tasks, calendar, notes, reminders, meetings,
//          knowledge, dictionary) and web search/fetch are always allowed without prompts; the
//          terminal (Bash, Read) when Settings allow it (user decision: explicitly wanted, on by
//          default). Deleting in MinuteMind is blocked (`--disallowedTools`), so Claude has to
//          ask instead. Nothing else: strict MCP config, no user settings, no CLAUDE.md.
//        - Runs in its own folder (App Support/MinuteMind/Assistant) with session persistence, so a
//          question can be answered with `--resume <session id>`.
//        - Claude Code's own system prompt stays (it knows how to use tools); the assistant rules
//          are appended.

import Foundation

/// What Claude wants done with its result.
enum ClaudeAssistantOutcome: Equatable {
    /// Text for the user: inserted at the cursor, or shown in a card.
    case paste(String)
    /// Claude did something; a one-line summary plus optional details.
    case done(summary: String, details: String)
    /// Claude needs an answer to go on.
    case ask(String)

    /// Reads the marker line from Claude's final message: the last line that starts with
    /// PASTE:, DONE: or ASK: wins and everything after it belongs to it. No marker: all text.
    static func parse(_ text: String) -> ClaudeAssistantOutcome {
        let lines = text.components(separatedBy: "\n")
        for index in lines.indices.reversed() {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            for marker in ["PASTE:", "DONE:", "ASK:"] where line.uppercased().hasPrefix(marker) {
                let first = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                let rest = lines[(index + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                switch marker {
                case "PASTE:":
                    return .paste([first, rest].filter { !$0.isEmpty }.joined(separator: "\n"))
                case "DONE:":
                    return .done(summary: first.isEmpty ? "Done" : first, details: rest)
                default:
                    return .ask([first, rest].filter { !$0.isEmpty }.joined(separator: "\n"))
                }
            }
        }
        return .paste(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Where the request came from: the selected text and the app the user was in.
struct ClaudeAssistantContext: Equatable {
    var selection: String?
    var appName: String?
    var windowTitle: String?
}

enum ClaudeAssistantService {
    /// MinuteMind tools Claude may not use without asking the user.
    static let blockedTools = [
        "delete_calendar_event", "delete_dictionary_entry", "delete_meeting",
        "delete_note", "delete_project_task", "delete_reminder",
    ].map { "mcp__minutemind__\($0)" }

    static let rules = """
        You are the user's voice assistant on their Mac. They called you with a triple tap of a key \
        from whatever app they were in and spoke a request. The request comes from speech \
        recognition and may contain misheard words; infer what was meant. Answer in the language \
        of the request unless it asks for another.

        Decide what the request needs:
        - An action (add a todo, create a calendar event, take a note, set a reminder, look \
        something up in their meetings or knowledge, \(terminalHint)): do it right away with your \
        tools, without asking for confirmation, then report it.
        - Text (an answer, a draft, a reply, a rewrite or translation of the selected text): write it.
        - Only if you truly cannot proceed without the user: ask one short question.
        Deleting things in MinuteMind is not available to you; if the user wants something \
        deleted, ask them to confirm and say exactly what would be deleted.

        End your final message with exactly one of these, on its own line, with nothing after it \
        that does not belong to it:
        PASTE: <the text>   text meant to be inserted where the user's cursor is; plain text, no \
        Markdown, no preamble, no quotation marks around it. It may continue on the next lines.
        DONE: <one line saying what you did>   optionally followed by a few lines of details.
        ASK: <one short question>
        Put nothing before the marker except your tool use.
        """

    private static let terminalHint = "run something in the terminal"

    /// The system prompt to append: the rules, the terminal note and the user's own instructions.
    static func systemPrompt(userInstructions: String, allowsTerminal: Bool) -> String {
        var prompt = allowsTerminal
            ? rules
            : rules.replacingOccurrences(of: ", \(terminalHint)", with: "")
                + "\nYou cannot run terminal commands; say so if the request needs one."
        let extra = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { prompt += "\n\nThe user's standing instructions:\n" + extra }
        return prompt
    }

    /// The request with its context, clearly delimited.
    static func prompt(request: String, context: ClaudeAssistantContext) -> String {
        var parts: [String] = []
        if let app = context.appName, !app.isEmpty {
            let title = context.windowTitle.map { $0.isEmpty ? "" : " (window \"\($0)\")" } ?? ""
            parts.append("The user was in \(app)\(title).")
        }
        if let selection = context.selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty {
            parts.append("Text they had selected:\n<selection>\n\(selection)\n</selection>")
        }
        parts.append("Their request:\n\(request)")
        return parts.joined(separator: "\n\n")
    }

    /// Command line for one run; `resume` continues a session after a question.
    static func arguments(
        model: String, systemPrompt: String, mcpConfig: URL?, allowsTerminal: Bool, resume: String?
    ) -> [String] {
        var builtIn = ["WebSearch", "WebFetch"]
        if allowsTerminal { builtIn += ["Bash", "Read"] }
        var allowed = builtIn
        var arguments = [
            "-p", "--model", model, "--output-format", "json",
            "--append-system-prompt", systemPrompt,
            "--tools", builtIn.joined(separator: ","),
            "--setting-sources", "",
        ]
        if let mcpConfig {
            arguments += ["--mcp-config", mcpConfig.path, "--strict-mcp-config"]
            allowed.append("mcp__minutemind")
            arguments += ["--disallowedTools", blockedTools.joined(separator: ",")]
        } else {
            arguments.append("--strict-mcp-config")
        }
        arguments += ["--allowedTools", allowed.joined(separator: ",")]
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// The assistant's own folder: sessions are kept per folder, so resuming needs a fixed one.
    static var workingDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinuteMind/Assistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs one request (or the answer to a question, with `resume`) and returns what Claude
    /// wants done plus the session to resume.
    static func run(
        prompt: String, systemPrompt: String, model: String, mcpConfig: URL?, allowsTerminal: Bool,
        resume: String? = nil
    ) async throws -> (outcome: ClaudeAssistantOutcome, sessionID: String?) {
        guard let claude = ClaudeCodeService.locate() else { throw ClaudeCodeService.ServiceError.notInstalled }
        let reply = try await claude.runPrinted(
            arguments: arguments(model: model, systemPrompt: systemPrompt, mcpConfig: mcpConfig,
                                 allowsTerminal: allowsTerminal, resume: resume),
            prompt: prompt, workingDirectory: workingDirectory, timeout: 600)
        return (ClaudeAssistantOutcome.parse(reply.result), reply.sessionID)
    }
}
