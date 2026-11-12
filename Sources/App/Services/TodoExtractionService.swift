import Foundation

/// Service for extracting todos from meeting minutes with Claude (AIClient)
struct TodoExtractionService {
    
    // MARK: - Structured Output Models
    
    /// A single extracted todo item from the AI
    struct ExtractedTodo: Codable {
        let title: String
        let assignee: String?
        let dueDate: String?  // ISO8601 format or natural language
        let priority: String?  // "low", "medium", "high", "critical"
        let notes: String?
    }
    
    /// The structured response from the AI
    struct ExtractionResponse: Codable {
        let todos: [ExtractedTodo]
    }
    
    // MARK: - Errors
    
    enum ServiceError: Error, LocalizedError {
        case parsingFailed(String)
        case noMinutesContent
        
        var errorDescription: String? {
            switch self {
            case .parsingFailed(let detail): return "Failed to parse AI response: \(detail)"
            case .noMinutesContent: return "No meeting minutes content to analyze"
            }
        }
    }
    
    // MARK: - System Prompt

    private static func systemPrompt(today: String) -> String {
        """
        You are an expert at extracting action items and follow-ups from meeting minutes and returning ONLY items that are new compared to an existing todo list.

        TODAY'S DATE: \(today)

        INPUTS YOU WILL RECEIVE
        1) Meeting minutes (Markdown text)
        2) Existing todos list (JSON or text)

        TASK
        1. Scan the meeting minutes and extract every explicit or implied commitment:
        - action items, tasks, follow-ups, requests, assignments, "someone should...", "we need to...", "let’s..."
        2. Normalize each extracted item into a canonical form (same meaning → same todo).
        3. Compare against the existing todos list.
        4. Output ONLY the todos that are not already covered by an existing todo (including near-duplicates).

        DEDUPE / MATCHING RULES (IMPORTANT)
        Consider a todo a duplicate if any of the following are true:
        - Same goal/outcome even if wording differs.
        - Same task with a different level of detail (subtask vs parent task).
        - Same deliverable with different phrasing (e.g., "send deck" vs "share slides").
        - Same assignee + same intent + same timeframe.
        When in doubt, prefer marking as duplicate unless the new item adds a materially different deliverable, scope, or deadline.

        EXTRACTION RULES
        - Do NOT invent assignees. Use null if the assignee is not mentioned.
        - Capture one todo per distinct task. Avoid overly broad titles; keep them actionable.
        - If an action is contingent ("if X happens, do Y"), include it and note the condition in notes.
        - If multiple owners are mentioned, put the primary one in assignee and the rest in notes.

        PRIORITY RULES
        - "critical" / "blocker" / "must do today" → critical
        - "urgent" / "ASAP" / "as soon as possible" / "top priority" / "this week" → high
        - Explicitly low-priority items → low
        - Everything else, including items with no urgency mentioned → medium (this is the default)

        DUE DATE RULES
        - Absolute dates in the minutes → ISO 8601 (YYYY-MM-DD), e.g. "2026-03-25"
        - Relative terms → resolve against TODAY'S DATE above:
          "tomorrow" → today + 1 day
          "end of week" / "EOW" / "Friday" → nearest upcoming Friday
          "next week" → today + 7 days
          "next month" → today + 30 days
          "this sprint" → today + 14 days
          "ASAP" / "urgent" / "today" → TODAY'S DATE
        - No timing context at all → default to end of this week (nearest Friday)
        Always output an ISO 8601 date string (YYYY-MM-DD). Never output null for dueDate.

        FIELDS
        For each NEW todo, return:
        - title (required): short, action-oriented verb phrase.
        - assignee: string or null.
        - dueDate: ISO 8601 date string (YYYY-MM-DD). Always set — use end of this week (nearest Friday) if no context.
        - priority: one of "critical" | "high" | "medium" | "low". Always set — default to "medium".
        - notes: string or null (include context, dependencies, condition, source snippet if useful).

        OUTPUT FORMAT (STRICT)
        Return valid JSON only (no markdown, no commentary), exactly:
        {
        "todos": [
            {
            "title": "string",
            "assignee": "string or null",
            "dueDate": "YYYY-MM-DD",
            "priority": "low|medium|high|critical",
            "notes": "string or null"
            }
        ]
        }
        """
    }
    
