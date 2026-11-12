import Foundation

/// Service for AI-powered calendar time block suggestions
struct CalendarBlockerService {
    
    // MARK: - Structured Output Models
    
    /// A suggested time block from the AI
    struct SuggestedBlock: Codable {
        let startTime: String  // ISO8601 format
        let endTime: String    // ISO8601 format
        let reasoning: String  // Why this slot was chosen
    }
    
    /// The structured response from the AI
    struct BlockerResponse: Codable {
        let suggestions: [SuggestedBlock]
        let explanation: String  // Overall explanation of the scheduling strategy
    }
    
    // MARK: - Errors
    
    enum ServiceError: Error, LocalizedError {
        case parsingFailed(String)
        case noDueDate
        case noDuration
        case noSuggestionsGenerated(rawResponse: String)
        
        var errorDescription: String? {
            switch self {
            case .parsingFailed(let detail): return "Failed to parse AI response: \(detail)"
            case .noDueDate: return "Task must have a due date to schedule blockers"
            case .noDuration: return "Task must have an estimated duration to schedule blockers"
            case .noSuggestionsGenerated(let raw): return "AI returned no valid time blocks. Raw: \(raw.prefix(200))"
            }
        }
    }
    
    // MARK: - System Prompt
    
    private static func systemPrompt(taskDuration: Int, timingPreferences: String?) -> String {
        var prompt = """
        You are an expert calendar scheduling assistant. Your job is to find optimal time slots to work on a task.
        
        You will be given:
        1. A task description and notes
        2. The estimated duration needed: \(taskDuration) minutes
        3. The deadline (due date)
        4. Current calendar events until the deadline
        5. Optional timing preferences from the user
        
        Your task is to suggest time blocks for working on this task. Consider:
        - Avoid conflicts with existing calendar events
        - Prefer working hours (9 AM - 6 PM) but adapt to the user's existing schedule patterns
        - If the task is long, split it into multiple focused sessions (60-120 min each is ideal)
        - Leave buffer time between meetings (at least 15 min after other events)
        - Schedule sooner rather than later to avoid last-minute rushing
        - Consider energy levels: complex tasks earlier in the day, routine tasks later
        
        Rules:
        - Total suggested time must equal or slightly exceed the estimated duration
        - Never overlap with existing events
        - Each block should be at least 30 minutes
        - Maximum 4 blocks per day to avoid fragmentation
        - Don't schedule outside 7 AM - 10 PM unless the user has events at odd hours
        - ALWAYS suggest at least one time block unless absolutely impossible
        
        CRITICAL: Use ISO8601 format for dates with timezone, like: "2025-12-19T09:00:00Z" or "2025-12-19T09:00:00+01:00"
        
        """
        
        if let prefs = timingPreferences, !prefs.isEmpty {
            prompt += """
            
            USER'S TIMING PREFERENCES (prioritize these):
            \(prefs)
            
            """
        }
        
        prompt += """
        
        Respond with valid JSON only, using this exact structure:
        {
          "suggestions": [
            {
              "startTime": "2025-12-19T09:00:00Z",
              "endTime": "2025-12-19T10:30:00Z",
              "reasoning": "Why this time slot is good"
            }
          ],
          "explanation": "Overall scheduling strategy explanation"
        }
        """
        
        return prompt
    }
    
    // MARK: - Date Parsing
    
    /// Parse various ISO8601 date formats that AI might return
    private static func parseDate(_ string: String) -> Date? {
        // Try standard ISO8601 with timezone
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: string) {
            return date
        }
        
        // Try with fractional seconds
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: string) {
            return date
        }
        
        // Try local time format (no timezone)
        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        localFormatter.timeZone = TimeZone.current
        if let date = localFormatter.date(from: string) {
            return date
        }
        
        // Try with just date and time, no T separator
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = localFormatter.date(from: string) {
            return date
        }
        
        return nil
    }
    
    // MARK: - Suggestion Method
    
    /// Get AI-powered time block suggestions for a task
    func suggestTimeBlocks(
        taskTitle: String,
        taskNotes: String,
        estimatedDurationMinutes: Int,
        dueDate: Date,
        existingEvents: [CalendarEvent],
        timingPreferences: String?,
        ai: AIClient
    ) async throws -> (blocks: [ProposedTimeBlock], explanation: String) {
        guard estimatedDurationMinutes > 0 else {
            throw ServiceError.noDuration
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        
        // Format existing events for the prompt
        let eventsDescription = existingEvents.isEmpty ? "No existing events" : existingEvents.map { event in
            let start = dateFormatter.string(from: event.startDate)
            let end = dateFormatter.string(from: event.endDate)
            return "- \(event.title): \(start) to \(end)"
        }.joined(separator: "\n")
        
        let userMessage = """
        ## TASK TO SCHEDULE
        Title: \(taskTitle)
        Notes: \(taskNotes.isEmpty ? "(No additional notes)" : taskNotes)
        Estimated Duration: \(estimatedDurationMinutes) minutes
        Due Date: \(dateFormatter.string(from: dueDate))
        Current Time: \(dateFormatter.string(from: Date()))
        
        ## EXISTING CALENDAR EVENTS (until due date)
        \(eventsDescription)
        
        Please suggest optimal time blocks to work on this task.
        """
        
        let content = try await ai.chatJSON(
            system: Self.systemPrompt(taskDuration: estimatedDurationMinutes, timingPreferences: timingPreferences),
            user: userMessage)

        // Parse the JSON response
        guard let jsonData = content.data(using: .utf8) else {
            throw ServiceError.parsingFailed("Invalid UTF8 content")
        }
        
        do {
            let blockerResponse = try JSONDecoder().decode(BlockerResponse.self, from: jsonData)
            
            // Convert to ProposedTimeBlock with robust date parsing
            var blocks: [ProposedTimeBlock] = []
            var failedParsing: [(start: String, end: String)] = []
            
            for suggestion in blockerResponse.suggestions {
                if let startDate = Self.parseDate(suggestion.startTime),
                   let endDate = Self.parseDate(suggestion.endTime) {
                    blocks.append(ProposedTimeBlock(
                        startDate: startDate,
                        endDate: endDate,
                        title: "📋 \(taskTitle)"
                    ))
                } else {
                    failedParsing.append((suggestion.startTime, suggestion.endTime))
                }
            }
            
            // If we got suggestions but couldn't parse any dates, throw with details
            if blocks.isEmpty && !blockerResponse.suggestions.isEmpty {
                let failedDetails = failedParsing.map { "start: \($0.start), end: \($0.end)" }.joined(separator: "; ")
                throw ServiceError.noSuggestionsGenerated(rawResponse: "Date parsing failed for: \(failedDetails)")
            }
            
            return (blocks, blockerResponse.explanation)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.parsingFailed("\(error.localizedDescription). Raw response: \(content.prefix(300))")
        }
    }
}
