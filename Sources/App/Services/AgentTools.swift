import Foundation

/// Represents an agent tool that can be called by the AI assistant
struct AgentTool {
    let definition: [String: Any]  // OpenAI function calling JSON schema
    let execute: (String) async throws -> String  // Execution handler taking JSON arguments
}

/// Registry for all available agent tools
@MainActor
class AgentToolRegistry {
    static let shared = AgentToolRegistry()
    
    private var tools: [String: AgentTool] = [:]
    
    private init() {
        registerDefaultTools()
    }
    
    func register(_ name: String, tool: AgentTool) {
        tools[name] = tool
    }
    
    func getTool(_ name: String) -> AgentTool? {
        return tools[name]
    }
    
    func allDefinitions() -> [[String: Any]] {
        return tools.values.map { $0.definition }
    }
    
    private func registerDefaultTools() {
        // Calendar tools
        register("list_calendar_events", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "list_calendar_events",
                    "description": "List all calendar events within a specific date range. Use this to see what events are scheduled, check for conflicts when creating new events/tasks, or find time blocks. When creating tasks with due dates, consider checking the calendar around that date to identify potential scheduling conflicts or related meetings.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "start_date": [
                                "type": "string",
                                "description": "Start date in ISO8601 format with local timezone offset — NEVER Z/UTC (e.g., '2026-01-06T00:00:00+01:00'). Required."
                            ],
                            "end_date": [
                                "type": "string",
                                "description": "End date in ISO8601 format with local timezone offset — NEVER Z/UTC (e.g., '2026-01-07T23:59:59+01:00'). Required."
                            ]
                        ],
                        "required": ["start_date", "end_date"]
                    ]
                ]
            ],
            execute: { _ in "" }  // Placeholder, will be set by ToolExecutor
        ))
        
        register("search_calendar_events", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "search_calendar_events",
                    "description": "Get calendar events within a time range for flexible searching and filtering. Returns ALL events in the range so you can filter/match them based on user's criteria (title keywords, attendees, etc.). Use this when user asks vague queries like 'meetings with John', 'events about the project', 'my morning meetings', etc. After getting results, present matching events and offer to take actions (delete, reschedule, add reminders). This is your multi-step tool: retrieve first, then analyze and suggest.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "start_date": [
                                "type": "string",
                                "description": "Start date in ISO8601 format with local timezone offset — NEVER Z/UTC (e.g., '2026-01-06T00:00:00+01:00'). Default to today if not specified."
                            ],
                            "end_date": [
                                "type": "string",
                                "description": "End date in ISO8601 format with local timezone offset — NEVER Z/UTC (e.g., '2026-01-13T23:59:59+01:00'). Default to 7 days from start if not specified."
                            ],
                            "days_ahead": [
                                "type": "integer",
                                "description": "Alternative to end_date: get events for next N days from start_date (or today). Useful for 'next week', 'next 2 weeks', etc."
                            ]
                        ],
                        "required": []
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        register("create_calendar_event", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "create_calendar_event",
                    "description": "Create a new calendar event or time blocker. Before creating, consider checking for conflicts using list_calendar_events. After creating, proactively ask if user wants: 1) a reminder for this event, 2) related tasks created, or 3) preparatory time blocked before the event. For work/focus blocks, suggest creating them as calendar events to protect the time.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "title": [
                                "type": "string",
                                "description": "Event title/name. Required."
                            ],
                            "start_date": [
                                "type": "string",
                                "description": "Start date and time in ISO8601 format with local timezone offset — NEVER Z/UTC (e.g., '2026-01-06T14:00:00+01:00'). Required."
                            ],
                            "end_date": [
                                "type": "string",
                                "description": "End date and time in ISO8601 format with local timezone offset — NEVER Z/UTC (e.g., '2026-01-06T15:00:00+01:00'). Required."
                            ],
                            "location": [
                                "type": "string",
                                "description": "Optional: Event location or address"
                            ],
                            "notes": [
                                "type": "string",
                                "description": "Optional: Additional notes or description for the event"
                            ],
                            "url": [
                                "type": "string",
                                "description": "Optional: URL related to the event (e.g., Zoom link, website)"
                            ],
                            "is_all_day": [
                                "type": "boolean",
                                "description": "Optional: Whether this is an all-day event (default: false)"
                            ],
                            "alert_minutes_before": [
                                "type": "integer",
                                "description": "Optional: Alert notification N minutes before event (e.g., 15, 30, 60)"
                            ]
                        ],
                        "required": ["title", "start_date", "end_date"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        register("delete_calendar_event", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "delete_calendar_event",
                    "description": "Delete a calendar event by its ID. MULTI-STEP WORKFLOW: First use search_calendar_events to find and present matching events to user, confirm which one(s) to delete, then delete them. When deleting meetings, check if there are related tasks (search by similar title/keywords) and offer to update or delete those too. When deleting time blockers, check if the associated task should be updated (remove due date, change status, etc.).",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "event_id": [
                                "type": "string",
                                "description": "The unique identifier of the calendar event to delete. Required."
                            ]
                        ],
                        "required": ["event_id"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        // Task tools
        register("list_projects", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "list_projects",
                    "description": "List all available projects in the system. ALWAYS use this first if user mentions tasks but doesn't specify a project. After showing projects, help user select the relevant one. When creating tasks, if user hasn't chosen a project, list projects and ask which one. This prevents errors and improves user experience.",
                    "parameters": [
                        "type": "object",
                        "properties": [:],
                        "required": []
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        register("list_project_tasks", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "list_project_tasks",
                    "description": "List all tasks in a specific project. After showing tasks, be proactive: identify tasks with approaching due dates and suggest calendar blockers or reminders, spot high-priority tasks without due dates and offer to schedule them, notice tasks missing descriptions and offer to add details. When showing tasks with due dates, consider checking calendar events around those dates to warn about conflicts. Use list_projects first if project_id is unknown.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "project_id": [
                                "type": "string",
                                "description": "Optional: UUID of the project to list tasks from. Required when not in a project context. Use list_projects to discover available projects."
                            ],
                            "include_completed": [
                                "type": "boolean",
                                "description": "Optional: Include completed tasks in results (default: false - only open tasks)"
                            ]
                        ],
                        "required": []
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        register("create_project_task", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "create_project_task",
                    "description": "Create a new task in a specific project. WORKFLOW: If project_id is unknown, use list_projects first. After creating task, be helpful and offer complementary actions: 1) If task has due date, suggest creating calendar time blocker to work on it, 2) Suggest creating a reminder for the due date/deadline, 3) For high-priority tasks, offer to schedule dedicated time on calendar. This makes you a proactive assistant, not just a task creator.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "project_id": [
                                "type": "string",
                                "description": "Optional: UUID of the project to create the task in. Required when not in a project context."
                            ],
                            "title": [
                                "type": "string",
                                "description": "Task title/name. Required."
                            ],
                            "description": [
                                "type": "string",
                                "description": "Optional: Detailed description of the task"
                            ],
                            "priority": [
                                "type": "string",
                                "enum": ["low", "medium", "high", "critical"],
                                "description": "Optional: Task priority level (default: medium)"
                            ],
                            "due_date": [
                                "type": "string",
                                "description": "Optional: Due date in ISO8601 format with local timezone offset — NEVER Z/UTC (e.g., '2026-01-10T17:00:00+01:00')"
                            ],
                            "status": [
                                "type": "string",
                                "enum": ["backlog", "todo", "inProgress", "review", "done"],
                                "description": "Optional: Board column status (default: todo). Use 'done' to mark complete."
                            ],
                            "epic_id": [
                                "type": "string",
                                "description": "Optional: UUID of an epic to assign this task to. Use list_project_epics to find epic IDs."
                            ]
                        ],
                        "required": ["title"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))

        register("update_project_task", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "update_project_task",
                    "description": "Update an existing task in a project. When updating, be intelligent: 1) If marking complete (is_completed=true), check calendar for related time blockers and offer to delete them, 2) If changing due date, search calendar around new date for conflicts and offer to move/create time blocker, 3) If increasing priority, suggest adding calendar blocker or reminder, 4) If removing due date, offer to delete related calendar events/reminders. Think holistically about the user's system.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "project_id": [
                                "type": "string",
                                "description": "Optional: UUID of the project containing the task. Required when not in a project context."
                            ],
                            "task_id": [
                                "type": "string",
                                "description": "UUID of the task to update. Required."
                            ],
                            "title": [
                                "type": "string",
                                "description": "Optional: New task title"
                            ],
                            "description": [
                                "type": "string",
                                "description": "Optional: New task description/notes"
                            ],
                            "priority": [
                                "type": "string",
                                "enum": ["low", "medium", "high", "critical"],
                                "description": "Optional: New priority level"
                            ],
                            "due_date": [
                                "type": "string",
                                "description": "Optional: New due date in ISO8601 format with local timezone offset — NEVER Z/UTC (e.g., '2026-01-10T17:00:00+01:00'). Pass empty string to remove due date."
                            ],
                            "is_completed": [
                                "type": "boolean",
                                "description": "Optional: Mark task as completed (true) or incomplete (false)"
                            ],
                            "assignee": [
                                "type": "string",
                                "description": "Optional: Assign task to someone. Pass empty string to remove assignee."
                            ],
                            "status": [
                                "type": "string",
                                "enum": ["backlog", "todo", "inProgress", "review", "done"],
                                "description": "Optional: Move task to a board column. 'done' also marks it complete."
                            ],
                            "epic_id": [
                                "type": "string",
                                "description": "Optional: UUID of an epic to assign. Pass empty string to unassign."
                            ]
                        ],
                        "required": ["task_id"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))

        // Epic and board tools
        register("list_project_epics", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "list_project_epics",
                    "description": "List all epics in a project. Epics group related tasks into larger initiatives on the workboard.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "project_id": [
                                "type": "string",
                                "description": "Optional: UUID of the project. Uses current project context if omitted."
                            ]
                        ],
                        "required": []
                    ]
                ]
            ],
            execute: { _ in "" }
        ))

        register("create_project_epic", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "create_project_epic",
                    "description": "Create a new epic in a project to group related tasks.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "project_id": [
                                "type": "string",
                                "description": "Optional: UUID of the project. Uses current project context if omitted."
                            ],
                            "title": [
                                "type": "string",
                                "description": "Epic title. Required."
                            ],
                            "summary": [
                                "type": "string",
                                "description": "Optional: One-line description of the epic."
                            ],
                            "color_hex": [
                                "type": "string",
                                "description": "Optional: Hex color code (e.g., '#007AFF'). Random default if omitted."
                            ]
                        ],
                        "required": ["title"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))

        register("get_board_summary", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "get_board_summary",
                    "description": "Get a summary of the project workboard — task counts per status column, epic progress, and overdue items.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "project_id": [
                                "type": "string",
                                "description": "Optional: UUID of the project. Uses current project context if omitted."
                            ]
                        ],
                        "required": []
                    ]
                ]
            ],
            execute: { _ in "" }
        ))

        // Web search tools
        register("web_search", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "web_search",
                    "description": "Search the web for current information, research topics, or find resources. Returns ranked results with titles, URLs, and short snippets. Use this when: 1) User asks about current events/news not in knowledge base, 2) Need to research technical topics or find documentation, 3) Finding external resources/articles, 4) Fact-checking or getting latest information. WORKFLOW: After getting search results, present them to user with brief summaries. If user wants details from a specific result, use fetch_webpage to get full content. Consider saving valuable information to knowledge base for future reference.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": "Search query. Be specific and use relevant keywords. Examples: 'SwiftUI async await best practices', 'EventKit macOS API documentation', 'project management techniques 2026'"
                            ],
                            "result_count": [
                                "type": "integer",
                                "description": "Optional: Number of results to return (1-10, default: 5). Use fewer (2-3) for focused queries, more (8-10) for exploratory research."
                            ]
                        ],
                        "required": ["query"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        register("fetch_webpage", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "fetch_webpage",
                    "description": "Fetch and extract the main text content from a specific webpage URL. Use this after web_search to read detailed content from a result the user is interested in. Returns cleaned text without HTML, ads, or navigation. Best for: documentation pages, articles, blog posts, technical guides. WORKFLOW: After fetching, summarize key points relevant to user's question. Offer to: 1) Extract specific information they need, 2) Save important content to knowledge base with proper category, 3) Create tasks based on action items found in the content.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "url": [
                                "type": "string",
                                "description": "Full URL of the webpage to fetch (must start with http:// or https://). Example: 'https://developer.apple.com/documentation/eventkit'"
                            ],
                            "max_length": [
                                "type": "integer",
                                "description": "Optional: Maximum content length in characters (default: 8000, max: 20000). Use lower values (2000-4000) for summaries, higher (10000-20000) for detailed extraction."
                            ]
                        ],
                        "required": ["url"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        register("delete_project_task", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "delete_project_task",
                    "description": "Delete a task from a project permanently. CRITICAL WORKFLOW: Before deleting, search the user's calendar (search_calendar_events) for time blockers or events related to this task (match by title keywords, due date range). If found, inform user and offer to delete those calendar items too, or ask if they should be kept. This prevents orphaned calendar entries and shows you're thinking ahead. Then delete the task.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "project_id": [
                                "type": "string",
                                "description": "Optional: UUID of the project containing the task. Required when not in a project context."
                            ],
                            "task_id": [
                                "type": "string",
                                "description": "UUID of the task to delete. Required."
                            ]
                        ],
                        "required": ["task_id"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        // Reminder tools
        register("list_reminders", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "list_reminders",
                    "description": "List all reminders from Apple Reminders app. After listing, be proactive: spot overdue reminders and offer to reschedule or mark complete, identify reminders without due dates that should have them, suggest converting high-priority reminders into calendar events for better time management, notice patterns (e.g., many reminders about same project) and offer to create a consolidated task. Help user maintain a clean reminder system.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "include_completed": [
                                "type": "boolean",
                                "description": "Optional: Include completed reminders in results (default: false - only open reminders)"
                            ],
                            "list_name": [
                                "type": "string",
                                "description": "Optional: Filter to specific reminder list by name"
                            ],
                            "days_ahead": [
                                "type": "integer",
                                "description": "Optional: Only show reminders due within the next N days"
                            ]
                        ],
                        "required": []
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        register("create_reminder", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "create_reminder",
                    "description": "Create a reminder in Apple Reminders app. After creating, be smart: 1) If reminder is task-like (has deadline, requires work time), suggest also creating a project task or calendar time blocker, 2) For meeting-related reminders, check if meeting exists in calendar, 3) For recurring reminders (weekly report, etc.), mention that and ask if user wants calendar recurring events instead. Help user choose the right tool for the job - reminders for quick alerts, tasks for tracked work, calendar for time blocking.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "title": [
                                "type": "string",
                                "description": "Reminder title/name. Required."
                            ],
                            "notes": [
                                "type": "string",
                                "description": "Optional: Additional notes or details"
                            ],
                            "due_date": [
                                "type": "string",
                                "description": "Optional: Due date and time in ISO8601 format with local timezone offset — NEVER Z/UTC (e.g., '2026-01-10T09:00:00+01:00')"
                            ],
                            "priority": [
                                "type": "integer",
                                "description": "Optional: Priority level - 0 (none), 1 (low), 5 (medium), 9 (high)"
                            ],
                            "list_name": [
                                "type": "string",
                                "description": "Optional: Name of the reminder list to add to (default: default list)"
                            ]
                        ],
                        "required": ["title"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        register("delete_reminder", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "delete_reminder",
                    "description": "Delete a reminder from Apple Reminders app by its ID. MULTI-STEP APPROACH: Use list_reminders first to find and show matching reminders to user, confirm which to delete, then delete. After deleting, check if there are related tasks or calendar events (search by title keywords) and inform user - they might want to clean those up too. This keeps the user's entire system consistent.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "reminder_id": [
                                "type": "string",
                                "description": "The unique identifier of the reminder to delete. Required."
                            ]
                        ],
                        "required": ["reminder_id"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
        
        // Notes tools
        register("list_notes", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "list_notes",
                    "description": "List notes stored in MinuteMind. Optionally filter by project. Returns note IDs, titles, content previews, tags, and dates. Use this before editing or deleting to find the note_id you need — never ask the user for an ID.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "project_id": [
                                "type": "string",
                                "description": "Optional: UUID of a project. When provided, only notes linked to that project are returned. Omit to return all notes."
                            ]
                        ],
                        "required": [] as [String]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))

        register("search_notes", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "search_notes",
                    "description": "Search notes by keyword. Matches against note title and content. Use this to find a specific note before editing it. Returns note IDs, titles, snippets, and tags.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": "The search keyword or phrase to match against note titles and content. Required."
                            ],
                            "project_id": [
                                "type": "string",
                                "description": "Optional: restrict the search to notes linked to this project UUID."
                            ]
                        ],
                        "required": ["query"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))

        register("create_note", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "create_note",
                    "description": "Create a new manual note in MinuteMind, optionally linked to a project. Use this to capture information, decisions, or context the user wants saved as a note. Returns the new note's ID so it can be referenced in follow-up actions.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "title": [
                                "type": "string",
                                "description": "The title of the note. Required."
                            ],
                            "content": [
                                "type": "string",
                                "description": "The main body text of the note. Can be empty if only a title is needed."
                            ],
                            "tags": [
                                "type": "array",
                                "items": ["type": "string"],
                                "description": "Optional list of tags to categorize the note (e.g., [\"decision\", \"architecture\"])."
                            ],
                            "project_id": [
                                "type": "string",
                                "description": "Optional: UUID of the project this note should be linked to. If omitted and there is a current project context, the note is linked to the current project."
                            ]
                        ],
                        "required": ["title"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))

        register("update_note", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "update_note",
                    "description": "Update an existing note's title, content, or tags. Only the fields you provide are changed; omitted fields are left as-is. Use list_notes or search_notes first to obtain the note_id.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "note_id": [
                                "type": "string",
                                "description": "UUID of the note to update. Required."
                            ],
                            "title": [
                                "type": "string",
                                "description": "New title for the note. Omit to keep the existing title."
                            ],
                            "content": [
                                "type": "string",
                                "description": "New body text. Omit to keep the existing content."
                            ],
                            "tags": [
                                "type": "array",
                                "items": ["type": "string"],
                                "description": "Replacement tag list. Omit to keep existing tags. Pass an empty array to clear all tags."
                            ]
                        ],
                        "required": ["note_id"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))

        register("delete_note", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "delete_note",
                    "description": "Permanently delete a note by ID. Use list_notes or search_notes first to confirm the correct note_id before calling this. This action cannot be undone.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "note_id": [
                                "type": "string",
                                "description": "UUID of the note to delete. Required."
                            ]
                        ],
                        "required": ["note_id"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))

        // Knowledge base tool
        register("commit_to_knowledge_base", tool: AgentTool(
            definition: [
                "type": "function",
                "function": [
                    "name": "commit_to_knowledge_base",
                    "description": "Save important information, decisions, or insights to the project's knowledge base for future reference. Use this when the conversation produces valuable knowledge that should be preserved: technical decisions, architecture patterns, lessons learned, best practices, or key facts. This makes the knowledge searchable and available in future sessions. Always provide a clear title and descriptive category.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "content": [
                                "type": "string",
                                "description": "The full text content to save to the knowledge base. Should be well-formatted and self-contained. Required."
                            ],
                            "title": [
                                "type": "string",
                                "description": "A clear, descriptive title for this knowledge entry. Required."
                            ],
                            "category": [
                                "type": "string",
                                "description": "Category for organizing knowledge (e.g., 'Technical Decision', 'Best Practice', 'Architecture', 'Meeting Notes', 'Troubleshooting'). Required."
                            ],
                            "project_id": [
                                "type": "string",
                                "description": "Optional: UUID of the project to save this knowledge to. If not provided, uses the current project context or saves globally."
                            ]
                        ],
                        "required": ["content", "title", "category"]
                    ]
                ]
            ],
            execute: { _ in "" }
        ))
    }
}