    // MARK: - Extraction Method
    
    /// Extract todos from meeting minutes, excluding any that already exist
    @MainActor
    func extractTodos(
        minutesContent: String,
        existingTodos: [ProjectTask],
        ai: AIClient
    ) async throws -> [ExtractedTodo] {
        guard !minutesContent.isEmpty else {
            throw ServiceError.noMinutesContent
        }

        let todayString: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let prompt = Self.systemPrompt(today: todayString)

        // Build the user message with existing todos context
        let existingTodosList = existingTodos.map { "- \($0.title)" }.joined(separator: "\n")
        let userMessage = """
        ## EXISTING TODOS (do not include these again):
        \(existingTodosList.isEmpty ? "(No existing todos)" : existingTodosList)

        ## MEETING MINUTES TO ANALYZE:
        \(minutesContent)
        """

        let content = try await ai.chatJSON(system: prompt, user: userMessage)

        // Parse the JSON response
        guard let jsonData = content.data(using: .utf8) else {
            throw ServiceError.parsingFailed("Invalid UTF8 content")
        }
        
        do {
            let extraction = try JSONDecoder().decode(ExtractionResponse.self, from: jsonData)
            return extraction.todos
        } catch {
            throw ServiceError.parsingFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Conversion Helper
    
    /// Convert extracted todos to ProjectTask objects.
    /// Applies fallback defaults (medium priority, end of current week) for any fields the AI left nil.
    static func convertToTasks(
        _ extractedTodos: [ExtractedTodo],
        projectID: UUID?,
        sourceSessionID: UUID?
    ) -> [ProjectTask] {
        let defaultDueDate = endOfCurrentWeek
        return extractedTodos.map { extracted in
            ProjectTask(
                projectID: projectID,
                title: extracted.title,
                notes: extracted.notes ?? "",
                sourceSessionID: sourceSessionID,
                assignee: extracted.assignee,
                dueDate: parseDate(extracted.dueDate) ?? defaultDueDate,
                priority: parsePriority(extracted.priority) ?? .medium,
                needsReview: true
            )
        }
    }
    
    /// Parse a date string (ISO8601 or natural language) into a Date
    private static func parseDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString, !dateString.isEmpty else { return nil }
        
        // Try ISO8601 first
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withFullDate]
        if let date = isoFormatter.date(from: dateString) {
            return date
        }
        
        // Try common date formats
        let formatters: [DateFormatter] = [
            { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }(),
            { let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"; return f }(),
            { let f = DateFormatter(); f.dateStyle = .medium; return f }(),
        ]
        
        for formatter in formatters {
            if let date = formatter.date(from: dateString) {
                return date
            }
        }
        
        // Try relative dates
        let lowercased = dateString.lowercased()
        let calendar = Calendar.current
        let today = Date()
        
        if lowercased.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: today)
        } else if lowercased.contains("next week") {
            return calendar.date(byAdding: .weekOfYear, value: 1, to: today)
        } else if lowercased.contains("next month") {
            return calendar.date(byAdding: .month, value: 1, to: today)
        } else if lowercased.contains("friday") {
            return nextWeekday(.friday, from: today)
        } else if lowercased.contains("monday") {
            return nextWeekday(.monday, from: today)
        }
        
        return nil
    }
    
    private static func nextWeekday(_ weekday: Weekday, from date: Date) -> Date? {
        let calendar = Calendar.current
        var components = DateComponents()
        components.weekday = weekday.rawValue
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }
    
    private enum Weekday: Int {
        case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
    }

    /// Returns end-of-day Friday for the current week (or today if today is Friday).
    static var endOfCurrentWeek: Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let daysUntilFriday = (6 - weekday + 7) % 7
        let friday = cal.date(byAdding: .day, value: daysUntilFriday, to: today) ?? today
        return cal.date(bySettingHour: 16, minute: 0, second: 0, of: friday) ?? friday
    }

    /// Parse priority string into TaskPriority
    private static func parsePriority(_ priorityString: String?) -> TaskPriority? {
        guard let priority = priorityString?.lowercased() else { return nil }
        return TaskPriority(rawValue: priority)
    }
}
