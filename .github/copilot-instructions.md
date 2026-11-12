## Purpose

This file provides actionable guidance for AI coding agents working on MinuteMind. Focus on concrete patterns and workflows to be immediately productive.

## Quick start
- Build: `swift build` in project root
- Test: `swift test` (uses `swift-testing` with `@Test` macro, NOT XCTest)
- Run: `./Scripts/package_app.sh --install` (builds release app bundle, copies to `~/Applications`)
- Debug: `log show --predicate 'process == "MinuteMind"' --last 5m` for system logs

## Big picture
- **Platform**: macOS SwiftUI app (single executable `MinuteMind`) defined in [Package.swift](Package.swift#L1) with Swift 6.2, targeting macOS 14+.
- **Entry point**: [Sources/App/MinuteMindApp.swift](Sources/App/MinuteMindApp.swift#L1) — injects `AppViewModel` into environment using `@StateObject`/`@EnvironmentObject` pattern. Multi-window app with WindowGroups for main UI, settings, meeting minutes, and global assistant.
- **State & orchestration**: `AppViewModel` ([Sources/App/ViewModels/AppViewModel.swift](Sources/App/ViewModels/AppViewModel.swift#L1)) — marked `@MainActor`, handles entire app lifecycle: recording, transcription, AI processing (meeting minutes, todo extraction, knowledge extraction), project management, and system integrations (Calendar, Reminders, Teams detection).
- **Storage architecture**: Multiple stores with distinct responsibilities:
  - `RecordingStore` (JSON) — sessions list in `sessions.json`, manages `Recordings/`, `Transcripts/`, `MeetingMinutes/` directories
  - `ProjectStore` (JSON) — projects and tasks in separate JSON files  
  - `KnowledgeStore` (SQLite + GRDB) — full-text search with FTS5, embeddings support, document chunking
  - `ChatHistoryStore` (JSON) — persists chat sessions with global assistant
  - `WorkspaceStore` (JSON) — hierarchical file/folder structure per project in `Workspaces/` directory
- **Transcription**: Two services — `TranscriptionService` (Apple Speech on-device) and `WhisperTranscriptionService` (OpenAI API). `LiveTranscriptionService` provides real-time transcription during recording.
- **AI Services**: All use OpenAI-compatible chat completions API with profile-based configuration:
  - `MeetingMinutesService` — generates structured minutes from transcripts
  - `TodoExtractionService` — extracts tasks with assignees/due dates
  - `KnowledgeExtractionService` — pulls reusable knowledge from minutes
  - `KnowledgeChatService` — tool-enabled chat with function calling (search knowledge base, calendar operations, reminders management)
  - `CalendarBlockerService` — AI-powered time block suggestions using structured JSON output
  - `OllamaService` — manages local Ollama installation, model downloads, and API interactions for on-device AI
- **Tool execution**: `ToolExecutor` ([Sources/App/Services/ToolExecutor.swift](Sources/App/Services/ToolExecutor.swift#L1)) handles agent tool calls with proper JSON encoding/decoding, authorization checks, and error handling. Tool definitions in `AgentTools.swift` use OpenAI function calling schema. `AgentToolRegistry` (singleton) manages tool registration and lookup.
- **Web search integration**: `WebSearchService` uses public SearxNG instances for web search and webpage fetching. Implements fallback rotation across multiple instances for reliability. Tools: `web_search` and `fetch_webpage_content`.
- **Audio/file processing**: `AudioProcessor` generates waveforms with VAD (voice activity detection) and handles audio cropping. `FileParserService` extracts text from PDF/Word/PowerPoint for knowledge base ingestion.
- **Project workspaces**: Each project has hierarchical workspace managed by `WorkspaceStore` — supports folders/files with metadata (size, type, URLs). Files copied to `Workspaces/<projectID>/` on import. UI pattern in `WorkspaceView` (Finder-like navigation with breadcrumbs).

## Data flow (concrete)
- Recording: `MicRecorder` writes `.caf` files, `SystemAudioRecorder` writes `.m4a` files to `Recordings/` (filenames via `AppViewModel.startRecording`). Both conform to async/await patterns with `AVAudioEngine` and `AudioQueue` APIs.
- Transcription: `AppViewModel` invokes `TranscriptionService.transcribeSession(...)` (Apple Speech) or `WhisperTranscriptionService.transcribe(...)` (OpenAI API) with mic/system URLs. Results written to `Transcripts/` via `persistTranscriptFile` with merged text from both channels. `TranscriptionService.isNoSpeechDetected(_:)` contains domain logic for handling silent recordings.
- Sessions list: `RecordingStore.saveSessions(_:)` serializes `[RecordingSession]` to JSON with ISO8601 dates (atomic write). `loadSessions()` deserializes. Round-trip tested in [Tests/RecordingStoreTests.swift](Tests/RecordingStoreTests.swift#L1).
- Meeting minutes: `AppViewModel.generateMeetingMinutes` fetches active profile + prompt from `OpenAIProfiles`, POSTs to chat completions API via `MeetingMinutesService.generateMinutes(...)`, saves result to `MeetingMinutes/<sessionID>-minutes.txt`.
- Knowledge base: `KnowledgeExtractionService.extract(...)` parses Markdown sections from meeting minutes (regex-based), creates documents + chunks, stored via `KnowledgeStore` in SQLite with FTS5 triggers for automatic index updates. Embeddings optional (stored as JSON blob).
- Todo extraction: `TodoExtractionService` uses structured JSON output from AI to extract tasks, which are then stored via `ProjectStore` and can be synced to Apple Reminders via `RemindersService`.
- Calendar blocking: `CalendarBlockerService` generates AI time block suggestions with ISO8601 date formatting. Uses structured JSON output mode for reliable parsing.
- Global assistant: `KnowledgeChatService` implements tool-enabled chat with function calling. `ToolExecutor` handles tool execution including knowledge base search (FTS5 + optional vector similarity), calendar operations (EventKit), reminders management. Tool responses are JSON-formatted and fed back to the AI.
- Web search flow: `WebSearchService.search(query:resultCount:)` returns `SearchResponse` with results array. Each `SearchResult` has title, URL, snippet. `fetchWebpage(url:maxLength:)` extracts clean text content using regex-based HTML stripping. Both use async/await and rotate through SearxNG instances on failure.

## Critical developer workflows
- **Build (development)**: `swift build` in project root
- **Run tests**: `swift test` (uses `swift-testing` framework with `@Test` macro, not XCTest). Set `SKIP_NETWORK_TESTS=1 swift test` to skip web search integration tests that require network access.
- **Run app bundle (local)**: `./Scripts/package_app.sh` builds `dist/MinuteMind.app` with release binary + Info.plist; pass `--install` to copy into `~/Applications`. Script runs tests (with SKIP_NETWORK_TESTS=1) before building.
- **Debugging**: Open `Package.swift` in Xcode or run the app bundle. `AppViewModel.errorMessage` surfaces runtime errors to UI. Use `log show --predicate 'process == "MinuteMind"'` for system logs.
- **Code signing**: Script auto-detects "MinuteMind-Self-Signed" certificate or falls back to ad-hoc signing (may cause permission prompts on each rebuild).
- **Info.plist embedding**: Uses Swift linker flags (`-Xlinker -sectcreate`) to embed Info.plist at build time into `__TEXT` segment — see [Package.swift](Package.swift#L1) `swiftSettings`. This allows SPM executable to behave as proper macOS app bundle.
- **File watching**: `FileWatcher` monitors directories for changes using `DispatchSource.makeFileSystemObjectSource` — triggers auto-reload of sessions when transcripts/minutes change externally.
- **Dependencies**: Managed via Swift Package Manager (GRDB for SQLite, MarkdownUI for rendering). Run `swift package resolve` to update.

## Project-specific conventions & patterns
- **Persisted sessions** are a JSON array at `sessions.json` (see `RecordingStore`). Keep the encoder/decoder's ISO8601 date strategy when modifying persistence — this is crucial for date round-trip accuracy.
- **Filenames** are generated using `AppViewModel.fileSafeSlug(...)` — keep that behavior if you add alternate naming (replaces invalid chars, lowercases).
- **Transcription** can return empty string on "no speech" — `TranscriptionService.isNoSpeechDetected(_:)` contains domain-specific detection logic (checks for minimal word count). When handling transcription failures, prefer surfacing the localized error message to the UI (pattern used in `AppViewModel.transcribe`).
- **OpenAI integration** is profile-driven: `OpenAICredentialProfile` and `OpenAIProfilesFile` live in [Sources/App/Config/OpenAIProfiles.swift](Sources/App/Config/OpenAIProfiles.swift#L1). Profiles include provider-specific fields:
  - Azure fields (deployment, API version) are optional but required for Azure provider
  - Ollama provider (local) — requires running Ollama service on localhost:11434, no API key needed
  - System prompts are stored per-profile with enable/select flags
  - Default prompt in `OpenAICredentialProfile.defaultPrompt()` expects Markdown output with specific sections
  - Providers: `.openAI`, `.azure`, `.ollama` (see `OpenAIProvider` enum)
- **Endpoint assembly** for Azure is in `AppViewModel.endpointURL(for:)` — uses base URL + deployment + API version query param. Change there if you alter how Azure endpoints are formed.
- **Audio file extensions**: Microphone uses `.caf` (Core Audio Format), system speaker uses `.m4a` (AAC). Keep playback code in `ContentView`'s `AudioPlaybackButton` consistent with these formats.
- **@MainActor usage**: `AppViewModel` and most ViewModels are `@MainActor`-isolated. Keep this pattern when adding services that update UI state. `ToolExecutor` is also `@MainActor` for safe access to app state.
- **Knowledge base chunking**: `KnowledgeExtractionService` splits documents at sentence boundaries (regex-based) with 500-char target chunks and 100-char overlap. Modify chunking logic there if needed.
- **Test patterns**: Use `swift-testing` with `@Test` macro (not XCTest). Tests use temporary directories for isolation (see `KnowledgeBaseTests` for SQLite testing pattern with in-memory DB).
- **Workspace file operations**: `WorkspaceStore.addFile` copies files to `Workspaces/<projectID>/` and auto-renames on collision (appends counter). Maintains hierarchical structure with `parentID` references. Delete operations remove files from disk. UI uses recursive folder navigation with breadcrumbs (pattern in `WorkspaceView`).

## Integration points & external dependencies
- Apple Speech framework (`SFSpeechRecognizer`) — requires runtime user permission; the request flow is implemented in `TranscriptionService.ensureAuthorization()` and controlled by `Info.plist` in [Sources/App/Supporting/Info.plist](Sources/App/Supporting/Info.plist#L1). Key: `NSSpeechRecognitionUsageDescription`.
- EventKit (Calendar & Reminders) — `CalendarService` and `RemindersService` handle authorization requests. `ToolExecutor` checks `isAuthorized` before operations and requests access if needed (async pattern).
- Microsoft Teams detection — `TeamsCallDetector` uses macOS Accessibility API to monitor running applications. Requires accessibility permissions (see `TeamsCallDetector.checkAccessibilityPermission()`). Can be toggled via `AppViewModel.teamsCallDetectionEnabled`.
- OpenAI-compatible HTTP API — all AI services (`MeetingMinutesService`, `TodoExtractionService`, `KnowledgeChatService`) use chat completions endpoint. Request format: JSON with `model`, `messages`, optional `tools` array. Response parsing expects `choices[].message.content`. Azure uses `api-key` header; OpenAI uses `Authorization: Bearer <apiKey>`.
- Ollama (local AI) — `OllamaService` manages local Ollama installation at `http://localhost:11434`. Key methods: `checkOllamaInstallation()` (checks if service running), `isModelDownloaded(_:)`, `downloadModel(_:)` (streaming progress via `/api/pull`), `listModels()`. Response format differs from OpenAI: uses `message` field instead of `choices[]`, includes `created_at`, `done` fields. Tool calling support tested in `OllamaIntegrationTests`.
- GRDB (SQLite) — `KnowledgeStore` uses GRDB with FTS5 for full-text search. Migration pattern in `migrator` property. Tables use auto-incrementing primary keys and FTS5 triggers for automatic index updates.
- MarkdownUI — used for rendering meeting minutes and knowledge entries in views. See `MarkdownDisplayView` component.
- Packaging: the release bundle creation uses `swift build -c release` and copies a custom `Info.plist` into the app bundle (see `Package.swift`'s linker flags via `-Xlinker` and [Scripts/package_app.sh](Scripts/package_app.sh#L1)). The Info.plist is embedded at build time into the `__TEXT` segment of the binary.

## Small but important details to preserve
- **Audio file extensions**: microphone uses `.caf`, system speaker uses `.m4a` (convention in `AppViewModel.startRecording`). Keep playback code in `ContentView`'s `AudioPlaybackButton` consistent with these formats.
- **Meeting minutes prompts**: default prompt is `OpenAICredentialProfile.defaultPrompt()` — it expects Markdown output with sections (used by UI to open `.txt` files). Sections: Summary, Decisions Made, Action Items, Discussion Points, Risks & Concerns, Attendees, Project Knowledge.
- **Ollama API differences**: Ollama's response format differs from OpenAI — uses `message` field instead of `choices[]`, includes `created_at` and `done` fields. Services must handle both formats. Tool calling works but response structure varies (see `OllamaIntegrationTests` for format validation).
- **Tool message encoding**: `KnowledgeChatService.ChatMessage.encode(to:)` has special handling for OpenAI API requirements — tool messages MUST have non-empty content string, assistant messages with tool calls can omit content field entirely (not null, omitted).
- **Authorization flow pattern**: Services check `isAuthorized` property, then call async `requestAccess()` if needed, returning success boolean. This pattern is used in `CalendarService`, `RemindersService`, and `TranscriptionService`.
- **Database migrations**: `KnowledgeStore` uses GRDB's `DatabaseMigrator` with named migrations ("v1", "v2", etc.). Each migration is idempotent and runs once. Current schema is at "v4" with documents + chunks architecture.
- **Live transcription**: `LiveTranscriptionService` provides partial results via callback, updating `AppViewModel.liveTranscriptPartial`. Final results update `liveTranscriptText`. Preview is calculated from recent segments.

## Quick examples (where to look)
- Start point / DI: [Sources/App/MinuteMindApp.swift](Sources/App/MinuteMindApp.swift#L1) -> `AppViewModel` ([Sources/App/ViewModels/AppViewModel.swift](Sources/App/ViewModels/AppViewModel.swift#L1)).
- Persist / load sessions: `RecordingStore.saveSessions` / `loadSessions` ([Sources/App/Store/RecordingStore.swift](Sources/App/Store/RecordingStore.swift#L1)).
- Transcription entry: `TranscriptionService.transcribeSession` ([Sources/App/Transcription/TranscriptionService.swift](Sources/App/Transcription/TranscriptionService.swift#L1)).
- API integration: `MeetingMinutesService.generateMinutes` ([Sources/App/Services/MeetingMinutesService.swift](Sources/App/Services/MeetingMinutesService.swift#L1)).
- Tool execution: `ToolExecutor.execute` ([Sources/App/Services/ToolExecutor.swift](Sources/App/Services/ToolExecutor.swift#L1)) — shows pattern for tool dispatch, JSON decoding, auth checks, and response formatting.
- Knowledge base search: `KnowledgeStore.search` — FTS5 query with ranking (bm25). Vector search optional via `searchByEmbedding`.
- Chat with tools: `KnowledgeChatService.sendMessage` — implements OpenAI function calling with multi-turn tool execution loop.
- Web search: `WebSearchService.search(...)` and `fetchWebpage(...)` — see [Tests/WebSearchServiceTests.swift](Tests/WebSearchServiceTests.swift#L1) for usage patterns.
- Workspace operations: `WorkspaceStore.createFolder/addFile/deleteItem/renameItem` — see [Sources/App/Views/WorkspaceView.swift](Sources/App/Views/WorkspaceView.swift#L1) for Finder-like UI pattern.

## When editing, prefer small, local changes
- **Changing persistence format**: update `RecordingStore` and incrementally migrate sessions; preserve ISO8601 dates.
- **Changing audio filenames**: update `fileSafeSlug`, UI playback, and any tests referencing filenames.
- **Changing OpenAI API shape**: update `MeetingMinutesService` and `OpenAICredentialProfile`, ensure UI reflects required config fields.
- **Adding tool functions**: Update `AgentTools.swift` tool definitions, add case to `ToolExecutor.execute`, implement handler with proper JSON decoding and auth checks (see existing tools as template).
- **Modifying knowledge base schema**: Add new migration in `KnowledgeStore.migrator` (sequential version names like "v5", "v6"). Test with temporary directory pattern from `KnowledgeBaseTests`.
- **Extending AI services**: Follow the `MeetingMinutesService` pattern — struct with async func, proper header handling (Azure vs OpenAI), decode `choices[].message.content`.
- **Workspace modifications**: For file/folder operations, update `WorkspaceStore` methods and ensure UI in `WorkspaceView` reflects changes (breadcrumbs, recursive folder display).

## Tests and how CI should run them
- Run `swift test` in CI; tests expect no global state and use temporary directories (see [Tests/RecordingStoreTests.swift](Tests/RecordingStoreTests.swift#L1)).
- **Test framework**: `swift-testing` with `@Test` macro (NOT XCTest). Use `#expect` assertions, not `XCTAssert*`.
- **Module imports**: Tests use `@testable import MinuteMindApp` to access internal members. The `@testable` attribute is required since the main target is an executable.
- **Isolation**: Tests create temp directories via `FileManager.temporaryDirectory` and clean up in `defer` blocks.
- **Database tests**: Use in-memory or temporary SQLite files. Pattern in [Tests/KnowledgeBaseTests.swift](Tests/KnowledgeBaseTests.swift#L1) — create unique temp dir per test.
- **No mocking**: Tests use real implementations where possible (RecordingStore, KnowledgeStore). For external services (OpenAI), tests verify request building without actual API calls.
- **Network tests**: Web search tests (see [Tests/WebSearchServiceTests.swift](Tests/WebSearchServiceTests.swift#L1)) use real SearxNG instances. Skip with `SKIP_NETWORK_TESTS=1` env var if network unavailable or in CI environments with restricted access.

## If something is missing or unclear
- Ask which area to expand (build, packaging, tests, or OpenAI profile usage). Provide sample API credentials only for local debugging — never commit secrets.

---
Please review and tell me any missing details or preferences to iterate.