// MARK: - Argument Decodable Structs

struct ListEventsArgs: Codable {
    let start_date: String
    let end_date: String
}

struct SearchEventsArgs: Codable {
    let start_date: String?
    let end_date: String?
    let days_ahead: Int?
}

struct CreateEventArgs: Codable {
    let title: String
    let start_date: String
    let end_date: String
    let location: String?
    let notes: String?
    let url: String?
    let is_all_day: Bool?
    let alert_minutes_before: Int?
}

struct ListTasksArgs: Codable {
    let project_id: String?
    let include_completed: Bool?
}

struct CreateTaskArgs: Codable {
    let project_id: String?
    let title: String
    let description: String?
    let priority: String?
    let due_date: String?
    let status: String?
    let epic_id: String?
}

struct WebSearchArgs: Codable {
    let query: String
    let result_count: Int?
}

struct FetchWebpageArgs: Codable {
    let url: String
    let max_length: Int?
}

struct UpdateTaskArgs: Codable {
    let project_id: String?
    let task_id: String
    let title: String?
    let description: String?
    let priority: String?
    let due_date: String?
    let is_completed: Bool?
    let assignee: String?
    let status: String?
    let epic_id: String?
}

struct DeleteTaskArgs: Codable {
    let project_id: String?
    let task_id: String
}

