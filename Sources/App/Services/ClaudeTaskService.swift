// Purpose: ClaudeTaskService, the "Claude mini task" behind a triple tap of the dictation key: the
//          spoken request goes to Claude once, and the finished result comes back as plain text
//          to paste. Also builds the link that opens the request as a real Claude chat.
// Dependencies: Sources/App/Services/ClaudeCodeService.swift (headless `claude -p`, user's
//               subscription), AppKit (NSWorkspace, to find the Claude app)
// RBAC: None.
// Dependents: Sources/App/Supporting/QuickDictationController.swift (runs tasks, opens chats),
//             Sources/App/Views/ClaudeTaskSettingsView.swift (model choices)
// Notes: User decisions (2026-10-04): the answer is pasted at the cursor like a dictation and
//        left on the clipboard (first it was clipboard only, changed the same day); the model is
//        chosen in Settings (Sonnet by default); the user can store standing instructions that are
//        added to every task; "Open Chat" opens the Claude app (claude.ai as fallback) with the
//        request already in the message box.
//        The base prompt makes clear this is a single task and not a chat: no follow-up questions,
//        no preamble, only the result, ready to paste. Plain text, because results are pasted into
//        mail and chat fields that would show Markdown asterisks literally.

import AppKit
import Foundation

enum ClaudeTaskService {
    /// Claude Code model aliases offered in Settings, with their display names.
    static let models: [(alias: String, name: String)] = [
        ("sonnet", "Sonnet (recommended)"),
        ("haiku", "Haiku (fastest)"),
        ("opus", "Opus (best, slowest)"),
    ]

    static let claudeAppBundleID = "com.anthropic.claudefordesktop"

    static let basePrompt = """
        You are a one-shot assistant the user calls by voice from anywhere on their Mac. They \
        dictated a single small task, for example drafting an email, rephrasing or translating a \
        text, or writing a short message. This is not a conversation: there is no follow-up, so \
        never ask questions; make sensible assumptions instead.

        Reply with only the finished result, ready to paste where the user needs it. No \
        preamble, no explanation, no closing remarks, no quotation marks around the result. Use \
        plain text without Markdown formatting.

        The request comes from speech recognition and may contain misheard words; infer what was \
        meant. Write the result in the language of the request unless the task asks for another.
        """

    /// The system prompt for one task: the base rules plus the user's standing instructions.
    static func systemPrompt(userInstructions: String) -> String {
        let extra = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.isEmpty else { return basePrompt }
        return basePrompt + "\n\nThe user's standing instructions for every task:\n" + extra
    }

    /// Runs one task through Claude Code and returns the result, trimmed.
    static func run(task: String, userInstructions: String, model: String) async throws -> String {
        guard let claude = ClaudeCodeService.locate() else { throw ClaudeCodeService.ServiceError.notInstalled }
        let result = try await claude.complete(
            prompt: task,
            systemPrompt: systemPrompt(userInstructions: userInstructions),
            model: model,
            timeout: 120)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A new Claude chat with `text` in the message box: the Claude app when installed,
    /// claude.ai in the browser otherwise.
    static func chatURL(for text: String, claudeAppInstalled: Bool) -> URL? {
        var components = URLComponents()
        if claudeAppInstalled {
            components.scheme = "claude"
            components.host = "claude.ai"
        } else {
            components.scheme = "https"
            components.host = "claude.ai"
        }
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }

    @MainActor
    static var isClaudeAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeAppBundleID) != nil
    }
}
