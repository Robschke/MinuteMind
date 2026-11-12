// Purpose: MeetingMinutesService, the board status summary for the workboard (two or three
//          sentences from the project's task counts, overdue tasks and epics).
// Dependencies: Sources/App/Services/AIClient.swift
// Used by: Sources/App/Views/WorkboardView.swift (AI summary button)

import Foundation

struct MeetingMinutesService {
    /// Generate a brief board status summary from structured project data.
    func generateBoardSummary(prompt: String, ai: AIClient) async throws -> String {
        let systemPrompt = "You are a concise project status reporter. Respond in 2-3 sentences only."
        return try await ai.chat(system: systemPrompt, user: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