struct ListRemindersArgs: Codable {
    let include_completed: Bool?
    let list_name: String?
    let days_ahead: Int?
}

struct CreateReminderArgs: Codable {
    let title: String
    let notes: String?
    let due_date: String?
    let priority: Int?
    let list_name: String?
}

struct DeleteEventArgs: Codable {
    let event_id: String
}

struct DeleteReminderArgs: Codable {
    let reminder_id: String
}

struct CommitToKnowledgeBaseArgs: Codable {
    let content: String
    let title: String
    let category: String
    let project_id: String?
}

struct ListNotesArgs: Codable {
    let project_id: String?
}

struct SearchNotesArgs: Codable {
    let query: String
    let project_id: String?
}

struct CreateNoteArgs: Codable {
    let title: String
    let content: String?
    let tags: [String]?
    let project_id: String?
}

struct UpdateNoteArgs: Codable {
    let note_id: String
    let title: String?
    let content: String?
    let tags: [String]?
}

struct DeleteNoteArgs: Codable {
    let note_id: String
}

struct ListEpicsArgs: Codable {
    let project_id: String?
}

struct CreateEpicArgs: Codable {
    let project_id: String?
    let title: String
    let summary: String?
    let color_hex: String?
}

struct BoardSummaryArgs: Codable {
    let project_id: String?
}
