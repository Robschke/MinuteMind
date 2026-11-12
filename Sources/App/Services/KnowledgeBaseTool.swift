import Foundation

/// A tool definition for AI units to search the knowledge base.
/// This can be used to generate tool calls for OpenAI or other providers.
struct KnowledgeBaseTool {

    /// The function name for tool calling
    static let name = "search_knowledge_base"

    /// The description for the AI to understand when to use this tool
    static let description = """
        Searches the organizational knowledge base for technical specifications, historical decisions, meeting outcomes, project context, and documented patterns.
        This tool uses hybrid search combining:
        1) Document title keyword matching (highest priority - finds documents by their titles)
        2) Content Full-Text Search (FTS) with Porter stemming (finds relevant text snippets)
        Results are ranked with title matches appearing first, ensuring most relevant documents surface quickly.
        
        WHEN TO USE: Use this proactively when creating tasks, making decisions, or answering questions that might reference past work. Before suggesting solutions or creating tasks, search the knowledge base to:
        1) Check if similar tasks/issues were discussed before and learn from past decisions
        2) Find technical specs, architecture decisions, or dependencies that inform current work
        3) Discover related meeting notes, action items, or context from previous sessions
        4) Avoid duplicating work by finding existing solutions or approaches
        
        SEARCH STRATEGY: For best results, include keywords that might appear in document titles (e.g., "API", "database", "architecture") or specific technical terms. The hybrid search will match both title keywords and content, with title matches prioritized.
        
        WORKFLOW: Search first to ground your responses in documented facts, then synthesize findings with user's current request. If knowledge base has relevant context, cite it and build upon it. This makes you an intelligent assistant that learns from organizational memory, not just a task manager.
        """

    /// The JSON schema for the tool parameters
    nonisolated(unsafe) static let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Search keywords. Include document title keywords for best results (e.g., 'API design', 'database schema'). The search uses hybrid matching: title keywords (highest priority) + content Full-Text Search with Porter stemming.",
            ],
            "projectID": [
                "type": "string",
                "description":
                    "Optional UUID of the project to filter by. If omitted, searches all projects.",
            ],
        ],
        "required": ["query"],
    ]

    /// The execution logic for the tool
    @MainActor
    static func execute(query: String, projectID: UUID?, store: KnowledgeStore) async throws
        -> [ChunkSearchResult]
    {
        return try store.searchChunks(keyword: query, projectID: projectID)
    }
}
