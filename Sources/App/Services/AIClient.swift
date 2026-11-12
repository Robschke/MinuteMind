// Purpose: AIClient, the one way the app's background jobs (summary, titles, todos, task brief,
//          time blocks, board summary) ask an AI for text: the installed Claude Code CLI with the
//          model chosen in Settings, AI.
// Dependencies: Sources/App/Services/ClaudeCodeService.swift (chat, chatJSON, locate)
// Used by: Sources/App/ViewModels/AppViewModel.swift (aiClient), Sources/App/Services/TodoExtractionService.swift,
//          Sources/App/Services/CalendarBlockerService.swift, Sources/App/Services/TodoBriefService.swift,
//          Sources/App/Services/MeetingMinutesService.swift (board summary)
// Notes: Services take an AIClient instead of credentials, so the engine behind it can change
//        in one place. There is no HTTP provider and no API key: without Claude Code installed,
//        `isAvailable` is false and the AI features stay off.

import Foundation

struct AIClient: Sendable {
    /// Claude Code model alias ("sonnet", "opus", "haiku").
    let model: String

    /// Model aliases offered in Settings, fastest to most thorough.
    static let models = ["haiku", "sonnet", "opus"]

    /// True when the AI engine is installed.
    static var isAvailable: Bool { ClaudeCodeService.locate() != nil }

    /// One system + user exchange; returns the reply text.
    func chat(system: String, user: String, timeout: TimeInterval = 300) async throws -> String {
        try await ClaudeCodeService.chat(system: system, user: user, model: model, timeout: timeout)
    }

    /// Like `chat`, for callers that parse a JSON object. Returns just the object.
    func chatJSON(system: String, user: String) async throws -> String {
        try await ClaudeCodeService.chatJSON(system: system, user: user, model: model)
    }
}
