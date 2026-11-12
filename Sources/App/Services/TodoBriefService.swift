// Purpose: Generates an AI-powered daily task brief — ranks upcoming tasks by urgency, accounts for
//          calendar context, and suggests 2–3 concrete time slot options per task.
// Dependencies: Foundation, Project.swift (ProjectTask, TaskPriority), CalendarService.swift (CalendarEvent, ProposedTimeBlock)
// Used by: Sources/App/ViewModels/AppViewModel.swift (runTodoBrief)
// Notes: Returns multiple slot options per task so the user can pick in TodoBriefSheetView.
//        Stateless — throttling is handled by AutomationCoordinator.

import Foundation

// MARK: - Output types

/// One task selected by the AI for the daily brief, with 2–3 slot options.
struct BriefItem {
    let task: ProjectTask
    let reason: String
    /// 2–3 calendar slot options for this task; empty if no free time found.
    let suggestedSlots: [ProposedTimeBlock]
}

/// The full result of a daily brief generation.
struct TodoBrief {
    /// 1–3 sentence summary suitable for a notification body.
    let summary: String
    /// Ranked list of tasks the user should focus on.
    let items: [BriefItem]
}

// MARK: - Service

struct TodoBriefService {

    // MARK: - AI response models (private)

    private struct SlotDTO: Codable {
        let startTime: String
        let endTime: String
        let label: String       // short human label, e.g. "Morning focus block"
    }

    private struct TaskDTO: Codable {
        let taskId: String
        let reason: String
        let suggestedSlots: [SlotDTO]
    }

    private struct BriefResponseDTO: Codable {
        let summary: String
        let prioritizedTasks: [TaskDTO]
    }

    // MARK: - Errors

    enum BriefError: Error, LocalizedError {
        case emptyResponse
        case parsingFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "AI returned an empty brief response"
            case .parsingFailed(let d): return "Failed to parse brief response: \(d)"
            }
        }
    }

    // MARK: - Main entry point

    /// Sends the top tasks + calendar context to the AI and returns a `TodoBrief`
    /// with 2–3 slot options per task.
    ///
    /// - Parameters:
    ///   - tasks: Up to 10 candidate tasks (pre-filtered and sorted by the caller).
    ///   - calendarEvents: Events in the next 7 days used for free-slot analysis.
    func generateBrief(
        tasks: [ProjectTask],
        calendarEvents: [CalendarEvent],
        ai: AIClient
    ) async throws -> TodoBrief {

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        // -- Build task list for the prompt --
        let taskLines = tasks.enumerated().map { idx, task in
            var line = "\(idx + 1). ID:\(task.id.uuidString) | \"\(task.title)\""
            if let due = task.dueDate {
                line += " | Due: \(dateFormatter.string(from: due))"
            }
            if let priority = task.priority {
                line += " | Priority: \(priority.displayName)"
            }
            if let mins = task.estimatedDurationMinutes, mins > 0 {
                line += " | Estimated: \(mins) min"
            }
            if !task.notes.isEmpty {
                line += " | Notes: \(task.notes.prefix(120))"
            }
            return line
        }.joined(separator: "\n")

        // -- Build calendar summary for the prompt --
        let calendarLines: String
        if calendarEvents.isEmpty {
            calendarLines = "No existing calendar events in the next 7 days."
        } else {
            calendarLines = calendarEvents.map { event in
                "- \(dateFormatter.string(from: event.startDate)) → \(dateFormatter.string(from: event.endDate)): \(event.title)"
            }.joined(separator: "\n")
        }

        let systemPrompt = """
        You are a personal productivity assistant that helps users plan their week.

        You receive a list of upcoming tasks (due within 7 days) with priorities and due dates, \
        and the user's calendar for the same period.

        Your job:
        1. Pick the 3 most important tasks (consider priority level AND proximity of due date).
        2. For each chosen task suggest 2–3 DISTINCT calendar slot options spread across different \
           days and times of day (morning / afternoon / next day). Each slot duration should match \
           the task's estimated duration (default 60 min if unknown). Leave ≥15 min before/after \
           existing events. Never overlap with existing calendar events.
        3. Write a concise 2–3 sentence summary for a push notification.

        Slot labelling: give each slot a short human-friendly label like "Tue morning", \
        "Wed afternoon", "Thu after lunch", etc.

        Rules:
        - Only suggest slots within the next 7 days and within 8 AM–8 PM.
        - Use ISO 8601 with the user's local timezone offset for ALL times, e.g. \
          "2026-03-18T09:00:00+01:00". NEVER use Z/UTC.
        - Respond with valid JSON only — no markdown fences, no extra text.

        JSON schema:
        {
          "summary": "<2–3 sentence notification text>",
          "prioritizedTasks": [
            {
              "taskId": "<UUID string>",
              "reason": "<why this task is urgent>",
              "suggestedSlots": [
                { "startTime": "<ISO8601>", "endTime": "<ISO8601>", "label": "<short label>" },
                { "startTime": "<ISO8601>", "endTime": "<ISO8601>", "label": "<short label>" }
              ]
            }
          ]
        }
        """

        let now = dateFormatter.string(from: Date())
        let userMessage = """
        Current time: \(now)

        ## TASKS DUE WITHIN 7 DAYS (top \(tasks.count) by priority)
        \(taskLines)

        ## CALENDAR (next 7 days)
        \(calendarLines)

        Please generate the daily task brief.
        """

        let content = try await ai.chatJSON(system: systemPrompt, user: userMessage)
        guard let jsonData = content.data(using: .utf8) else {
            throw BriefError.parsingFailed("Non-UTF8 content")
        }

        let dto: BriefResponseDTO
        do {
            dto = try JSONDecoder().decode(BriefResponseDTO.self, from: jsonData)
        } catch {
            throw BriefError.parsingFailed("\(error.localizedDescription). Raw: \(content.prefix(400))")
        }

        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id.uuidString, $0) })

        let items: [BriefItem] = dto.prioritizedTasks.compactMap { taskDTO in
            guard let task = tasksByID[taskDTO.taskId] else {
                NSLog("TodoBriefService: AI returned unknown taskId %@", taskDTO.taskId)
                return nil
            }
            let slots: [ProposedTimeBlock] = taskDTO.suggestedSlots.compactMap { slotDTO in
                guard let start = Self.parseDate(slotDTO.startTime),
                      let end   = Self.parseDate(slotDTO.endTime) else { return nil }
                return ProposedTimeBlock(
                    startDate: start,
                    endDate: end,
                    title: "📋 \(task.title) (\(slotDTO.label))"
                )
            }
            return BriefItem(task: task, reason: taskDTO.reason, suggestedSlots: slots)
        }

        return TodoBrief(summary: dto.summary, items: items)
    }

    // MARK: - Date parsing

    private static func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        local.timeZone = .current
        return local.date(from: string)
    }
}
