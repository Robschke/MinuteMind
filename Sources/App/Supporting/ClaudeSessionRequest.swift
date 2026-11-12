// Purpose: ClaudeSessionRequest, what a workspace Claude session asks of the user (a permission,
//          a question with options, a plan, its finished answer, an error), read from its hook
//          payloads, and the keys that answer it in the session's terminal, so the desktop
//          companion's chat card can answer without opening the session.
// Dependencies: Foundation only (pure, unit tested in Tests/ClaudeSessionRequestTests.swift)
// Used by: Sources/App/Supporting/WorkspaceTerminalStore.swift (keeps the payloads, sends the
//          keys), Sources/App/Supporting/CompanionController.swift and
//          Sources/App/Supporting/MeetingPillController.swift (the chat card)
// Notes: Answers are keystrokes into Claude Code's own prompts, measured against Claude Code
//        2.1 in a pseudo terminal: Enter takes a permission prompt's first, highlighted choice
//        (Yes, once), Esc declines it; a question's option is its number key (it answers at
//        once, no Enter); a reply is pasted with bracketed paste (so line breaks stay in the
//        text instead of sending it) and sent with Enter. A different prompt layout in a
//        later Claude Code breaks these, which is why the card always offers Open as well.
//        - Only one question with single choice is answered from the card: several questions
//          or multiple choice need the session's own screen.
//        - A plan to approve is only shown: its choices differ in how much they allow.
//        - The hook file holds only the latest event, and a permission prompt's notification
//          (seconds later) overwrites the request, so the store keeps the last request apart.

import Foundation

enum ClaudeSessionRequest: Equatable {
    /// Wants to use a tool: "Bash", "git push origin main".
    case permission(tool: String, detail: String)
    /// AskUserQuestion; `options` empty when it cannot be answered from the card.
    case question(text: String, options: [String])
    case plan(String)
    /// The turn ended; Claude's last message.
    case finished(String)
    case failed(String?)
    /// Waiting, but the request is unknown (a notification's message, if any).
    case waiting(String?)

    /// Can be answered with a typed reply.
    var takesReply: Bool {
        switch self {
        case .permission, .finished, .failed: true
        case .question, .plan, .waiting: false
        }
    }

    // MARK: Reading

    /// The request from the session's last request payload (PermissionRequest, or PreToolUse of
    /// AskUserQuestion / ExitPlanMode) and its latest payload, given its current status.
    static func from(request: Data?, latest: Data?, status: TerminalSessionStatus) -> ClaudeSessionRequest? {
        let latestObject = latest.flatMap(object)
        switch status {
        case .done:
            let message = (latestObject?["last_assistant_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .finished(message ?? "")
        case .error:
            let message = latestObject?["error"] as? String ?? latestObject?["message"] as? String
            return .failed(message)
        case .waiting:
            if let request = request.flatMap(object), let parsed = fromToolRequest(request) { return parsed }
            return .waiting(latestObject?["message"] as? String)
        case .idle, .working:
            return nil
        }
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func fromToolRequest(_ object: [String: Any]) -> ClaudeSessionRequest? {
        guard let tool = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        switch tool {
        case "AskUserQuestion":
            let questions = input["questions"] as? [[String: Any]] ?? []
            guard let first = questions.first else { return .waiting(nil) }
            let text = first["question"] as? String ?? ""
            let multi = first["multiSelect"] as? Bool ?? false
            let labels = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            // Number keys reach 1 to 9; more questions or several choices need the session.
            let answerable = questions.count == 1 && !multi && labels.count <= 9
            return .question(text: questions.count > 1 ? "\(text) (+\(questions.count - 1) more)" : text,
                             options: answerable ? labels : [])
        case "ExitPlanMode":
            return .plan(input["plan"] as? String ?? "")
        default:
            return .permission(tool: tool, detail: detail(tool: tool, input: input))
        }
    }

    /// The one line that says what the tool would do.
    private static func detail(tool: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "url", "pattern", "query", "description"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    /// Whether a payload starts or replaces the remembered request.
    static func isRequestPayload(_ data: Data) -> Bool {
        guard let object = object(data), let event = object["hook_event_name"] as? String else { return false }
        if event == "PermissionRequest" { return true }
        let tool = object["tool_name"] as? String ?? ""
        return event == "PreToolUse" && ["AskUserQuestion", "ExitPlanMode"].contains(tool)
    }

    /// Whether a payload means the remembered request was answered (a new prompt, a tool ran).
    static func endsRequest(_ data: Data) -> Bool {
        guard let event = object(data)?["hook_event_name"] as? String else { return false }
        return ["UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "Stop", "SessionStart"].contains(event)
    }

    // MARK: Answering

    enum Answer: Equatable {
        case allow
        case deny
        /// Declines and tells Claude what to do instead.
        case denyWith(String)
        case option(Int)
        case reply(String)
    }

    /// The keystrokes for an answer, in order; a pause belongs between two entries (the prompt
    /// has to close before the next input arrives).
    static func keys(for answer: Answer) -> [String] {
        switch answer {
        case .allow: return ["\r"]
        case .deny: return ["\u{1b}"]
        case .denyWith(let text): return ["\u{1b}"] + pasted(text)
        case .option(let index): return index >= 0 && index < 9 ? ["\(index + 1)"] : []
        case .reply(let text): return pasted(text)
        }
    }

    private static func pasted(_ text: String) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{1b}", with: "")
        guard !clean.isEmpty else { return [] }
        return ["\u{1b}[200~\(clean)\u{1b}[201~", "\r"]
    }
}
