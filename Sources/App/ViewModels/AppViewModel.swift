import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Speech
import SwiftUI
import UserNotifications

@Observable
@MainActor
final class AppViewModel {
    enum LanguageOption: String, CaseIterable, Identifiable {
        case auto = "auto"
        case english = "en-US"
        case german = "de-DE"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto:
                return "Auto-detect"
            case .english:
                return "English (US)"
            case .german:
                return "Deutsch"
            }
        }

        var isAutoDetect: Bool {
            self == .auto
        }
    }

    private(set) var sessions: [RecordingSession] = []
    var isRecording = false
    var selectedLanguage: LanguageOption = .auto
    var currentSession: RecordingSession?
    var isTranscribing = false
    var errorMessage: String? {
        didSet {
            // Kept for diagnostics (get_app_status): the alert is gone once dismissed.
            guard let errorMessage, errorMessage != oldValue else { return }
            recentErrors = Array(([AppErrorRecord(date: Date(), message: errorMessage)] + recentErrors).prefix(20))
        }
    }
    /// The last error messages shown to the user, newest first (AppViewModel+Diagnostics.swift).
    private(set) var recentErrors: [AppErrorRecord] = []
    var pendingSessionTitle: String = ""
    /// Project the next manual recording is assigned to. Optional — with none selected
    /// the session is recorded without a project (no file export), as before this
    /// feature. Calendar-triggered recordings resolve theirs from the event's project
    /// mapping instead. Persisted so hotkey/Teams starts reuse the last choice.
    var pendingProjectID: UUID? {
        didSet {
            UserDefaults.standard.set(
                pendingProjectID?.uuidString, forKey: "mm.pendingProjectID")
        }
    }
    var selectedMinutesSession: RecordingSession?
    var initialKnowledgeEditingState: Bool = false
    /// The summary prompts (Settings, AI); the selected, enabled one writes the summary.
    private(set) var summaryPrompts: [SystemPrompt] = []
    private(set) var minutesGenerationInProgress: Set<UUID> = []
    private(set) var todoExtractionInProgress: Set<UUID> = []
    var knowledgeExtractionInProgress: Set<UUID> = []
    var searchQuery: String = ""
    var isShowingAIAssistant = false
    var isLiveTranscribing = false
    var liveTranscriptText = ""
    var liveTranscriptPreview = ""
    var liveTranscriptPartial = ""
    var transcriptionProgress: (current: Int, total: Int)? = nil
    var transcriptionProgressMessage: String = ""
    var transcribingSessionID: UUID? = nil
    /// Non-nil while the Parakeet model is downloading/loading.
    var parakeetLoadingMessage: String? = nil
    /// Download fraction (0.0–1.0). Non-zero only while a Parakeet model download is in progress.
    var parakeetDownloadProgress: Double = 0
    /// True after the Parakeet model has been downloaded and is ready to use.
    var parakeetModelInstalled: Bool = false
    /// True while a Parakeet install/download is in progress (disables install button in Settings).
    var isInstallingParakeet: Bool = false
    /// Display name of the installed Parakeet model ("Parakeet Ultra"), nil when none is installed.
    var parakeetModelName: String? = nil
    /// When the installed Parakeet revision was downloaded, if recorded.
    var parakeetInstalledAt: Date? = nil
    /// Result of the last Parakeet update check (Settings, Automation).
    var parakeetUpdateState: ParakeetUpdateState = .unknown
    /// Why the last Parakeet install failed, nil after a successful one (diagnostics).
    var parakeetLastError: String? = nil

    enum ParakeetUpdateState: Equatable {
        case unknown
        case checking
        case upToDate
        case available(ParakeetTranscriptionService.UpdateStatus)
        case failed
    }

    // Project management
    private(set) var projects: [Project] = []
    private(set) var tasks: [ProjectTask] = []
    private(set) var epics: [Epic] = []
    var selectedProjectID: UUID? { didSet { if selectedProjectID != nil { isShowingInbox = false; isShowingClipboard = false; isShowingHome = false } } }
    var isShowingAllTasks = false { didSet { if isShowingAllTasks { isShowingInbox = false; isShowingClipboard = false; isShowingHome = false } } }
    /// When set to true, all other exclusive navigation flags (isShowingAllTasks,
    /// isShowingAIAssistant) must be set to false.
    var isShowingCalendar = false { didSet { if isShowingCalendar { isShowingInbox = false; isShowingClipboard = false; isShowingHome = false } } }
    /// Inbox of meetings waiting to be processed. Turning any other destination on turns this
    /// off (didSets above), so existing navigation code needs no change.
    var isShowingInbox = false { didSet { if isShowingInbox { isShowingClipboard = false; isShowingHome = false } } }
    /// The dictation history ("Clipboard" in the sidebar). Exclusive like the inbox.
    var isShowingClipboard = false { didSet { if isShowingClipboard { isShowingInbox = false; isShowingHome = false } } }
    /// Home: the project tiles (HomeView). The window opens on it. Exclusive like the others:
    /// turning it on clears every other destination, any other destination turns it off.
    var isShowingHome = true {
        didSet {
            guard isShowingHome else { return }
            selectedProjectID = nil
            isShowingAllTasks = false
            isShowingCalendar = false
            isShowingInbox = false
            isShowingClipboard = false
        }
    }
    /// Each project's section (Overview, Workspace, Jobs), remembered across launches
    /// (`mm.projectTabs`); read through `projectTab(for:)` (AppViewModel+Navigation.swift).
    var projectTabs: [UUID: ProjectTab] = AppViewModel.loadProjectTabs()
    /// Projects (and General) most recently visited first, for the Cmd+K switcher (`mm.recentProjects`).
    var recentProjectIDs: [UUID] = AppViewModel.loadRecentProjects()
    /// Back and forward between places (mouse buttons 4 and 5, AppViewModel+Navigation.swift).
    var navigationHistory = NavigationHistory()
    /// The place a back or forward step is going to, so arriving there is not recorded as a visit.
    @ObservationIgnored var historyTarget: NavigationPlace?
    /// Home's New Project tile asks the Home sidebar (ProjectsSidebarView) to open its sheet.
    var requestsNewProject = false

    var audioDeviceManager = AudioDeviceManager()
    var teamsCallDetectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "mm.teamsDetectionEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "mm.teamsDetectionEnabled") }
    }
    var showTeamsConsentInfo = false
    /// Session ID of the currently active auto-recorded Teams call (nil when not in a Teams session).
    private var teamsSessionID: UUID?

    let teamsCallDetector = TeamsCallDetector()
    /// Detects calls in any meeting app and screen sharing; feeds the meeting pill.
    let meetingRadar = MeetingRadar()
    /// The floating pill that asks to record, shows the recording and offers processing.
    let meetingPill = MeetingPillController()
    /// The desktop creature that carries the pill's popups and reports Claude sessions.
    let companion = CompanionController()
    /// Captured from the main window (ContentView), so non-view code can open scenes.
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    /// A section of the selected project to switch to, e.g. Workspace for a Claude session the
    /// companion reveals. Callers set `selectedProjectID` first; the request is applied to that
    /// project's remembered section at once and cleared (AppViewModel+Navigation.swift).
    var requestedProjectTab: ProjectTab? {
        didSet { applyRequestedProjectTab() }
    }
    /// A Settings page to switch to (MeetingMinutesSettingsView consumes it), set when Claude
    /// opens a page over MCP (AppViewModel+AppControl.swift).
    var requestedSettingsTab: MeetingMinutesSettingsView.Tab?
    /// Sessions the user asked to process while their transcription was still pending.
    private var processRequests: Set<UUID> = []
    /// True while the running recording is shown in the pill (every normal recording, not live dictation).
    private var pillTracksRecording = false
    let remindersService = RemindersService()
    let calendarService = CalendarService()

    private let store: RecordingStore
    private let waveformStore: WaveformStore
    private let summaryPromptStore: SummaryPromptStore
    internal let projectStore: ProjectStore
    let autoRecordStore: AutoRecordStore
    let eventProjectStore: EventProjectStore
    let eventLanguageStore: EventLanguageStore
    /// Voices the user has named before, so diarized speakers are recognised across recordings.
    let voiceDirectory: VoiceDirectoryStore
    private let eventNotesStore: EventNotesStore
    var eventNotes: [EventNote] = []
    private(set) var automationCoordinator: AutomationCoordinator!
    let automationSettings: AutomationSettings
    let transcriptionQueue = TranscriptionQueue()
    /// When set before calling startRecording(), the session is auto-populated with calendar
    /// metadata and the event's project assignment. Cleared after each startRecording() call.
    var pendingCalendarEvent: CalendarEvent? = nil
    var showTodoBriefSheet = false
    var pendingTodoBrief: TodoBrief? = nil
    private let micRecorder = MicRecorder()
    /// Latest RMS audio level from the microphone tap. Used by AutomationCoordinator for silence detection.
    var currentMicLevel: Float { micRecorder.currentLevel }
    /// Louder of microphone and system audio: the call is only silent when both sides are.
    var currentCallLevel: Float { max(micRecorder.currentLevel, systemRecorder.currentLevel) }
    private let systemRecorder = SystemAudioRecorder()
    private let transcriptionService = TranscriptionService()
    private let liveTranscriptionService = LiveTranscriptionService()
    private let transcriptCleanupService = TranscriptCleanupService()
    /// Session IDs currently being polished by the AI cleanup.
    private var transcriptCleanupInProgress: Set<UUID> = []
    /// Cleanups started right after transcription, which processing waits for.
    private var earlyCleanups: [UUID: Task<Void, Never>] = [:]
    /// The last early cleanup queued; the next one starts after it (one model run at a time).
    private var lastEarlyCleanup: Task<Void, Never>?
    /// Meetings whose early cleanup has run, so processing does not clean them up again.
    private var earlyCleanupDone: Set<UUID> = []
    /// Speaker names given while a cleanup ran, re-applied to its result.
    private var renamesDuringCleanup: [UUID: [[String: String]]] = [:]
    private let todoExtractionService = TodoExtractionService()
    private let calendarBlockerService = CalendarBlockerService()
    private let parakeetService = ParakeetTranscriptionService()
    /// Exposed so quick dictation can stream through the same installed Parakeet model instead of
    /// downloading its own copy.
    var parakeetServiceForDictation: ParakeetTranscriptionService { parakeetService }
    private let fileWatcher = FileWatcher()
    private let audioProcessor = AudioProcessor()
    /// On-device speaker-diarization models (pyannote segmentation + speaker embedding).
    let speakerDiarizationModels = SpeakerDiarizationModelStore()
    /// Tracks the post-recording waveform + pipeline task so it can be cancelled.
    private var postRecordingTask: Task<Void, Never>?
    /// True while a waveform is being generated (lets UI show progress / cancel button).
    var isGeneratingWaveform: Bool = false
    /// True while audio files are being copied in by the import feature.
    var isImportingAudio: Bool = false
    /// Maximum recording duration (3 hours). After this, recording auto-stops.
    static let maxRecordingDuration: TimeInterval = 3 * 60 * 60
    /// Timer that auto-stops the recording when maxRecordingDuration is reached.
    private var maxRecordingTimer: Task<Void, Never>?
    let knowledgeStore: KnowledgeStore?
    /// Local MCP server that exposes meetings, tasks, notes and the knowledge base to MCP clients.
    let mcpServer: MinuteMindMCPServer
    /// Real folder + git repo per project, where Claude Code works and meetings are mirrored.
    let projectRepositories: ProjectRepositoryService
    /// Keeps each workspace's knowledge/ folder current (AppViewModel+WorkspaceKnowledge.swift).
    let knowledgeCurator = KnowledgeCurator()
    /// Prompts Claude runs on a schedule in each workspace (AppViewModel+ScheduledJobs.swift).
    let scheduledJobs = ScheduledJobStore()
    /// Background git sync of Shared Projects and its status (AppViewModel+SharedSync.swift).
    let sharedSync = SharedProjectSync()
    /// A job or run to show in the Jobs tab (ScheduledJobsView consumes it), e.g. from a notification.
    var requestedJobRun: ScheduledJobRunReference?
    /// The user's dictionary: terms to get right and the forms they are misheard as.
    let vocabulary: VocabularyStore
    /// Everything said through the dictation key, for the sidebar Clipboard.
    let dictationHistory: DictationHistoryStore
    /// The last texts copied anywhere, for the companion card's Clipboard list (memory only).
    let clipboardHistory = ClipboardHistory()
    /// The live terminals (Claude Code sessions) per project, kept across tab and project switches.
    let workspaceTerminals = WorkspaceTerminalStore()
    /// The file open in each workspace's editor, kept across tab and project switches.
    let workspaceEditors = WorkspaceEditorStore()
    let workspaceStore: WorkspaceStore

    /// Sessions filtered by the current search query (searches title and transcript text)
    var filteredSessions: [RecordingSession] {
        // Filter out sessions that are assigned to projects - they only appear in their project
        let unassignedSessions = sessions.filter { $0.projectID == nil }
        
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty else {
            return unassignedSessions
        }
        return unassignedSessions.filter { session in
            // Search in title
            if session.title.lowercased().contains(trimmedQuery) {
                return true
            }
            // Search in transcript text
            if let transcriptText = session.transcript?.text.lowercased(),
                transcriptText.contains(trimmedQuery)
            {
                return true
            }
            return false
        }
    }

    /// Get the currently selected project
    var selectedProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    /// Get sessions for a specific project
    func sessionsForProject(_ projectID: UUID) -> [RecordingSession] {
        sessions.filter { $0.projectID == projectID }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Get tasks for a specific project
    func tasksForProject(_ projectID: UUID) -> [ProjectTask] {
        tasks.filter { $0.projectID == projectID }
    }

    // MARK: - Storage Analysis

    /// Computes disk usage of all recording artifacts (audio, waveforms, transcripts, minutes),
    /// aggregated overall, per project, and as a list of the largest recordings.
    ///
    /// Sizing reads file metadata only (a stat() per file), so it is cheap; the work runs off the
    /// main actor to keep disk I/O off the UI thread. Keeps the private RecordingStore encapsulated.
    func analyzeStorage() async -> StorageReport {
        let sessionsSnapshot = sessions
        let projectsSnapshot = projects
        let directories = StorageAnalyzer.Directories(
            recordings: store.recordingsDirectory,
            transcripts: store.transcriptsDirectory,
            minutes: store.minutesDirectory,
            waveforms: store.baseDirectory.appendingPathComponent("Waveforms", isDirectory: true)
        )
        return await Task.detached(priority: .utility) {
            StorageAnalyzer.analyze(
                sessions: sessionsSnapshot,
                projects: projectsSnapshot,
                directories: directories
            )
        }.value
    }

    /// Reclaims disk space from a single recording. Returns the number of bytes freed.
    /// - `.recompress`: re-encodes mic/system audio to 32 kbps mono (lossy, not reversible).
    /// - `.deleteAudio`: removes all audio files, keeping the transcript and meeting minutes.
    @discardableResult
    func archiveSession(_ sessionID: UUID, action: StorageArchiveAction) async -> Int64 {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return 0 }
        var session = sessions[index]
        let recordingsDir = store.recordingsDirectory
        var freed: Int64 = 0

        switch action {
        case .recompress:
            // Re-encode the active mic/system files. Pre-crop originals are left untouched.
            let names = [session.micFileName, session.systemFileName].compactMap { $0 }
            for name in names {
                let url = recordingsDir.appendingPathComponent(name)
                if let saved = try? await audioProcessor.recompressForArchive(at: url) {
                    freed += saved
                }
            }

        case .deleteAudio:
            let names = [
                session.micFileName,
                session.systemFileName,
                session.originalMicFileName,
                session.originalSystemFileName,
            ].compactMap { $0 }
            for name in names {
                let url = recordingsDir.appendingPathComponent(name)
                freed += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                try? FileManager.default.removeItem(at: url)
            }
            session.micFileName = nil
            session.systemFileName = nil
            session.originalMicFileName = nil
            session.originalSystemFileName = nil
            session.cropStartTime = nil
            session.cropEndTime = nil
            updateSession(session, persist: true)
        }

        return freed
    }

    /// Archives every recording older than `days` that still has audio. Returns how many recordings
    /// were affected and the total bytes freed.
    @discardableResult
    func archiveSessions(olderThanDays days: Int, action: StorageArchiveAction) async -> (count: Int, freed: Int64) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let targets = sessions.filter { session in
            session.createdAt < cutoff
                && (session.micFileName != nil || session.systemFileName != nil)
        }
        var count = 0
        var freed: Int64 = 0
        for session in targets {
            let saved = await archiveSession(session.id, action: action)
            if saved > 0 || action == .deleteAudio {
                count += 1
                freed += saved
            }
        }
        return (count, freed)
    }

    // MARK: - Audio Retention

    /// Ticks or unticks "Keep audio" on a card. Kept audio is exempt from the 14-day purge.
    func setKeepAudio(_ keep: Bool, for sessionID: UUID) {
        guard var session = sessions.first(where: { $0.id == sessionID }) else { return }
        session.keepAudio = keep ? true : nil
        updateSession(session, persist: true)
    }

    /// Deletes the audio of every recording past AudioRetentionPolicy's retention period that is
    /// not marked "Keep audio". Transcripts and summaries stay. Runs at launch and every 6 hours.
    func purgeExpiredAudio() async {
        let busy = Set(transcriptionQueue.jobs.compactMap { job -> UUID? in
            switch job.status {
            case .pending, .running: return job.sessionID
            default: return nil
            }
        })
        let expired = AudioRetentionPolicy.expiredSessions(in: sessions, busySessionIDs: busy)
        guard !expired.isEmpty else { return }
        var freed: Int64 = 0
        for session in expired {
            freed += await archiveSession(session.id, action: .deleteAudio)
        }
        print("[AudioRetention] Deleted audio of \(expired.count) recording(s), freed \(freed / 1_048_576) MB")
    }

    /// True inside a test process. Tests create AppViewModel against the real App Support folder,
    /// so anything that deletes or rewrites user data at launch must not run there.
    static let isTestProcess: Bool = {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.processName.contains("xctest")
            || process.processName.contains("swiftpm-testing-helper")
    }()

    private func startAudioRetentionLoop() {
        guard !Self.isTestProcess else { return }
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.purgeExpiredAudio()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    // MARK: - Event Notes

    func note(for eventId: String) -> EventNote? {
        eventNotes.first { $0.eventId == eventId }
    }

    func upsertNote(_ note: EventNote) {
        var updated = note
        updated.updatedAt = Date()
        // Manual notes (nil eventId) match by id; calendar notes match by eventId.
        let idx: Int?
        if let eventId = note.eventId {
            idx = eventNotes.firstIndex(where: { $0.eventId == eventId })
        } else {
            idx = eventNotes.firstIndex(where: { $0.id == note.id })
        }
        if let idx {
            eventNotes[idx] = updated
        } else {
            eventNotes.insert(updated, at: 0)
        }
        try? eventNotesStore.save(eventNotes)

        // Embed note content into knowledge base
        Task { await embedNoteInKnowledgeBase(updated) }
    }

    /// Creates a blank manual note linked to the given project and returns it.
    @discardableResult
    func createManualNote(projectId: UUID?) -> EventNote {
        let note = EventNote(title: "Untitled Note", projectId: projectId)
        upsertNote(note)
        return note
    }

    func notesForProject(_ projectId: UUID) -> [EventNote] {
        eventNotes.filter { $0.projectId == projectId }
    }

    func deleteNote(_ note: EventNote) {
        eventNotes.removeAll { $0.id == note.id }
        try? eventNotesStore.save(eventNotes)

        // Remove corresponding KB document
        if let knowledgeStore,
           let doc = try? knowledgeStore.fetchDocument(byNoteID: note.id),
           let docID = doc.id {
            try? knowledgeStore.deleteDocument(id: docID)
        }
    }

    func sessionsForEvent(_ eventID: String) -> [RecordingSession] {
        sessions.filter { $0.calendarEventID == eventID }
    }

    // MARK: - Event → Project Assignment

    /// The project an event's series is routed to. A mapping to a project that no longer exists
    /// counts as none, so its recordings land unassigned in the Inbox instead of nowhere.
    func projectID(for event: CalendarEvent) -> UUID? {
        guard let id = eventProjectStore.projectID(for: event.seriesKey),
            projects.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func setEventProject(_ projectID: UUID?, for event: CalendarEvent) {
        try? eventProjectStore.setProjectID(projectID, for: event.seriesKey)
    }

    /// Per-event transcription language override, or nil when the event uses the global default.
    func languageCode(for event: CalendarEvent) -> String? {
        eventLanguageStore.languageCode(for: event.seriesKey)
    }

    func setEventLanguage(_ languageCode: String?, for event: CalendarEvent) {
        try? eventLanguageStore.setLanguageCode(languageCode, for: event.seriesKey)
    }

    // MARK: - Parakeet Model Management

    /// Downloads and installs the newest Parakeet model (Ultra, or a newer revision of it). The installed
    /// model keeps working until the download is complete. Updates published state throughout.
    func installParakeetModel() async {
        isInstallingParakeet = true
        parakeetDownloadProgress = 0

        parakeetService.onModelLoadProgress = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.parakeetLoadingMessage = message.isEmpty ? nil : message
            }
        }
        parakeetService.onDownloadProgress = { [weak self] fraction in
            Task { @MainActor [weak self] in
                self?.parakeetDownloadProgress = fraction
            }
        }

        do {
            try await parakeetService.downloadModel()
            parakeetModelInstalled = true
            parakeetUpdateState = .upToDate
            parakeetLastError = nil
        } catch {
            parakeetLastError = error.localizedDescription
            errorMessage = "Failed to install Parakeet model: \(error.localizedDescription)"
        }

        parakeetService.onModelLoadProgress = nil
        parakeetService.onDownloadProgress = nil
        parakeetLoadingMessage = nil
        parakeetDownloadProgress = 0
        isInstallingParakeet = false
        refreshParakeetInstallInfo()
    }

    /// Removes the Parakeet model files and resets installation state.
    func deleteParakeetModel() {
        parakeetService.unloadModel()
        parakeetModelInstalled = false
        parakeetUpdateState = .unknown
        refreshParakeetInstallInfo()
    }

    /// Asks whether a newer Parakeet model or revision is available. One small Hugging Face request;
    /// an installed v3 is reported as outdated without one.
    func checkParakeetUpdate() async {
        guard parakeetModelInstalled, !isInstallingParakeet, parakeetUpdateState != .checking else { return }
        parakeetUpdateState = .checking
        do {
            let status = try await parakeetService.checkForUpdate()
            parakeetUpdateState = status == .upToDate ? .upToDate : .available(status)
        } catch {
            NSLog("Parakeet update check failed: %@", error.localizedDescription)
            parakeetUpdateState = .failed
        }
    }

    /// Free space on the volume holding the recordings (diagnostics).
    var recordingsFreeDiskBytes: Int64? {
        (try? store.recordingsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// What the Parakeet install looks like on disk (diagnostics).
    var parakeetInstallDiagnostics: ParakeetTranscriptionService.InstallDiagnostics {
        parakeetService.installDiagnostics
    }

    /// Loads the installed Parakeet model from disk to prove it is usable; returns why not, or nil.
    /// Also brings the in-memory install flag in line with the files.
    func verifyParakeetModel() async -> String? {
        parakeetModelInstalled = parakeetService.isModelInstalled
        refreshParakeetInstallInfo()
        do {
            _ = try await parakeetService.loadInstalledModels()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func refreshParakeetInstallInfo() {
        parakeetModelName = parakeetService.installedModelName
        parakeetInstalledAt = parakeetService.installedAt
    }

    init(fileManager: FileManager = .default) {
        let baseDirName = "MinuteMind"
        if let baseDirectory = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent(baseDirName, isDirectory: true) {
            self.store = RecordingStore(baseDirectory: baseDirectory, fileManager: fileManager)
            self.waveformStore = WaveformStore(baseDirectory: baseDirectory, fileManager: fileManager)
            self.projectStore = ProjectStore(baseDirectory: baseDirectory, fileManager: fileManager)
            self.knowledgeStore = try? KnowledgeStore(baseDirectory: baseDirectory)
            self.workspaceStore = WorkspaceStore(baseDirectory: baseDirectory)
            self.autoRecordStore = AutoRecordStore(baseDirectory: baseDirectory)
            self.eventProjectStore = EventProjectStore(baseDirectory: baseDirectory)
            self.eventLanguageStore = EventLanguageStore(baseDirectory: baseDirectory)
            self.voiceDirectory = VoiceDirectoryStore(baseDirectory: baseDirectory)
            self.eventNotesStore = EventNotesStore(baseDirectory: baseDirectory)
        } else {
            let tempBase = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                baseDirName, isDirectory: true)
            self.store = RecordingStore(baseDirectory: tempBase, fileManager: fileManager)
            self.waveformStore = WaveformStore(baseDirectory: tempBase, fileManager: fileManager)
            self.projectStore = ProjectStore(baseDirectory: tempBase, fileManager: fileManager)
            self.knowledgeStore = try? KnowledgeStore(baseDirectory: tempBase)
            self.workspaceStore = WorkspaceStore(baseDirectory: tempBase)
            self.autoRecordStore = AutoRecordStore(baseDirectory: tempBase)
            self.eventProjectStore = EventProjectStore(baseDirectory: tempBase)
            self.eventLanguageStore = EventLanguageStore(baseDirectory: tempBase)
            self.voiceDirectory = VoiceDirectoryStore(baseDirectory: tempBase)
            self.eventNotesStore = EventNotesStore(baseDirectory: tempBase)
        }
        self.automationSettings = AutomationSettings()
        // Seed the working language from the persisted default so live transcription honors
        // the Settings value from launch (normal recordings read it fresh in startRecording()).
        self.selectedLanguage = LanguageOption(rawValue: automationSettings.liveDictationLanguage) ?? .auto
        // Parakeet and Apple Speech are the only engines; any other stored value goes back to Parakeet.
        if !["parakeet", "appleSpeech"].contains(automationSettings.defaultTranscriptionModel) {
            automationSettings.defaultTranscriptionModel = "parakeet"
        }
        self.summaryPromptStore = SummaryPromptStore(baseDirectory: store.baseDirectory, fileManager: fileManager)
        self.mcpServer = MinuteMindMCPServer(baseDirectory: store.baseDirectory)
        self.vocabulary = VocabularyStore(baseDirectory: store.baseDirectory)
        self.dictationHistory = DictationHistoryStore(baseDirectory: store.baseDirectory)
        self.projectRepositories = ProjectRepositoryService(
            baseDirectory: store.baseDirectory, legacyWorkspaceStore: workspaceStore)
        self.summaryPrompts = summaryPromptStore.load()
        // The model of an old Claude Code profile carries over until a model is picked in Settings.
        if UserDefaults.standard.object(forKey: "mm.claudeModel") == nil,
           let model = summaryPromptStore.legacyClaudeModel() {
            automationSettings.claudeModel = model
        }

        // Load projects and tasks synchronously on init
        if let loadedProjects = try? projectStore.loadProjects() {
            self.projects = loadedProjects.sorted(by: Project.isOrderedBefore)
        }
        if let loadedTasks = try? projectStore.loadTasks() {
            self.tasks = loadedTasks
        }
        if let loadedEpics = try? projectStore.loadEpics() {
            self.epics = loadedEpics
        }
        self.eventNotes = eventNotesStore.load()
        if !Self.isTestProcess { parakeetService.pruneStaleInstalls() }
        self.parakeetModelInstalled = parakeetService.isModelInstalled
        self.parakeetModelName = parakeetService.installedModelName
        self.parakeetInstalledAt = parakeetService.installedAt

        // Restore the last recording project, dropping it if the project was deleted.
        if let raw = UserDefaults.standard.string(forKey: "mm.pendingProjectID"),
            let id = UUID(uuidString: raw),
            id == ProjectRepositoryService.generalProjectID || projects.contains(where: { $0.id == id }) {
            self.pendingProjectID = id
        }

        setupMeetingRadar()
        setupFileWatching()
        setupRecordingErrorHandlers()

        // TranscriptionQueue and AutomationCoordinator take `self` — must be set after all stored properties.
        transcriptionQueue.setAppViewModel(self)
        automationCoordinator = AutomationCoordinator(appViewModel: self)
        mcpServer.attach(to: self)

        Task {
            await automationCoordinator.startMonitoring()
            await loadSessions()
            runStartupMigrations()
            await removeLegacyStaticReminders()
        }
    }

    // MARK: - Calendar Integration

    /// Factory that creates a new RecordingSession pre-filled with data from a CalendarEvent.
    /// Called from CalendarView when the user taps "Record" on an event.
    /// Creates a new RecordingSession pre-filled with CalendarEvent data.
    /// Uses the same logic as the module-level createSession(from:) free function.
    func createSession(from event: CalendarEvent) -> RecordingSession {
        // Per-event language override wins, otherwise the global default.
        let defaultLanguage = LanguageOption(rawValue: automationSettings.liveDictationLanguage) ?? .auto
        let language = eventLanguageStore.languageCode(for: event.seriesKey)
            .flatMap(LanguageOption.init(rawValue:)) ?? defaultLanguage
        var session = RecordingSession(title: event.title, languageCode: language.rawValue)
        session.calendarEventID = event.id
        session.calendarEventTitle = event.title
        session.calendarAttendees = event.attendees
        session.calendarScheduledStart = event.startDate
        session.calendarScheduledEnd = event.endDate
        session.calendarNotes = event.notes
        return session
    }

    // MARK: - Meeting radar and pill

    /// Whether the radar watches for calls. Replaces the old Teams-only detection.
    var meetingDetectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "mm.meetingRadarEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mm.meetingRadarEnabled") }
    }

    func setMeetingDetection(_ enabled: Bool) {
        meetingDetectionEnabled = enabled
        enabled ? meetingRadar.start() : meetingRadar.stop()
        refreshPillIdleBar()
    }

    /// The pill's idle bar shows while dictation or meeting detection is on; its hover hint names
    /// the dictation key the user chose.
    private func refreshPillIdleBar() {
        let settings = automationSettings
        let hint: String?
        if settings.quickDictationEnabled {
            let key: String?
            switch settings.quickDictationMode {
            case "holdFn": key = "fn"
            case "holdRightOption", "hold": key = "right \u{2325}"
            default: key = nil
            }
            if let key {
                // 2x tap records, the key with Control asks Claude (each only when switched on).
                // Kept short: the hint sits next to the Record button in the opened bar.
                var parts = ["Hold \(key) to dictate"]
                if settings.quickRecordingEnabled { parts.append("2\u{00D7} record") }
                if settings.claudeTaskEnabled { parts.append("\u{2303}\(key) Claude") }
                hint = parts.joined(separator: " \u{00B7} ")
            } else {
                hint = "\u{2303}\u{2325}D to dictate"
            }
        } else {
            hint = nil
        }
        meetingPill.configureIdleBar(
            enabled: settings.quickDictationEnabled || meetingDetectionEnabled, dictationHint: hint)
    }

    private func setupMeetingRadar() {
        meetingRadar.onCallStarted = { [weak self] call in
            self?.handleCallStarted(call)
        }
        meetingRadar.onCallEnded = { [weak self] call in
            guard let self else { return }
            if self.isRecording && self.pillTracksRecording && !self.isQuickRecordingActive {
                // Only the user ends a recording (2026-10-08): the call app letting go of the mic
                // is not proof the meeting is over, so the pill just asks.
                NSLog("AppViewModel: Call app released the microphone, asking whether the meeting ended")
                self.meetingPill.askIfMeetingEnded(.callEnded(call.appName))
            } else {
                self.meetingPill.meetingEnded()
            }
        }
        meetingRadar.onScreenSharingChanged = { [weak self] sharing in
            self?.meetingPill.screenSharingChanged(sharing)
            self?.companion.screenSharingChanged(sharing)
        }

        meetingPill.levelProvider = { [weak self] in self?.currentCallLevel ?? 0 }
        meetingPill.onRecord = { [weak self] meeting in
            guard let self else { return }
            Task { await self.recordFromPill(meeting) }
        }
        meetingPill.onStop = { [weak self] in
            guard let self else { return }
            Task { await self.stopRecording() }
        }
        meetingPill.onOpenApp = {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        meetingPill.onProcess = { [weak self] sessionID in self?.processMeeting(sessionID) }
        meetingPill.onChooseProject = { [weak self] sessionID, projectID in
            guard let self, let session = self.sessions.first(where: { $0.id == sessionID }) else { return }
            self.assignSessionToProject(session, projectID: projectID)
        }
        // Shared Projects: the saved card asks whether to publish (AppViewModel+SharedPublishing.swift).
        meetingPill.isSharedProject = { [weak self] projectID in self?.isSharedProject(projectID) ?? false }
        meetingPill.sharedProjectOfSession = { [weak self] sessionID in
            guard let self, let projectID = self.sessions.first(where: { $0.id == sessionID })?.projectID,
                  self.isSharedProject(projectID) else { return nil }
            return self.projects.first { $0.id == projectID }?.name
        }
        meetingPill.onSetPublication = { [weak self] sessionID, publication in
            self?.setPublication(publication, for: sessionID)
        }
        meetingPill.onLater = { sessionID in
            NSLog("AppViewModel: Processing of \(sessionID) deferred to the inbox")
        }
        meetingPill.onOpenInbox = { [weak self] _ in
            guard let self else { return }
            self.selectedProjectID = nil
            self.isShowingAllTasks = false
            self.isShowingCalendar = false
            self.isShowingInbox = true
            self.meetingPill.onOpenApp()
        }
        meetingPill.onRecordNow = { [weak self] in
            guard let self, !self.isRecording else { return }
            Task { await self.startRecording() }
        }
        meetingPill.onShowSession = { [weak self] id in self?.revealTerminalSession(id) }
        meetingPill.onOpenClaude = { [weak self] in self?.openClaudeAssistant() }
        meetingPill.onSummonClaude = { [weak self] in self?.companion.model.actions.summon() }
        meetingPill.model.clipboardSource = clipboardHistory
        // After launch: AppViewModel is built in App.init, before NSApp and any window exist.
        if !Self.isTestProcess {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.companion.start(viewModel: self, pill: self.meetingPill)
                self.clipboardHistory.start()
            }
        }
        refreshPillIdleBar()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPillIdleBar() }
        }

        if meetingDetectionEnabled { meetingRadar.start() }
        _ = inboxSince  // pin the inbox start on first launch with this feature
        #if DEBUG
        meetingPill.runDemoIfRequested()
        openWorkspaceDemoIfRequested()
        if ProcessInfo.processInfo.environment["MM_INBOX_DEMO"] != nil { isShowingInbox = true }
        openSettingsDemoIfRequested()
        #endif
    }

    private func handleCallStarted(_ call: MeetingRadar.CallInfo) {
        guard meetingDetectionEnabled, !isRecording else { return }
        let event = currentCalendarEvent()
        // Events opted in to auto-record start on their own through the coordinator.
        if let event, autoRecordStore.isEnabled(for: event.id) { return }

        let meeting = PillMeeting(
            title: event?.title ?? call.windowTitle ?? "\(call.appName) call",
            subtitle: event.map { "\(call.appName) \u{00B7} \(Self.timeRange($0))" } ?? "\(call.appName) \u{00B7} started just now",
            appBundleID: call.bundleID,
            calendarEventID: event?.id)
        meetingPill.meetingDetected(meeting)
    }

    /// Called by the automation coordinator when a calendar meeting starts that is not opted in to
    /// auto-record.
    func promptForCalendarEvent(_ event: CalendarEvent) {
        guard meetingDetectionEnabled, !isRecording else { return }
        meetingPill.meetingDetected(PillMeeting(
            title: event.title, subtitle: "\(Self.timeRange(event)) \u{00B7} no call detected yet",
            appBundleID: nil, calendarEventID: event.id))
    }

    /// Silence for the configured threshold. The pill asks whether the meeting is over; the
    /// recording itself only ever ends when the user stops it.
    func handleSilenceDetected(silence: TimeInterval) async {
        // Presenting to a silent room is not the end of a meeting: do not even ask while sharing.
        if meetingRadar.isScreenSharing { return }
        if pillTracksRecording {
            meetingPill.askIfMeetingEnded(.silence(silence))
        }
    }

    /// True while a quick recording (double tap of the dictation key) runs. Only those stop on a
    /// press of the dictation key; a recording started with the mouse stops with the mouse.
    var isQuickRecordingActive: Bool {
        isRecording && currentSession?.isQuickRecording == true
    }

    /// Double tap of the dictation key: record without a project; the user files it on the card.
    func startQuickRecording() async {
        guard !isRecording else { return }
        // A calendar event left over from an earlier trigger must not turn this into a meeting.
        pendingCalendarEvent = nil
        await startRecording(requiresProject: false, kind: .quickRecording)
    }

    /// "fn to stop" in the pill, named after the key the user dictates with.
    private var quickRecordingStopHint: String {
        switch automationSettings.quickDictationMode {
        case "holdRightOption", "hold": return "right \u{2325} to stop"
        default: return "fn to stop"
        }
    }

    private func recordFromPill(_ meeting: PillMeeting) async {
        pendingSessionTitle = meeting.title
        if let eventID = meeting.calendarEventID {
            pendingCalendarEvent = currentCalendarEvent(matching: eventID)
        }
        await startRecording()
        guard isRecording, let session = currentSession else {
            meetingPill.meetingEnded()
            return
        }
        let threshold = automationSettings.autoStopSilenceThreshold
        if threshold > 0 {
            await automationCoordinator.startSilenceMonitoringIfNeeded(threshold: threshold, sessionID: session.id)
        }
    }

    /// The calendar meeting happening now (started up to 15 min ago or starting within 15 min).
    private func currentCalendarEvent(matching id: String? = nil) -> CalendarEvent? {
        guard calendarService.isAuthorized else { return nil }
        let now = Date()
        let events = calendarService.fetchEvents(from: now.addingTimeInterval(-3 * 3600), to: now.addingTimeInterval(15 * 60))
            .filter { !$0.isAllDay && $0.participantStatus != .declined }
        if let id { return events.first { $0.id == id } }
        return events
            .filter { $0.startDate <= now.addingTimeInterval(15 * 60) && $0.endDate >= now.addingTimeInterval(-5 * 60) }
            .min { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
    }

    private static func timeRange(_ event: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: event.startDate)) to \(formatter.string(from: event.endDate))"
    }

    // MARK: - Meeting processing (cleanup, minutes, title, todos, knowledge)

    /// "Process" from the pill or the inbox. Runs now when the transcript is ready, otherwise as
    /// soon as the transcription finishes. A meeting without a project (or General) is never
    /// processed for the first time (MeetingProcessingRule); updating an existing summary is.
    /// Without one, a failed or missing transcription is still (re)started ("Retry").
    func processMeeting(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let mayProcess = session.hasProcessingTarget || session.meetingMinutesFileName != nil || session.isQuickRecording
        if session.status == .completed, session.transcript != nil {
            guard mayProcess else { return }
            processingTasks[sessionID] = Task { await runMeetingProcessing(sessionID: sessionID) }
        } else {
            if mayProcess {
                processRequests.insert(sessionID)
                processingStage[sessionID] = .waitingForTranscript
            }
            if session.status == .recorded || session.status == .failed {
                enqueueTranscription(sessionID: sessionID, model: configuredTranscriptionModel(language: .auto))
            }
        }
    }

    /// What the pill's saved card says happens next to a recording that just stopped: ask for the
    /// project, say where it went, or (automatic processing off) offer Process Now.
    private func pillNext(for session: RecordingSession) -> MeetingPillModel.SavedNext {
        let all = projectWheelItems(tail: .none)
        guard session.hasProcessingTarget else {
            return .chooseProject(quick: recentProjectChoices(), all: all, processes: automationSettings.processOnceAssigned)
        }
        guard automationSettings.processOnceAssigned else { return .manual }
        let name = session.assignedToGeneral == true
            ? ProjectRepositoryService.generalProject.name
            : projects.first { $0.id == session.projectID }?.name ?? "the project"
        return .filed(project: name, all: all)
    }

    /// Up to three projects for one-click filing: the ones recordings went to most recently, then
    /// the sidebar's first ones.
    private func recentProjectChoices(limit: Int = 3) -> [ProjectWheel.Item] {
        var ids: [UUID] = []
        for session in sessions where !ids.contains(where: { $0 == session.projectID }) {
            guard let id = session.projectID, projects.contains(where: { $0.id == id }) else { continue }
            ids.append(id)
            if ids.count == limit { break }
        }
        for project in projects where ids.count < limit && !ids.contains(project.id) {
            ids.append(project.id)
        }
        return ids.compactMap { id in projects.first { $0.id == id } }
            .map { .init(projectID: $0.id, name: $0.name, colorHex: $0.colorHex) }
    }

    /// A project (or General) was picked for the recording: process it now when it is transcribed.
    /// Without a transcript the transcription is (re)started where needed; TranscriptionQueue
    /// processes it once it is done (MeetingProcessingRule).
    private func meetingAssigned(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              processingStage[sessionID] == nil
        else { return }
        switch MeetingProcessingRule.decide(session, trigger: .assigned, enabled: automationSettings.processOnceAssigned) {
        case .process:
            processMeeting(sessionID)
        case .waitForTranscript where session.status == .recorded || session.status == .failed:
            enqueueTranscription(sessionID: sessionID, model: configuredTranscriptionModel(language: .auto))
        default:
            break
        }
    }

    /// The speaker naming sheet saved names: an unprocessed meeting with a project goes now.
    func speakersNamed(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              MeetingProcessingRule.decide(session, trigger: .speakersNamed, enabled: automationSettings.processOnceAssigned) == .process,
              processingStage[sessionID] == nil
        else { return }
        processMeeting(sessionID)
    }

    /// Whether a recording that just finished transcribing is processed right away (it has a
    /// project, picked before or during the transcription).
    func shouldProcessAfterTranscription(_ sessionID: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
        return MeetingProcessingRule.decide(session, trigger: .transcribed, enabled: automationSettings.processOnceAssigned) == .process
    }

    /// What keeps a transcribed recording from being processed: no project yet.
    func processingHold(for session: RecordingSession) -> MeetingProcessingRule.Decision? {
        processingStage[session.id] == nil ? MeetingProcessingRule.hold(for: session) : nil
    }

    // MARK: - Inbox

    /// Where a meeting is in processing, for the inbox rows and the pill.
    enum ProcessingStage: String, Equatable {
        /// Queued in a "Process All" batch, not started yet.
        case queued = "Waiting"
        case waitingForTranscript = "Waiting for transcript"
        case cleaningUp = "Cleaning up transcript"
        case summarizing = "Summarizing"
        case extractingKnowledge = "Adding to knowledge"
    }

    private(set) var processingStage: [UUID: ProcessingStage] = [:]

    /// Only meetings recorded after the inbox existed show up, so the backlog of older sessions
    /// without minutes does not flood it on first launch.
    private var inboxSince: Date {
        #if DEBUG
        // Debug aid: MM_INBOX_DEMO=<days> shows the last N days in the inbox, for checking the UI.
        if let days = ProcessInfo.processInfo.environment["MM_INBOX_DEMO"].flatMap(Double.init) {
            return Date().addingTimeInterval(-days * 86_400)
        }
        #endif
        let key = "mm.inboxSince"
        if let date = UserDefaults.standard.object(forKey: key) as? Date { return date }
        let now = Date()
        UserDefaults.standard.set(now, forKey: key)
        return now
    }

    /// Meetings saved since the inbox exists that have no summary yet and were not skipped:
    /// waiting for or in transcription, ready, processing, or failed. Meetings processed in the
    /// last few seconds stay listed so the row can show "Processed".
    var inboxSessions: [RecordingSession] {
        let since = inboxSince
        return sessions
            .filter { session in
                guard session.createdAt >= since, session.inboxDismissed != true else { return false }
                if recentlyProcessed.contains(session.id) { return true }
                guard session.meetingMinutesFileName == nil else { return false }
                switch session.status {
                case .recording, .liveTranscribing, .idle: return false
                default: return true
                }
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Meetings the user skipped, newest first, so a mistaken skip can be undone later.
    var skippedInboxSessions: [RecordingSession] {
        let since = inboxSince
        return sessions
            .filter { $0.createdAt >= since && $0.inboxDismissed == true && $0.meetingMinutesFileName == nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Processed in the last seconds; the inbox shows "Processed · Open Summary" before removing the row.
    private(set) var recentlyProcessed: Set<UUID> = []
    /// Progress of "Process All": done and total, nil when no batch runs.
    private(set) var inboxBatch: (done: Int, total: Int)?
    /// True between "Stop" and the end of the meeting that is still running.
    private(set) var inboxBatchStopping = false
    @ObservationIgnored private var inboxBatchTask: Task<Void, Never>?
    @ObservationIgnored private var processingTasks: [UUID: Task<Void, Never>] = [:]

    func dismissFromInbox(_ sessionID: UUID) {
        setInboxDismissed(sessionID, true)
    }

    func restoreToInbox(_ sessionID: UUID) {
        setInboxDismissed(sessionID, false)
    }

    private func setInboxDismissed(_ sessionID: UUID, _ dismissed: Bool) {
        guard var session = sessions.first(where: { $0.id == sessionID }) else { return }
        session.inboxDismissed = dismissed ? true : nil
        updateSession(session, persist: true)
    }

    /// Processes every waiting inbox meeting one after another (Claude calls never run in
    /// parallel), with progress in `inboxBatch` and a Stop via `stopProcessingAll()`.
    func processAllInbox() {
        guard inboxBatchTask == nil else { return }
        // Meetings without a project wait for one; they are never processed in a batch.
        let ids = inboxSessions.filter(\.hasProcessingTarget).map(\.id)
            .filter { processingStage[$0] == nil && !recentlyProcessed.contains($0) }
        guard !ids.isEmpty else { return }
        inboxBatch = (0, ids.count)
        for id in ids { processingStage[id] = .queued }
        inboxBatchTask = Task {
            defer {
                // Anything still waiting when the batch ends (Stop) goes back to Ready.
                for id in ids where processingStage[id] == .queued { processingStage[id] = nil }
                inboxBatch = nil
                inboxBatchTask = nil
                inboxBatchStopping = false
            }
            for (index, id) in ids.enumerated() {
                guard !Task.isCancelled else { return }
                // Cancelled from its row while waiting.
                guard processingStage[id] == .queued, let session = sessions.first(where: { $0.id == id }) else { continue }
                if session.status == .completed, session.transcript != nil {
                    // Stored like a single run, so the row's Cancel stops this Claude call too.
                    let task = Task { await runMeetingProcessing(sessionID: id) }
                    processingTasks[id] = task
                    await task.value
                } else {
                    processingStage[id] = nil
                    processMeeting(id)
                }
                inboxBatch = (index + 1, ids.count)
            }
        }
    }

    /// Stops a "Process All" batch after the meeting that is running now.
    func stopProcessingAll() {
        inboxBatchStopping = true
        inboxBatchTask?.cancel()
    }

    /// Cancels processing of one meeting (a running Claude call is terminated).
    func cancelProcessing(_ sessionID: UUID) {
        processingTasks[sessionID]?.cancel()
        processRequests.remove(sessionID)
        processingStage[sessionID] = nil
    }

    /// Whether the user asked to process this session while it waited for transcription.
    func takeProcessRequest(for sessionID: UUID) -> Bool {
        processRequests.remove(sessionID) != nil
    }

    /// Claude Sonnet cleanup (when Claude Code is installed), then minutes, title and todos.
    /// Knowledge is extracted as part of minutes generation.
    func runMeetingProcessing(sessionID: UUID) async {
        guard processingStage[sessionID] != .cleaningUp, processingStage[sessionID] != .summarizing else { return }
        defer { processingStage[sessionID] = nil }
        // Meetings transcribed before the user's name was set still say "You": name them first,
        // so an updated summary uses the name too. No-op when nothing is labelled "You".
        if let name = ownSpeakerName, let session = sessions.first(where: { $0.id == sessionID }) {
            renameSpeakers([TranscriptFormatting.localSpeaker: name], for: session)
        }
        let clock = ContinuousClock()
        let started = clock.now
        let canCleanUp = ClaudeCodeService.locate() != nil
        if let early = earlyCleanups[sessionID] {
            // Started right after transcription; usually done by now.
            processingStage[sessionID] = .cleaningUp
            await early.value
        }
        if canCleanUp, !earlyCleanupDone.contains(sessionID),
           let session = sessions.first(where: { $0.id == sessionID }),
           session.transcript?.rawText == nil {
            processingStage[sessionID] = .cleaningUp
            await cleanUpTranscript(for: session)
        }
        let cleanedUp = clock.now
        guard !Task.isCancelled else { return }
        // Minutes generation extracts knowledge right after writing the summary.
        processingStage[sessionID] = .summarizing
        await transcriptionQueue.runPostTranscriptionPipeline(sessionID: sessionID, vm: self)
        processingTasks[sessionID] = nil
        NSLog("AppViewModel: processed \(sessionID) (cleanup %.0f s, summary/title/todos %.0f s)",
              (cleanedUp - started) / .seconds(1), (clock.now - cleanedUp) / .seconds(1))
        guard sessions.first(where: { $0.id == sessionID })?.meetingMinutesFileName != nil else { return }
        mirrorMeetingToWorkspace(sessionID)
        // The knowledge agent folds the summary into the workspace's knowledge/ in the background.
        curateKnowledge(for: sessionID)
        recentlyProcessed.insert(sessionID)
        Task {
            try? await Task.sleep(for: .seconds(3))
            recentlyProcessed.remove(sessionID)
        }
    }

    /// Mirrors a session into its project's repo once there is something to mirror: a quick
    /// recording as soon as it has a transcript, a meeting once it is processed. Called after
    /// transcription, on project assignment and before the workspace terminal starts.
    func mirrorToWorkspaceIfReady(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              workspaceProject(for: session) != nil else { return }
        let ready = session.isQuickRecording
            ? session.transcript?.text.isEmpty == false
            : session.meetingMinutesFileName != nil
        if ready { mirrorMeetingToWorkspace(sessionID) }
    }

    /// Writes a processed meeting into its project's repo (meetings/<date> <title>/), or a quick
    /// recording into recordings/<date>-<time>-<title>/.
    /// Processed meetings without a project go to the General workspace; quick recordings without
    /// a project are skipped.
    func mirrorMeetingToWorkspace(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let project = workspaceProject(for: session)
        else { return }
        let minutes = minutesURL(for: session).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if projectRepositories.mirror(session: session, minutes: minutes, project: project), project.isShared {
            // A Shared Project's members get the committed item with the next sync.
            sharedSync.requestSync(project.id, repo: projectRepositories.repoURL(for: project.id))
        }
    }

    /// Everything a workspace terminal needs to start in a project's repo: Claude Code, or a
    /// plain login shell for Terminal tabs.
    struct ClaudeLaunch {
        let repo: URL
        let executable: String
        let arguments: [String]
        let environment: [String]
    }

    /// What a new or restarted workspace tab runs: Claude Code with a model, or a plain terminal.
    func workspaceLaunch(for project: Project, kind: WorkspaceTerminalSession.Kind) -> ClaudeLaunch {
        switch kind {
        case .claude(let model): claudeLaunch(for: project, model: model)
        case .terminal: shellLaunch(for: project)
        }
    }

    /// The repo a workspace terminal starts in, with meetings processed (and recordings
    /// transcribed) before the repo existed brought into it.
    private func prepareWorkspaceRepository(for project: Project) -> URL {
        let repo = projectRepositories.ensureRepository(for: project)
        for session in sessions where session.projectID == project.id {
            mirrorToWorkspaceIfReady(session.id)
        }
        return repo
    }

    /// A plain Terminal tab: the user's own login shell (`-l`) in the repo, with Claude Code's
    /// directory on the PATH so typing `claude` there works too. No MCP config, no status hooks.
    func shellLaunch(for project: Project) -> ClaudeLaunch {
        let repo = prepareWorkspaceRepository(for: project)
        var env = ClaudeCodeService.locate()?.environment ?? ProcessInfo.processInfo.environment
        let shell = Self.loginShell()
        env["SHELL"] = shell
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return ClaudeLaunch(
            repo: repo,
            executable: shell,
            arguments: ["-l"],
            environment: env.map { "\($0.key)=\($0.value)" })
    }

    /// The user's login shell from the user database (the app's own SHELL can be missing when it
    /// was launched from Finder), else SHELL, else zsh.
    nonisolated static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let path = String(cString: raw)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let path = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/bin/zsh"
    }

    /// `model` is a Claude Code alias ("opus", "sonnet"); the workspace offers both per session.
    /// `initialPrompt` is sent as the session's first message (e.g. the share-project skill).
    func claudeLaunch(for project: Project, model: String = "opus", initialPrompt: String? = nil) -> ClaudeLaunch {
        let repo = prepareWorkspaceRepository(for: project)
        let config = projectRepositories.writeClaudeMCPConfig(endpoint: mcpServer.endpointURL, token: mcpServer.token)
        var env = ProcessInfo.processInfo.environment
        let claude = ClaudeCodeService.locate()
        if let claude { env = claude.environment }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"

        // Start Claude (the chosen model, MinuteMind MCP, status hooks), and drop into a login
        // shell when it exits; the exit code goes to the session's status file (non-zero = error).
        let hooks = projectRepositories.writeClaudeHookSettings()
        let command: String
        if let claude {
            let reportExit = #"rc=$?; [ -n "$MM_TERMINAL_STATUS" ] && printf '{"hook_event_name":"ClaudeExited","exit_code":%d}' "$rc" > "$MM_TERMINAL_STATUS""#
            // `--` ends the options, so --mcp-config (which takes several values) never swallows the prompt.
            let prompt = initialPrompt.map { " -- \(Self.shellQuote($0))" } ?? ""
            command = "\(Self.shellQuote(claude.executableURL.path)) --model \(Self.shellQuote(model)) --mcp-config \(Self.shellQuote(config.path)) --settings \(Self.shellQuote(hooks.path))\(prompt); \(reportExit); exec /bin/zsh -l"
        } else {
            command = "printf 'Claude Code is not installed.\\nInstall it from https://claude.com/code, run claude once to log in, then use Restart Claude.\\n\\n'; exec /bin/zsh -l"
        }
        return ClaudeLaunch(
            repo: repo,
            executable: "/bin/zsh",
            arguments: ["-l", "-c", command],
            environment: env.map { "\($0.key)=\($0.value)" })
    }

    #if DEBUG
    /// Debug aid: MM_SETTINGS_DEMO=dictionary|automation opens that settings page in a window.
    private func openSettingsDemoIfRequested() {
        guard let page = ProcessInfo.processInfo.environment["MM_SETTINGS_DEMO"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let window = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 900, height: 700),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Settings demo: \(page)"
            window.isReleasedWhenClosed = false
            let root: AnyView = page == "automation"
                ? AnyView(AutomationSettingsView().environmentObject(automationSettings).environment(self))
                : AnyView(DictionarySettingsView().environment(self))
            window.contentView = NSHostingView(rootView: root)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Debug aid: MM_WORKSPACE_DEMO=<project UUID> opens that project's workspace in a window.
    private func openWorkspaceDemoIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["MM_WORKSPACE_DEMO"],
              let project = projects.first(where: { $0.id.uuidString == raw }) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let window = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 1100, height: 700),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Workspace: \(project.name)"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:
                ProjectWorkspaceView(project: project, terminals: workspaceTerminals).environment(self))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    #endif

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func setupTeamsCallDetection() {
        teamsCallDetector.onCallDetected = { [weak self] in
            guard let self = self else { return }
            guard !self.isRecording, self.teamsCallDetectionEnabled else { return }
            Task { await self.startTeamsRecording() }
        }

        teamsCallDetector.onCallEnded = { [weak self] in
            guard let self = self else { return }
            Task { await self.handleTeamsCallEnded() }
        }

        if teamsCallDetectionEnabled {
            if !TeamsCallDetector.checkAccessibilityPermission() {
                TeamsCallDetector.requestAccessibilityPermission()
            }
            teamsCallDetector.startMonitoring()
        }
    }

    private func startTeamsRecording() async {
        let title = teamsCallDetector.currentMeetingTitle ?? "Teams Call"
        pendingSessionTitle = title
        NSLog("AppViewModel: Auto-starting Teams recording — \"%@\"", title)
        await startRecording()
        teamsSessionID = currentSession?.id
    }

    private func handleTeamsCallEnded() async {
        guard teamsSessionID != nil else { return }
        teamsSessionID = nil
        guard isRecording else { return }

        NSLog("AppViewModel: Teams call ended, asking whether the meeting ended")
        meetingPill.askIfMeetingEnded(.callEnded("Microsoft Teams"))
    }

    private func setupFileWatching() {
        // Watch transcripts directory for changes
        fileWatcher.watch(directory: store.transcriptsDirectory) { [weak self] in
            Task { @MainActor in
                await self?.loadSessions()

            }
        }

        // Watch meeting minutes directory for changes
        fileWatcher.watch(directory: store.minutesDirectory) { [weak self] in
            Task { @MainActor in
                await self?.loadSessions()

            }
        }

        // Watch the base directory for sessions.json changes
        fileWatcher.watch(directory: store.baseDirectory) { [weak self] in
            Task { @MainActor in
                await self?.loadSessions()

            }
        }
    }

    private func setupRecordingErrorHandlers() {
        micRecorder.onWriteError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                NSLog("AppViewModel: Mic write error during recording — \(error.localizedDescription)")
                self.errorMessage = "Microphone recording issue: \(error.localizedDescription)"
            }
        }
        micRecorder.onDeviceRecovery = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                NSLog("AppViewModel: \(message)")
                // Brief info toast — not an error, just awareness.
                self.errorMessage = message
            }
        }
        micRecorder.onFileStall = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                NSLog("AppViewModel: Mic recording file stall detected")
                self.errorMessage = "Recording may have stalled — microphone audio file stopped growing."
            }
        }
        systemRecorder.onStreamError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                NSLog("AppViewModel: System audio error during recording — \(error.localizedDescription)")
                self.errorMessage = "System audio issue: \(error.localizedDescription). Mic recording continues."
            }
        }
    }

    func toggleTeamsCallDetection(_ enabled: Bool) {
        teamsCallDetectionEnabled = enabled
        if enabled {
            // Check and request accessibility permissions
            if !TeamsCallDetector.checkAccessibilityPermission() {
                TeamsCallDetector.requestAccessibilityPermission()
            }
            teamsCallDetector.startMonitoring()
        } else {
            teamsCallDetector.stopMonitoring()
        }
    }

    /// Handle notification action responses (from system notification buttons).
    /// `userInfo` carries extra string payload.
    /// `category` is passed so default taps on category-specific notifications can be handled.
    func handleNotificationAction(_ actionIdentifier: String,
                                  userInfo: [String: String] = [:],
                                  category: String = "") {
        switch actionIdentifier {
        case "REVIEW_BRIEF",
             UNNotificationDefaultActionIdentifier where category == "mm.todoBrief":
            openTodoBriefSheet()
        case UNNotificationDefaultActionIdentifier where category == Self.jobRunNotificationCategory:
            openJobRun(fromNotification: userInfo)
        default:
            break
        }
    }

    /// Brings the main window to front and presents the todo brief sheet.
    /// Safe to call even if `pendingTodoBrief` is nil (sheet guard handles it).
    func openTodoBriefSheet() {
        // Ensure the app and main window are visible before SwiftUI tries to present the sheet.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)

        // Brief async hop lets the window finish activating before the sheet is triggered.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            self.showTodoBriefSheet = true
        }
    }

    /// Reloads sessions from disk. Called on launch and by the file watchers when the data
    /// directory changes (multi-window sync). Kept cheap and idempotent: it only re-publishes
    /// `sessions` when the on-disk content actually differs, so a watcher fire reflecting our
    /// own save doesn't trigger a redundant full-tree re-render under @Observable.
    /// One-time data migrations live in `runStartupMigrations()`, NOT here — running them on
    /// every reload spawned conversion work and re-render churn on each watcher event.
    func loadSessions() async {
        do {
            try store.ensureDirectories()
            let storedSessions = try store.loadSessions()
                .sorted { $0.createdAt > $1.createdAt }
            if storedSessions != sessions {
                self.sessions = storedSessions
                currentSession = sessions.first(where: { $0.isActive })
                isRecording = currentSession?.status == .recording
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// One-time data migrations + housekeeping, run once per launch after the initial
    /// `loadSessions()`. Each step is self-guarding (a cheap no-op when there's nothing to
    /// do), so existing data is migrated forward on first launch and skipped thereafter.
    /// New recordings are converted to M4A directly by the post-recording pipeline
    /// (see `stopRecording()`), so these migrations only touch legacy/historical data.
    private func runStartupMigrations() {
        rollForwardOverdueTasks()
        migrateWaveformsToSidecar()
        migrateOldRecordingsToM4A()
        startAudioRetentionLoop()
        CrashReporter.shared.sendPending(after: .seconds(15))
        setupWorkspaceKnowledge()
        setupScheduledJobs()
        setupSharedSync()
        if !Self.isTestProcess { LaunchAtLogin.shared.enableOnFirstLaunch() }
    }

    /// Why the next recording cannot start, or nil when it can. Recording without a
    /// project is allowed (the session is stored as before, just without file export).
    /// Blocked only when the resolved project (event mapping for calendar triggers,
    /// `pendingProjectID` otherwise) has neither an export folder nor the explicit
    /// opt-out. Shared by the startRecording() guard and the record-button UI.
    func recordingStartBlockReason() -> String? {
        guard let project = recordingStartBlockingProject() else { return nil }
        return "Project '\(project.name)' has no export folder. Set one in the project settings (or explicitly disable export)."
    }

    /// The project that blocks the next manual recording (no export folder, no explicit opt-out), if any.
    func recordingStartBlockingProject() -> Project? {
        let project: Project?
        if let event = pendingCalendarEvent {
            let mappedID = projectID(for: event)
            project = projects.first { $0.id == mappedID }
        } else {
            project = projects.first { $0.id == pendingProjectID }
        }
        guard let project, !project.isExportConfigured else { return nil }
        return project
    }

    /// The record-time picker's choice: a project, or General (`generalProjectID`), which files
    /// the meeting to the General workspace without a project.
    private func applyPendingProject(to session: inout RecordingSession) {
        if pendingProjectID == ProjectRepositoryService.generalProjectID {
            session.assignedToGeneral = true
        } else {
            session.projectID = pendingProjectID
        }
    }

    /// Starts a new recording. Manual recordings are assigned to `pendingProjectID`,
    /// calendar-triggered ones to the event's project mapping. No project selected →
    /// the session is recorded and stored as before, just without file export. A
    /// resolved project must have its export folder configured (or export explicitly
    /// disabled), otherwise recording is refused. Live dictation passes
    /// `requiresProject: false` — those sessions skip project assignment and export.
    /// `kind: .quickRecording` (double tap of the dictation key) also starts without a project
    /// (the user assigns it on the card), but shows in the pill and gets no silence auto-stop:
    /// it ends only when the user stops it.
    func startRecording(requiresProject: Bool = true, kind: RecordingSession.Kind = .meeting) async {
        NSLog("AppViewModel: startRecording called, isRecording=\(isRecording)")
        if isRecording {
            NSLog("AppViewModel: Already recording, returning early")
            return
        }

        if requiresProject, let reason = recordingStartBlockReason() {
            NSLog("AppViewModel: Recording blocked — \(reason)")
            errorMessage = reason
            pendingCalendarEvent = nil
            return
        }

        do {
            // Pre-flight: check available disk space (500 MB minimum for a typical 1-hour recording).
            let freeBytes = try? store.recordingsDirectory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
            if let freeBytes, freeBytes < 500_000_000 {
                let freeMB = freeBytes / 1_000_000
                NSLog("AppViewModel: Low disk space warning — \(freeMB) MB available")
                errorMessage = "Low disk space (\(freeMB) MB). Recording may fail if disk fills up."
                // Continue anyway — the user may still want to record.
            }

            let isQuick = kind == .quickRecording
            // A quick recording never takes the title typed for the next meeting.
            let title = isQuick ? "Recording" : resolvedSessionTitle()
            // Resolve the transcription language: a per-event override set in the calendar wins,
            // otherwise fall back to the global default. Both are read fresh so changes take
            // effect immediately without an app restart.
            let defaultLanguage = LanguageOption(rawValue: automationSettings.liveDictationLanguage) ?? .auto
            let resolvedLanguage: LanguageOption = {
                if let event = pendingCalendarEvent,
                   let override = eventLanguageStore.languageCode(for: event.seriesKey),
                   let overrideOption = LanguageOption(rawValue: override) {
                    return overrideOption
                }
                return defaultLanguage
            }()
            selectedLanguage = resolvedLanguage
            var session = RecordingSession(
                title: title,
                languageCode: resolvedLanguage.rawValue,
                status: .recording
            )
            if isQuick { session.kind = .quickRecording }
            let slug = fileSafeSlug(for: title, id: session.id)
            session.micFileName = "\(slug)-microphone.caf"
            session.systemFileName = "\(slug)-speaker.caf"

            try store.ensureDirectories()

            guard let micFileName = session.micFileName,
                let systemFileName = session.systemFileName
            else {
                throw NSError(
                    domain: "AppViewModel", code: -10,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create recording filenames"])
            }

            let micURL = store.recordingsDirectory.appendingPathComponent(micFileName)
            let systemURL = store.recordingsDirectory.appendingPathComponent(systemFileName)

            try micRecorder.startRecording(
                to: micURL, deviceID: MicrophonePreference.resolvedDeviceID())
            try await systemRecorder.startRecording(to: systemURL)

            // Populate calendar metadata and project from a pending event trigger.
            if let event = pendingCalendarEvent {
                session.calendarEventID = event.id
                session.calendarEventTitle = event.title
                session.calendarAttendees = event.attendees
                session.calendarScheduledStart = event.startDate
                session.calendarScheduledEnd = event.endDate
                session.calendarNotes = event.notes
                session.projectID = projectID(for: event)
                pendingCalendarEvent = nil
            } else if requiresProject {
                applyPendingProject(to: &session)
            }

            sessions.insert(session, at: 0)
            currentSession = session
            isRecording = true
            if !isQuick { pendingSessionTitle = "" }
            try store.saveSessions(sessions)

            if requiresProject || isQuick {
                pillTracksRecording = true
                meetingPill.recordingStarted(at: session.createdAt, stopHint: isQuick ? quickRecordingStopHint : nil)
            }

            // Start silence monitoring for manual recordings (no pending calendar event).
            // Quick recordings are stopped by the user only.
            if session.calendarEventID == nil, !isQuick,
               automationSettings.manualRecordingSilenceEnabled {
                let threshold = automationSettings.autoStopSilenceThreshold
                await automationCoordinator.startSilenceMonitoringIfNeeded(
                    threshold: threshold, sessionID: session.id)
            }

            // Start the max-duration safety timer (3 hours).
            startMaxRecordingTimer()
        } catch {
            await cleanupRecording()
            errorMessage = error.localizedDescription
        }
    }

    /// Starts a timer that auto-stops recording after `maxRecordingDuration` (3 hours).
    /// Warns the user 10 minutes before the limit.
    private func startMaxRecordingTimer() {
        maxRecordingTimer?.cancel()
        let warningTime = Self.maxRecordingDuration - 10 * 60  // warn 10 min before
        maxRecordingTimer = Task { [weak self] in
            // Warning at 2h50m
            try? await Task.sleep(nanoseconds: UInt64(warningTime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.errorMessage = "Recording will auto-stop in 10 minutes (3-hour limit)."
            }
            // Final 10 minutes
            try? await Task.sleep(nanoseconds: UInt64(10 * 60 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NSLog("AppViewModel: Max recording duration reached (3 hours) — auto-stopping")
            await self?.stopRecording()
        }
    }

    private func cleanupRecording() async {
        maxRecordingTimer?.cancel()
        maxRecordingTimer = nil
        micRecorder.stopRecording()
        await systemRecorder.stopRecording()
    }

    func stopRecording() async {
        NSLog(
            "AppViewModel: stopRecording called, isRecording=\(isRecording), currentSession=\(currentSession?.id.uuidString ?? "nil")"
        )
        guard isRecording, let recording = currentSession else {
            NSLog("AppViewModel: stopRecording guard failed, returning early")
            return
        }
        // Start from the stored session, not the copy taken at start: a project picked during the
        // recording (companion wheel, card, Inbox) lives only there.
        var session = sessions.first { $0.id == recording.id } ?? recording

        maxRecordingTimer?.cancel()
        maxRecordingTimer = nil

        micRecorder.stopRecording()
        await systemRecorder.stopRecording()

        session.status = .recorded
        session.duration = Date().timeIntervalSince(session.createdAt)

        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        }
        try? store.saveSessions(sessions)
        currentSession = nil
        isRecording = false
        NSLog("AppViewModel: Recording stopped, session saved with status=.recorded")

        // Under 2 s a quick recording is an accidental double tap: drop it instead of filing it.
        if session.isQuickRecording, (session.duration ?? 0) < 2 {
            NSLog("AppViewModel: Quick recording under 2 s discarded")
            pillTracksRecording = false
            meetingPill.recordingDiscarded()
            deleteSession(session)
            return
        }

        if pillTracksRecording {
            pillTracksRecording = false
            meetingPill.recordingStopped(
                sessionID: session.id, title: session.title, duration: session.duration ?? 0,
                next: pillNext(for: session))
        }
        
        let sessionID = session.id
        // Post-recording: convert .caf → .m4a, generate waveform, run auto-pipeline.
        postRecordingTask?.cancel()
        isGeneratingWaveform = true
        postRecordingTask = Task {
            // Convert PCM .caf recordings to compressed .m4a (AAC) to save disk space.
            await convertRecordingsToM4A(sessionID: sessionID)

            if Task.isCancelled { isGeneratingWaveform = false; return }

            // Re-fetch session after conversion updated the filenames.
            guard let updated = sessions.first(where: { $0.id == sessionID }) else {
                isGeneratingWaveform = false; return
            }
            let channel: RecordingSession.Channel = updated.micFileName != nil ? .microphone : .system
            _ = await generateWaveform(for: updated, channel: channel)
            if Task.isCancelled {
                NSLog("AppViewModel: Waveform generation cancelled for session \(sessionID)")
                isGeneratingWaveform = false
                return
            }
            NSLog("AppViewModel: Waveform auto-generated for session \(sessionID)")
            isGeneratingWaveform = false
            await automationCoordinator.runPipelineIfEnabled(for: sessionID)
        }
    }

    func startLiveTranscription() async throws -> (
        SendableRecognitionRequest, SendableRecognitionRequest
    )? {
        let lang = selectedLanguage.isAutoDetect ? "en-US" : selectedLanguage.rawValue

        print("[DEBUG] AppViewModel: Starting live transcription with language: \(lang)")
        NSLog("AppViewModel: Starting live transcription with language: \(lang)")

        // Clear previous transcript state
        liveTranscriptText = ""
        liveTranscriptPreview = ""
        liveTranscriptPartial = ""

        let requests = try await liveTranscriptionService.start(localeIdentifier: lang) {
            [weak self] update in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.handleLiveTranscriptUpdate(update)
            }
        }
        isLiveTranscribing = true
        print(
            "[DEBUG] AppViewModel: Live transcription started successfully, isLiveTranscribing=\(isLiveTranscribing)"
        )
        NSLog(
            "AppViewModel: Live transcription started successfully, isLiveTranscribing=\(isLiveTranscribing)"
        )
        return requests
    }

    func stopLiveTranscription() async {
        NSLog(
            "AppViewModel: stopLiveTranscription called, isLiveTranscribing=\(isLiveTranscribing)")
        _ = await liveTranscriptionService.stop()
        isLiveTranscribing = false
        NSLog("AppViewModel: Live transcription stopped")
    }

    private func handleLiveTranscriptUpdate(_ update: LiveTranscriptionService.TranscriptUpdate) {
        let timestamp = String(
            format: "[%02d:%02d]", Int(update.timestamp) / 60, Int(update.timestamp) % 60)
        let text = VocabularyCorrection.apply(update.text, entries: vocabulary.entries).text
        let formattedEntry = "\(timestamp) \(update.speaker): \(text)"

        if update.isFinal {
            if !liveTranscriptText.isEmpty {
                liveTranscriptText += "\n\n"
            }
            liveTranscriptText += formattedEntry
            liveTranscriptPartial = ""
        } else {
            liveTranscriptPartial = formattedEntry
        }

        // Update preview
        let allText =
            liveTranscriptText
            + (liveTranscriptPartial.isEmpty ? "" : "\n\n" + liveTranscriptPartial)
        liveTranscriptPreview = String(allText.suffix(200))
    }

    /// Picks the microphone for recordings (nil = system default), from Settings or the recording
    /// card. A running recording switches right away; System Default resolves to the current default.
    func selectMicrophone(_ deviceID: AudioDeviceID?) {
        audioDeviceManager.selectedInputDeviceID = deviceID
        guard isRecording, let target = deviceID ?? audioDeviceManager.getDefaultInputDevice() else { return }
        switchMicrophoneDevice(to: target)
    }

    func switchMicrophoneDevice(to deviceID: AudioDeviceID) {
        guard isRecording else { return }
        do {
            try micRecorder.switchInputDevice(deviceID)
            NSLog("AppViewModel: Switched microphone to device \(deviceID)")
        } catch {
            errorMessage = "Failed to switch microphone: \(error.localizedDescription)"
        }
    }

    func renameSession(_ session: RecordingSession, newTitle: String) {
        guard var existing = sessions.first(where: { $0.id == session.id }) else {
            return
        }
        existing.title =
            newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultSessionTitle() : newTitle
        existing.updatedAt = Date()
        updateSession(existing, persist: true)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            syncExportFolderName(forSessionAt: index, newTitle: existing.title)
        }
    }

    // MARK: - Audio Import

    /// Imports existing audio files (Voice Memos, exported call recordings, …) as new sessions.
    /// The file is copied into the recordings folder and stored as the microphone channel, so the
    /// resulting card behaves exactly like a recorded one. Transcription is NOT started
    /// automatically — the card appears with status `.recorded` and the user hits transcribe.
    /// Each file becomes its own session; failures are reported per file and don't abort the rest.
    func importAudioFiles(_ urls: [URL]) async {
        let audioURLs = urls.filter(AudioImportService.hasAudioExtension)
        guard !audioURLs.isEmpty else {
            if !urls.isEmpty {
                errorMessage = "No audio files in the selection — supported types are m4a, mp3, wav, aiff and caf."
            }
            return
        }

        isImportingAudio = true
        defer { isImportingAudio = false }

        var failures: [String] = []
        var importedIDs: [UUID] = []

        for url in audioURLs {
            // A file picked outside the app's own folders may need scoped access.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                try store.ensureDirectories()
                let sessionID = UUID()
                let slug = fileSafeSlug(for: AudioImportService.suggestedTitle(for: url), id: sessionID)
                let imported = try await AudioImportService.copy(
                    url, into: store.recordingsDirectory, fileNameBase: slug)

                let language = LanguageOption(rawValue: automationSettings.liveDictationLanguage) ?? .auto
                var session = RecordingSession(
                    id: sessionID,
                    title: imported.title,
                    languageCode: language.rawValue,
                    status: .recorded,
                    micFileName: imported.fileName,
                    duration: imported.duration > 0 ? imported.duration : nil
                )
                applyPendingProject(to: &session)

                sessions.insert(session, at: 0)
                sessions.sort { $0.createdAt > $1.createdAt }
                try store.saveSessions(sessions)
                importedIDs.append(session.id)
                NSLog("AppViewModel: Imported audio %@ as session %@", imported.fileName, session.id.uuidString)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }

        // Waveforms are generated afterwards so the cards show up immediately.
        for id in importedIDs {
            guard let session = sessions.first(where: { $0.id == id }) else { continue }
            _ = await generateWaveform(for: session, channel: .microphone)
        }
    }

    /// Opens the macOS file picker and imports whatever the user chooses.
    func importAudioFromPicker() async {
        let urls = AudioImportService.pickFiles()
        guard !urls.isEmpty else { return }
        await importAudioFiles(urls)
    }

    func deleteAudio(for session: RecordingSession, channel: RecordingSession.Channel) {
        guard var existing = sessions.first(where: { $0.id == session.id }) else { return }
        guard let fileName = existing.fileName(for: channel) else { return }
        let fileURL = store.recordingsDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        switch channel {
        case .microphone:
            existing.micFileName = nil
        case .system:
            existing.systemFileName = nil
        }
        existing.updatedAt = Date()
        updateSession(existing, persist: true)
    }

    func deleteTranscript(for session: RecordingSession) {
        guard var existing = sessions.first(where: { $0.id == session.id }) else { return }
        if let fileName = existing.transcript?.fileName {
            let url = store.transcriptsDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
        }
        existing.transcript = nil
        existing.updatedAt = Date()
        updateSession(existing, persist: true)
    }

    func deleteAllArtifacts(for session: RecordingSession) {
        deleteAudio(for: session, channel: .microphone)
        deleteAudio(for: session, channel: .system)
        deleteTranscript(for: session)
        deleteMinutes(for: session)
        waveformStore.delete(sessionID: session.id)
    }

    func deleteSession(_ session: RecordingSession) {
        // Delete all associated files first
        deleteAllArtifacts(for: session)
        // Remove from sessions list
        sessions.removeAll { $0.id == session.id }
        if currentSession?.id == session.id {
            currentSession = nil
        }
        try? store.saveSessions(sessions)
    }

    private func updateSession(_ session: RecordingSession, persist: Bool) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.createdAt > $1.createdAt }
        if currentSession?.id == session.id {
            currentSession = session
        }
        if persist {
            try? store.saveSessions(sessions)
        }
    }
    
    /// Cancel any in-progress waveform generation (e.g. for very long recordings).
    func cancelWaveformGeneration() {
        postRecordingTask?.cancel()
        postRecordingTask = nil
        isGeneratingWaveform = false
        NSLog("AppViewModel: Waveform generation cancelled by user")
    }

    // MARK: - Audio Waveform & Cropping
    
    func generateWaveform(for session: RecordingSession, channel: RecordingSession.Channel) async -> AudioProcessor.WaveformData? {
        // Always look up the latest session from the array to get fresh in-memory state.
        guard let currentSession = sessions.first(where: { $0.id == session.id }) else {
            return nil
        }

        // Cache tiers (cheapest first):
        //   1. In-memory copy on the session (populated by a previous call this launch).
        //   2. Sidecar file on disk (populated by a previous launch).
        //   3. Regenerate from the audio file, then write to sidecar + in-memory.
        //
        // The sessions.json file itself never contains waveform data — see
        // RecordingSession.encode(to:) and WaveformStore for the rationale.

        if let cachedSamples = currentSession.waveformSamples,
           let cachedDuration = currentSession.waveformDuration,
           let cachedChannel = currentSession.waveformChannel,
           cachedChannel == channel.rawValue {
            let speechSegments = (currentSession.waveformSpeechSegments ?? []).map {
                AudioProcessor.SpeechSegment(startTime: $0.startTime, endTime: $0.endTime)
            }
            return AudioProcessor.WaveformData(
                samples: cachedSamples,
                duration: cachedDuration,
                sampleRate: Int(Double(cachedSamples.count) / cachedDuration),
                speechSegments: speechSegments
            )
        }

        if let sidecar = waveformStore.load(sessionID: currentSession.id),
           sidecar.channel == channel.rawValue {
            // Promote sidecar into in-memory cache so the next call hits tier 1.
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index].waveformSamples = sidecar.samples
                sessions[index].waveformDuration = sidecar.duration
                sessions[index].waveformSpeechSegments = sidecar.speechSegments.map {
                    RecordingSession.CachedSpeechSegment(startTime: $0.start, endTime: $0.end)
                }
                sessions[index].waveformChannel = sidecar.channel
            }
            let speechSegments = sidecar.speechSegments.map {
                AudioProcessor.SpeechSegment(startTime: $0.start, endTime: $0.end)
            }
            return AudioProcessor.WaveformData(
                samples: sidecar.samples,
                duration: sidecar.duration,
                sampleRate: Int(Double(sidecar.samples.count) / sidecar.duration),
                speechSegments: speechSegments
            )
        }

        NSLog("AppViewModel: Generating new waveform for session \(currentSession.title)")
        guard let url = currentSession.fileURL(for: channel, baseURL: store.recordingsDirectory),
              FileManager.default.fileExists(atPath: url.path) else {
            NSLog("AppViewModel: No audio file found for waveform generation")
            return nil
        }

        do {
            let waveformData = try await audioProcessor.generateWaveform(from: url)

            // Persist to sidecar (compact binary) and update the in-memory cache. Sidecar
            // write is a single small file — no impact on sessions.json.
            let sidecar = WaveformSidecar(
                samples: waveformData.samples,
                duration: waveformData.duration,
                speechSegments: waveformData.speechSegments.map { ($0.startTime, $0.endTime) },
                channel: channel.rawValue
            )
            try? waveformStore.save(sessionID: session.id, sidecar)

            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index].waveformSamples = waveformData.samples
                sessions[index].waveformDuration = waveformData.duration
                sessions[index].waveformSpeechSegments = waveformData.speechSegments.map {
                    RecordingSession.CachedSpeechSegment(startTime: $0.startTime, endTime: $0.endTime)
                }
                sessions[index].waveformChannel = channel.rawValue
            }

            return waveformData
        } catch {
            NSLog("AppViewModel: Failed to generate waveform: \(error)")
            return nil
        }
    }
    
    func cropAudio(sessionID: UUID, startTime: TimeInterval, endTime: TimeInterval) async {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[index]
        
        NSLog("AppViewModel: Starting crop for session \(session.title)")
        
        do {
            // Backup originals if not already backed up (only on first crop)
            if session.originalMicFileName == nil {
                session.originalMicFileName = session.micFileName
                session.originalSystemFileName = session.systemFileName
            }
            
            // Use the CURRENT filenames as source (might already be cropped)
            // This allows iterative cropping of the same audio
            let sourceMicFileName = session.micFileName
            let sourceSystemFileName = session.systemFileName
            
            // Create cropped file names based on the original file name
            let originalMicName = session.originalMicFileName ?? session.micFileName
            let originalSystemName = session.originalSystemFileName ?? session.systemFileName
            let croppedMicFileName = originalMicName.map { "cropped-\($0)" }
            let croppedSystemFileName = originalSystemName.map { "cropped-\($0)" }
            
            // Crop microphone audio if exists (from current, not original)
            if let sourceName = sourceMicFileName {
                let sourceURL = store.recordingsDirectory.appendingPathComponent(sourceName)
                if let croppedName = croppedMicFileName {
                    let finalURL = store.recordingsDirectory.appendingPathComponent(croppedName)
                    
                    // Use a temporary file to avoid conflicts when source and dest are the same
                    let tempName = "temp-\(UUID().uuidString).m4a"
                    let tempURL = store.recordingsDirectory.appendingPathComponent(tempName)
                    
                    NSLog("AppViewModel: Cropping mic from \(sourceName) to temp file, then to \(croppedName)")
                    
                    // Export to temp file
                    try await audioProcessor.cropAudio(from: sourceURL, to: tempURL, startTime: startTime, endTime: endTime)
                    
                    // Delete old cropped file if it exists
                    try? FileManager.default.removeItem(at: finalURL)
                    
                    // Move temp file to final location
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)
                    
                    session.micFileName = croppedName
                }
            }
            
            // Crop system audio if exists (from current, not original)
            if let sourceName = sourceSystemFileName {
                let sourceURL = store.recordingsDirectory.appendingPathComponent(sourceName)
                if let croppedName = croppedSystemFileName {
                    let finalURL = store.recordingsDirectory.appendingPathComponent(croppedName)
                    
                    // Use a temporary file to avoid conflicts when source and dest are the same
                    let tempName = "temp-\(UUID().uuidString).m4a"
                    let tempURL = store.recordingsDirectory.appendingPathComponent(tempName)
                    
                    NSLog("AppViewModel: Cropping system from \(sourceName) to temp file, then to \(croppedName)")
                    
                    // Export to temp file
                    try await audioProcessor.cropAudio(from: sourceURL, to: tempURL, startTime: startTime, endTime: endTime)
                    
                    // Delete old cropped file if it exists
                    try? FileManager.default.removeItem(at: finalURL)
                    
                    // Move temp file to final location
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)
                    
                    session.systemFileName = croppedName
                }
            }
            
            // Update session with crop info
            session.cropStartTime = startTime
            session.cropEndTime = endTime
            session.duration = endTime - startTime
            
            // Clear transcript since audio has changed
            session.transcript = nil
            session.status = .recorded
            
            // Clear waveform cache since audio has changed
            session.waveformSamples = nil
            session.waveformDuration = nil
            session.waveformSpeechSegments = nil
            session.waveformChannel = nil
            waveformStore.delete(sessionID: session.id)

            updateSession(session, persist: true)
            NSLog("AppViewModel: Crop completed successfully for session \(session.title)")
            
        } catch {
            NSLog("AppViewModel: Crop failed: \(error.localizedDescription)")
            errorMessage = "Failed to crop audio: \(error.localizedDescription)"
        }
    }
    
    func restoreOriginalAudio(sessionID: UUID) async {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[index]
        
        NSLog("AppViewModel: Starting restore for session \(session.title)")
        
        guard let originalMicFileName = session.originalMicFileName else {
            errorMessage = "No original audio to restore"
            return
        }
        
        // Delete cropped files
        if let croppedMicName = session.micFileName {
            let croppedURL = store.recordingsDirectory.appendingPathComponent(croppedMicName)
            try? FileManager.default.removeItem(at: croppedURL)
        }
        if let croppedSystemName = session.systemFileName {
            let croppedURL = store.recordingsDirectory.appendingPathComponent(croppedSystemName)
            try? FileManager.default.removeItem(at: croppedURL)
        }
        
        // Restore original file names
        session.micFileName = originalMicFileName
        session.systemFileName = session.originalSystemFileName
        session.originalMicFileName = nil
        session.originalSystemFileName = nil
        session.cropStartTime = nil
        session.cropEndTime = nil
        
        // Recalculate duration from original files
        if let micFileName = session.micFileName {
            let url = store.recordingsDirectory.appendingPathComponent(micFileName)
            let asset = AVAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                session.duration = duration.seconds
            }
        }
        
        // Clear transcript since we're back to original
        session.transcript = nil
        session.status = .recorded
        
        // Clear waveform cache since audio has changed
        session.waveformSamples = nil
        session.waveformDuration = nil
        session.waveformSpeechSegments = nil
        session.waveformChannel = nil
        waveformStore.delete(sessionID: session.id)

        updateSession(session, persist: true)
        NSLog("AppViewModel: Restore completed successfully for session \(session.title)")
    }
    
    /// Reset a session stuck in transcribing state back to recorded
    func resetTranscribingSession(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[index]
        
        // Only reset if stuck in transcribing state
        guard session.status == .transcribing else { return }
        
        NSLog("AppViewModel: Resetting stuck transcribing session: \(session.title)")
        session.status = .recorded
        session.lastErrorMessage = "Transcription was interrupted"
        updateSession(session, persist: true)
        
        // Clean up any lingering transcription state
        if transcribingSessionID == sessionID {
            transcribingSessionID = nil
            isTranscribing = false
            transcriptionProgress = nil
            transcriptionProgressMessage = ""
        }
    }

    // MARK: - Transcription Queue

    /// Single entry point for all transcription requests from views.
    /// Enqueues the job and returns immediately; the queue processes serially.
    func enqueueTranscription(sessionID: UUID, model: TranscriptionQueue.TranscriptionModel) {
        let title = sessions.first(where: { $0.id == sessionID })?.title ?? "Unknown"
        transcriptionQueue.enqueue(sessionID: sessionID, title: title, model: model)
    }

    // MARK: - Calendar presentation

    /// The project a calendar event is routed to, via its series mapping. Nil when unassigned.
    func project(for event: CalendarEvent) -> Project? {
        guard let id = projectID(for: event) else { return nil }
        return projects.first { $0.id == id }
    }

    /// Today's meetings worth deciding about: no all-day blockers, nothing already declined,
    /// and nothing that has already finished. This is what the morning briefing asks about.
    func todaysDecidableEvents(now: Date = Date()) -> [CalendarEvent] {
        let calendar = Calendar.current
        guard calendarService.isAuthorized,
            let day = calendar.dateInterval(of: .day, for: now)
        else { return [] }

        let events: [CalendarEvent] = calendarService.fetchEvents(from: day.start, to: day.end)
        let today = events.filter { (event: CalendarEvent) -> Bool in
            calendar.isDate(event.startDate, inSameDayAs: now)
                && !event.isAllDay
                && event.participantStatus != .declined
                && event.endDate > now
        }
        return today.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Configured transcription engine

    /// The transcription engine to use, as configured in Settings → Automation.
    ///
    /// This is the single place that turns the stored setting into a concrete job, so the
    /// "Transcribe" button, the automation coordinator and the auto-pipeline can never disagree
    /// about which engine "default" means. An engine whose model is not installed (or whose API key
    /// is missing) falls back to Apple Speech rather than failing — a recording that transcribes
    /// with the wrong engine is recoverable, one that silently does nothing is not.
    func configuredTranscriptionModel(language: LanguageOption? = nil)
        -> TranscriptionQueue.TranscriptionModel
    {
        let code = (language ?? selectedLanguage).isAutoDetect ? nil : (language ?? selectedLanguage).rawValue

        switch automationSettings.defaultTranscriptionModel {
        case "parakeet" where parakeetModelInstalled:
            return .parakeet(language: code)
        case "appleSpeech":
            return .appleSpeech(language: code)
        default:
            return .appleSpeech(language: code)
        }
    }

    /// Human-readable name of the engine `configuredTranscriptionModel()` will actually use.
    var configuredTranscriptionEngineName: String {
        switch configuredTranscriptionModel() {
        case .parakeet: return "Parakeet"
        case .appleSpeech: return "Apple Speech"
        }
    }

    /// Set when the configured engine is unavailable and a fallback is in play, so the UI can say so
    /// instead of quietly transcribing with something the user did not pick.
    var transcriptionEngineFallbackNote: String? {
        switch automationSettings.defaultTranscriptionModel {
        case "parakeet" where !parakeetModelInstalled:
            return "Parakeet is not installed — using Apple Speech. Install it in Settings → Automation."
        default:
            return nil
        }
    }

    /// Transcribes a session with the configured engine; processing follows when
    /// MeetingProcessingRule allows it. The one entry point behind the Transcribe/Retranscribe button.
    func transcribeWithConfiguredEngine(sessionID: UUID, language: LanguageOption? = nil) {
        enqueueTranscription(sessionID: sessionID, model: configuredTranscriptionModel(language: language))
    }

    /// Mark a session as queued (pending transcription) so the UI reflects it.
    func markSessionQueued(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        // Only mark as queued if the session is in a state that makes sense.
        let session = sessions[index]
        guard session.status == .recorded || session.status == .completed || session.status == .failed else { return }
        // We don't change session.status here — the actual transcription methods will set .transcribing.
        // The queue's job status (.pending) is what the UI should check.
    }

    /// Builds biasing context (participant names, meeting title, project) for a session so the
    /// transcription engine recognizes proper nouns and meeting-specific jargon.
    private func transcriptionContext(for session: RecordingSession) -> TranscriptionContext {
        let projectName = session.projectID.flatMap { id in
            projects.first(where: { $0.id == id })?.name
        }
        return TranscriptionContext.build(
            meetingTitle: session.title,
            calendarEventTitle: session.calendarEventTitle,
            attendees: session.calendarAttendees,
            projectName: projectName,
            extraTerms: vocabulary.terms
        )
    }

    /// True while an AI cleanup is running for a session.
    func isCleaningUpTranscript(_ session: RecordingSession) -> Bool {
        transcriptCleanupInProgress.contains(session.id)
    }

    /// True when a cleanup has run and the untouched engine output is still available.
    func canRevertTranscriptCleanup(_ session: RecordingSession) -> Bool {
        session.transcript?.rawText != nil
    }

    /// Polishes a session's transcript with an LLM (punctuation, filler words, obvious slips).
    /// Prefers Claude Sonnet via Claude Code when installed, then Apple's on-device model, then
    /// the active AI profile. The untouched engine
    /// output is preserved in `transcript.rawText` so the change can be reverted.
    /// Starts the transcript cleanup in the background as soon as a meeting is transcribed, so
    /// Process later only has the summary, title and todos left. Meetings only (quick
    /// recordings are cleaned up when processed), and only with a model to clean up with.
    /// Cleanups run one at a time; speaker names given meanwhile are kept (see cleanUpTranscript).
    func startEarlyCleanup(_ sessionID: UUID) {
        guard earlyCleanups[sessionID] == nil,
              let session = sessions.first(where: { $0.id == sessionID }),
              !session.isQuickRecording,
              session.transcript?.rawText == nil,
              session.transcript?.text.isEmpty == false
        else { return }
        let previous = lastEarlyCleanup
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.earlyCleanups[sessionID] = nil }
            guard ClaudeCodeService.locate() != nil,
                  let current = self.sessions.first(where: { $0.id == sessionID }),
                  current.transcript?.rawText == nil
            else { return }
            if await self.cleanUpTranscript(for: current) { self.earlyCleanupDone.insert(sessionID) }
        }
        earlyCleanups[sessionID] = task
        lastEarlyCleanup = task
    }

    /// Returns whether the cleanup ran to the end (changed or not); false when it failed, was
    /// cancelled, or the transcript was edited by hand meanwhile.
    @discardableResult
    func cleanUpTranscript(for session: RecordingSession) async -> Bool {
        guard let transcript = session.transcript, !transcript.text.isEmpty else { return false }
        guard !transcriptCleanupInProgress.contains(session.id) else { return false }

        transcriptCleanupInProgress.insert(session.id)
        renamesDuringCleanup[session.id] = []
        defer {
            transcriptCleanupInProgress.remove(session.id)
            renamesDuringCleanup[session.id] = nil
        }

        // Without Claude only the dictionary's exact replacements apply.
        guard let claude = ClaudeCodeService.locate() else { return false }
        do {
            var cleaned = try await transcriptCleanupService.cleanUp(
                transcript.text, claude: claude, context: cleanupContext(for: session))

            guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return false }
            // The transcript may have changed while the model worked: speakers named (their
            // names go into the result too) or text edited by hand (the edit wins, no cleanup).
            var input = transcript.text
            for names in renamesDuringCleanup[session.id] ?? [] {
                input = SpeakerRenaming.apply(names, to: input).text
                cleaned = SpeakerRenaming.apply(names, to: cleaned).text
            }
            guard sessions[index].transcript?.text == input else {
                NSLog("AppViewModel: transcript edited during cleanup, cleanup dropped for \(session.id)")
                return false
            }
            guard cleaned != input else {
                NSLog("AppViewModel: cleanup produced no changes for \(session.id)")
                return true
            }

            var updated = sessions[index]
            // Keep the first raw version — repeated cleanups must not overwrite the original.
            let raw = updated.transcript?.rawText ?? input
            updated.transcript?.rawText = raw
            updated.transcript?.text = cleaned
            updated.transcript?.updatedAt = Date()
            updateSession(updated, persist: true)

            if let fileName = updated.transcript?.fileName {
                try? persistTranscriptFile(text: cleaned, fileName: fileName)
            }
            exportToProjectFolder(.transcript, text: cleaned, sessionID: session.id)
            NSLog("AppViewModel: transcript cleaned via Claude for \(session.id)")
            return true
        } catch is CancellationError {
            NSLog("AppViewModel: transcript cleanup cancelled for \(session.id)")
        } catch {
            errorMessage = "Transcript cleanup failed: \(error.localizedDescription)"
        }
        return false
    }

    /// Names and terms that help the cleanup model spell the meeting right.
    private func cleanupContext(for session: RecordingSession) -> String {
        var parts: [String] = []
        if let title = session.calendarEventTitle ?? Optional(session.title) { parts.append("Title: \(title)") }
        if let attendees = session.calendarAttendees, !attendees.isEmpty {
            parts.append("Attendees: \(attendees.joined(separator: ", "))")
        }
        let speakers = (session.speakerProfiles ?? []).compactMap(\.name)
        if !speakers.isEmpty { parts.append("Speakers: \(speakers.joined(separator: ", "))") }
        if let project = session.projectID.flatMap({ id in projects.first { $0.id == id } }) {
            parts.append("Project: \(project.name)")
        }
        let dictionary = vocabulary.promptContext
        if !dictionary.isEmpty { parts.append("Dictionary (correct spellings):\n\(dictionary)") }
        return parts.joined(separator: "\n")
    }

    /// Restores the untouched engine output, discarding the AI cleanup.
    func revertTranscriptCleanup(for session: RecordingSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }),
            let raw = sessions[index].transcript?.rawText
        else { return }

        var updated = sessions[index]
        updated.transcript?.text = raw
        updated.transcript?.rawText = nil
        updated.transcript?.updatedAt = Date()
        updateSession(updated, persist: true)

        if let fileName = updated.transcript?.fileName {
            try? persistTranscriptFile(text: raw, fileName: fileName)
        }
        exportToProjectFolder(.transcript, text: raw, sessionID: session.id)
        NSLog("AppViewModel: reverted transcript cleanup for \(session.id)")
    }

    /// Fixes near-miss spellings of known proper nouns (participant names, project, title) in a
    /// finished transcript. Returns the text unchanged when the feature is off or nothing matched.
    private func correctProperNouns(_ text: String, for session: RecordingSession) -> String {
        guard !text.isEmpty else { return text }
        // Dictionary first: exact, user-confirmed mappings always apply.
        let (mapped, mappedCount) = VocabularyCorrection.apply(text, entries: vocabulary.entries)
        if mappedCount > 0 { NSLog("AppViewModel: applied \(mappedCount) dictionary correction(s)") }
        let text = mapped
        guard automationSettings.properNounCorrectionEnabled else { return text }
        let terms = transcriptionContext(for: session).terms
        guard !terms.isEmpty else { return text }

        let (corrected, replacements) = ProperNounCorrection.correct(text, terms: terms)
        if replacements > 0 {
            NSLog("AppViewModel: corrected \(replacements) proper-noun spelling(s) in transcript")
        }
        return corrected
    }

    // MARK: - Speaker naming

    /// The user's own name for the microphone speaker (Settings, Audio), nil while unset.
    var ownSpeakerName: String? {
        let name = automationSettings.ownSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Labels the microphone speaker of a fresh transcript with the user's name instead of "You".
    private func labelOwnSpeaker(_ text: String) -> String {
        guard let name = ownSpeakerName else { return text }
        return SpeakerRenaming.apply([TranscriptFormatting.localSpeaker: name], to: text).text
    }

    /// Speakers detected for a session, if it was diarized.
    func speakerProfiles(for session: RecordingSession) -> [RecordingSession.SpeakerProfile] {
        session.speakerProfiles ?? []
    }

    /// Speakers the user can put a name to.
    ///
    /// Prefers the diarized profiles, which carry an audio sample and a voice embedding. Transcripts
    /// made before speakers were recorded have none, so their labels are read straight out of the
    /// transcript text: those can still be renamed, just without playback or voice learning.
    func nameableSpeakers(for session: RecordingSession) -> [RecordingSession.SpeakerProfile] {
        let profiles = speakerProfiles(for: session)
        guard profiles.isEmpty, let text = session.transcript?.text else { return profiles }

        return SpeakerRenaming.labels(in: text)
            .filter { $0 != TranscriptFormatting.localSpeaker && $0 != ownSpeakerName }
            .map {
                RecordingSession.SpeakerProfile(
                    label: $0, channel: .system, sampleStart: 0, sampleEnd: 0)
            }
    }

    /// Name suggestions for the naming sheet: people already in the voice library first (they are
    /// the likely repeat participants), then the meeting's calendar attendees.
    func speakerNameSuggestions(for session: RecordingSession) -> [String] {
        let attendees = TranscriptionContext.build(
            meetingTitle: nil, calendarEventTitle: nil,
            attendees: session.calendarAttendees, projectName: nil
        ).terms

        var seen = Set<String>()
        return (voiceDirectory.names + attendees).filter { name in
            seen.insert(name.lowercased()).inserted
        }
    }

    // MARK: - Voice library

    /// Matches the speakers a diarizer found against the voice library, filling in the names of
    /// people the user has named before and rewriting the transcript to use them.
    ///
    /// This is the payoff of the library: a recurring meeting comes out of transcription already
    /// saying "Anna:" instead of "Speaker 2:", with no interaction at all.
    private func recognizeSpeakers(in text: String, samples: [SpeakerSample])
        -> (text: String, profiles: [RecordingSession.SpeakerProfile]?)
    {
        guard !samples.isEmpty else { return (text, nil) }

        // One voice must not end up on two speakers in the same recording — if two clusters both
        // look like Anna, only the closer one gets the name and the other stays unnamed.
        var winnerByVoice: [UUID: (label: String, match: (voice: KnownVoice, distance: Float))] = [:]
        for sample in samples {
            guard let embedding = sample.embedding,
                let match = voiceDirectory.match(embedding)
            else { continue }

            if let current = winnerByVoice[match.voice.id], current.match.distance <= match.distance {
                continue
            }
            winnerByVoice[match.voice.id] = (sample.label, match)
        }

        var matchByLabel: [String: (voice: KnownVoice, distance: Float)] = [:]
        for winner in winnerByVoice.values {
            matchByLabel[winner.label] = winner.match
        }

        let profiles = samples.map { sample -> RecordingSession.SpeakerProfile in
            let match = matchByLabel[sample.label]
            if let match {
                NSLog(
                    "AppViewModel: recognized \(sample.label) as \(match.voice.name) (distance \(match.distance))"
                )
            }
            return RecordingSession.SpeakerProfile(
                label: sample.label,
                name: match?.voice.name,
                channel: sample.channel,
                sampleStart: sample.start,
                sampleEnd: sample.end,
                embedding: sample.embedding,
                voiceID: match?.voice.id,
                wasAutoMatched: match == nil ? nil : true,
                spokenSeconds: sample.spokenSeconds)
        }

        let names = matchByLabel.mapValues(\.voice.name)
        guard !names.isEmpty else { return (text, profiles) }
        return (SpeakerRenaming.apply(names, to: text).text, profiles)
    }

    /// Applies user-assigned names to a session's transcript and remembers them on the profiles.
    /// `names` maps the label currently shown in the transcript to the new display name.
    func renameSpeakers(_ names: [String: String], for session: RecordingSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }),
            let transcript = sessions[index].transcript
        else { return }

        let (updatedText, changed) = SpeakerRenaming.apply(names, to: transcript.text)
        guard changed > 0 else { return }
        // A cleanup running now started from the old labels; it applies these names to its result.
        renamesDuringCleanup[session.id]?.append(names)

        var updated = sessions[index]
        updated.transcript?.text = updatedText
        updated.transcript?.updatedAt = Date()
        // Track the assigned name so the sheet shows it and the original label stays recoverable,
        // and teach the voice library who this was so later recordings recognise them by themselves.
        updated.speakerProfiles = updated.speakerProfiles?.map { profile in
            var profile = profile
            guard let newName = names[profile.displayLabel],
                !newName.trimmingCharacters(in: .whitespaces).isEmpty
            else { return profile }

            profile.name = newName
            profile.wasAutoMatched = false
            if let embedding = profile.embedding,
                let voice = voiceDirectory.learn(
                    name: newName, embedding: embedding,
                    spokenSeconds: profile.spokenSeconds ?? 0)
            {
                profile.voiceID = voice.id
            }
            return profile
        }
        updateSession(updated, persist: true)

        if let fileName = updated.transcript?.fileName {
            try? persistTranscriptFile(text: updatedText, fileName: fileName)
        }
        // Keep the raw copy in sync so "Undo Polish" cannot resurrect the old labels.
        if updated.transcript?.rawText != nil,
            let raw = updated.transcript?.rawText
        {
            sessions[index].transcript?.rawText = SpeakerRenaming.apply(names, to: raw).text
            try? store.saveSessions(sessions)
        }
        exportToProjectFolder(.transcript, text: updatedText, sessionID: session.id)
        NSLog("AppViewModel: renamed speakers on \(changed) line(s) for \(session.id)")
    }

    /// Saves a transcript the user edited by hand.
    ///
    /// Writes the session, the transcript file and the project export together, so the copy on disk
    /// and the copy in the project folder never drift from what the reader shows. The raw
    /// pre-cleanup text is left untouched: it is the record of what the engine produced, and a
    /// manual edit does not change that.
    func updateTranscriptText(_ text: String, for session: RecordingSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }),
            sessions[index].transcript != nil
        else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != sessions[index].transcript?.text else { return }

        var updated = sessions[index]
        updated.transcript?.text = trimmed
        updated.transcript?.updatedAt = Date()
        updateSession(updated, persist: true)

        let fileName = updated.transcript?.fileName ?? transcriptFileName(for: updated)
        try? persistTranscriptFile(text: trimmed, fileName: fileName)
        exportToProjectFolder(.transcript, text: trimmed, sessionID: session.id)
        NSLog("AppViewModel: transcript edited for \(session.id) (\(trimmed.count) characters)")
    }

    /// The audio file and time range for a speaker's sample, for playback in the naming sheet.
    func speakerSampleURL(for profile: RecordingSession.SpeakerProfile, in session: RecordingSession)
        -> URL?
    {
        session.fileURL(for: profile.channel, baseURL: store.recordingsDirectory)
    }

    /// Diarization settings when the feature is enabled and its models are installed, else nil.
    /// Engines that receive nil simply label the remote channel with the generic "Other".
    private var activeDiarization: DiarizationOptions? {
        guard automationSettings.speakerDiarizationEnabled,
            speakerDiarizationModels.isInstalled
        else { return nil }
        let useNemotron = automationSettings.diarizationEngine == "nemotron3"
            && speakerDiarizationModels.isNemotronInstalled
        return DiarizationOptions(
            diarizer: useNemotron ? Nemotron3SpeakerDiarizer() : FluidAudioDiarizer(),
            includeMicrophone: automationSettings.diarizeMicrophone)
    }

    /// Returns a cleaned temp copy of `url` for transcription (high-pass + normalize + gentle
    /// gate), plus the temp URL to delete afterwards. Falls back to the original when
    /// preprocessing is disabled or fails.
    private func preprocessedAudioURL(_ url: URL?) async -> (url: URL?, temp: URL?) {
        guard automationSettings.audioPreprocessingEnabled, let url,
            FileManager.default.fileExists(atPath: url.path)
        else { return (url, nil) }
        if let cleaned = await AudioPreprocessor.process(url: url) {
            return (cleaned, cleaned)
        }
        return (url, nil)
    }

    /// Writes a transcription run's state onto the session as it is now, not the run's starting
    /// copy: fields the user changed meanwhile (project, General, title, keep audio, inbox skip)
    /// survive. A session deleted during the run stays deleted. See takeTranscriptionResult.
    private func storeTranscriptionRun(_ run: RecordingSession) {
        guard var current = sessions.first(where: { $0.id == run.id }) else { return }
        current.takeTranscriptionResult(from: run)
        updateSession(current, persist: true)
    }

    func transcribe(sessionID: UUID, language: LanguageOption? = nil) async {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[index]
        
        // Update language if provided, otherwise use selectedLanguage
        let languageToUse = language ?? selectedLanguage
        session.languageCode = languageToUse.rawValue
        
        // Set status to transcribing and update immediately
        session.status = .transcribing
        storeTranscriptionRun(session)
        
        isTranscribing = true
        transcribingSessionID = sessionID
        transcriptionProgress = nil
        transcriptionProgressMessage = ""
        
        // Ensure cleanup always happens
        defer {
            transcriptionProgress = nil
            transcriptionProgressMessage = ""
            transcribingSessionID = nil
            isTranscribing = false
        }
        
        do {
            let micURL = session.fileURL(for: .microphone, baseURL: store.recordingsDirectory)
            let systemURL = session.fileURL(for: .system, baseURL: store.recordingsDirectory)
            
            // Verify files exist
            let micExists = micURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let sysExists = systemURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            
            NSLog("AppViewModel.transcribe: session=\(session.id), mic=\(session.micFileName ?? "nil"), system=\(session.systemFileName ?? "nil")")
            NSLog("AppViewModel.transcribe: micExists=\(micExists), sysExists=\(sysExists)")
            
            guard micExists || sysExists else {
                throw NSError(domain: "MinuteMind", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No audio files found. The recording files may have been moved or deleted."
                ])
            }
            
            let isAutoDetect = session.languageCode == "auto"
            let context = transcriptionContext(for: session)
            let (micProc, micTemp) = await preprocessedAudioURL(micURL)
            let (sysProc, sysTemp) = await preprocessedAudioURL(systemURL)
            defer {
                [micTemp, sysTemp].compactMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) }
            }
            let diarization = activeDiarization
            let rawText = try await transcriptionService.transcribeSession(
                microphoneURL: micProc,
                systemURL: sysProc,
                localeIdentifier: isAutoDetect ? nil : session.languageCode,
                autoDetectLanguage: isAutoDetect,
                contextualStrings: context.terms,
                diarization: diarization,
                onProgress: { [weak self] current, total in
                    Task { @MainActor in
                        self?.transcriptionProgress = (current, total)
                        self?.transcriptionProgressMessage = "Transcribing chunk \(current) of \(total)"
                    }
                }
            )
            // Fix near-miss spellings of known names/project terms before storing.
            let corrected = correctProperNouns(rawText.text, for: session)
            // Put names to the detected voices we already know, and the user's own name to the
            // microphone speaker, before anything is written out.
            let (recognized, profiles) = recognizeSpeakers(in: corrected, samples: rawText.speakers)
            let text = labelOwnSpeaker(recognized)
            session.speakerProfiles = profiles
            let transcriptFileName = transcriptFileName(for: session)
            session.transcript = RecordingSession.Transcript(
                text: text,
                languageCode: session.languageCode,
                updatedAt: Date(),
                fileName: transcriptFileName
            )
            session.status = .completed
            session.lastErrorMessage = nil
            storeTranscriptionRun(session)
            try? persistTranscriptFile(text: text, fileName: transcriptFileName)
            exportToProjectFolder(.transcript, text: text, sessionID: session.id)
        } catch let interrupted as TranscriptionInterruptedError {
            if let partial = interrupted.partialText, !partial.isEmpty {
                let transcriptFileName = transcriptFileName(for: session)
                session.transcript = RecordingSession.Transcript(
                    text: partial, languageCode: session.languageCode,
                    updatedAt: Date(), fileName: transcriptFileName)
                session.status = .completed
                session.lastErrorMessage = "Partial transcript — stopped early by user."
                storeTranscriptionRun(session)
                try? persistTranscriptFile(text: partial, fileName: transcriptFileName)
                exportToProjectFolder(.transcript, text: partial, sessionID: session.id)
                NSLog("AppViewModel.transcribe: Saved partial transcript for session \(sessionID)")
            } else {
                session.status = .recorded
                session.lastErrorMessage = nil
                storeTranscriptionRun(session)
                NSLog("AppViewModel.transcribe: Stopped with no partial results for session \(sessionID)")
            }
        } catch is CancellationError {
            session.status = .recorded
            session.lastErrorMessage = nil
            storeTranscriptionRun(session)
            NSLog("AppViewModel.transcribe: Cancelled for session \(sessionID)")
        } catch {
            session.status = .failed
            session.lastErrorMessage = error.localizedDescription
            storeTranscriptionRun(session)
            self.errorMessage = error.localizedDescription
        }
    }

    /// Transcribes a session with the on-device NVIDIA Parakeet model (FluidAudio).
    func transcribeWithParakeet(sessionID: UUID, language: LanguageOption = .auto) async {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        var session = sessions[index]

        session.status = .transcribing
        storeTranscriptionRun(session)

        isTranscribing = true
        transcribingSessionID = sessionID

        defer {
            transcriptionProgress = nil
            transcriptionProgressMessage = ""
            parakeetLoadingMessage = nil
            parakeetService.onModelLoadProgress = nil
            parakeetService.onProgress = nil
            transcribingSessionID = nil
            isTranscribing = false
        }

        // Parakeet reports a completion fraction as (percent, 100) — only for audio longer than ~15 s.
        parakeetService.onProgress = { [weak self] current, total in
            Task { @MainActor in
                guard let self else { return }
                guard total > 0 else {
                    self.transcriptionProgressMessage = "Transcribing…"
                    return
                }
                let prev = self.transcriptionProgress?.current ?? 0
                let clamped = min(max(prev, current), total)
                self.transcriptionProgress = (clamped, total)
                self.transcriptionProgressMessage = "Transcribing… \(Int(Double(clamped) / Double(total) * 100))%"
            }
        }

        parakeetService.onModelLoadProgress = { [weak self] message in
            Task { @MainActor in
                self?.parakeetLoadingMessage = message.isEmpty ? nil : message
                self?.transcriptionProgressMessage = message
            }
        }

        do {
            let micURL = session.fileURL(for: .microphone, baseURL: store.recordingsDirectory)
            let systemURL = session.fileURL(for: .system, baseURL: store.recordingsDirectory)

            let languageCode: String? = language.isAutoDetect ? nil : language.rawValue
            let (micProc, micTemp) = await preprocessedAudioURL(micURL)
            let (sysProc, sysTemp) = await preprocessedAudioURL(systemURL)
            defer {
                [micTemp, sysTemp].compactMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) }
            }

            let rawText = try await parakeetService.transcribe(
                microphoneURL: micProc,
                systemURL: sysProc,
                language: languageCode,
                diarization: activeDiarization
            )

            // Fix near-miss spellings of known names/project terms before storing.
            let corrected = correctProperNouns(rawText.text, for: session)
            // Put names to the detected voices we already know, and the user's own name to the
            // microphone speaker, before anything is written out.
            let (recognized, profiles) = recognizeSpeakers(in: corrected, samples: rawText.speakers)
            let text = labelOwnSpeaker(recognized)
            session.speakerProfiles = profiles
            let transcriptFileName = transcriptFileName(for: session)
            session.transcript = RecordingSession.Transcript(
                text: text,
                languageCode: session.languageCode,
                updatedAt: Date(),
                fileName: transcriptFileName
            )
            session.status = .completed
            session.lastErrorMessage = nil
            storeTranscriptionRun(session)
            try? persistTranscriptFile(text: text, fileName: transcriptFileName)
            exportToProjectFolder(.transcript, text: text, sessionID: session.id)
        } catch let interrupted as TranscriptionInterruptedError {
            if let partial = interrupted.partialText, !partial.isEmpty {
                let transcriptFileName = transcriptFileName(for: session)
                session.transcript = RecordingSession.Transcript(
                    text: partial, languageCode: session.languageCode,
                    updatedAt: Date(), fileName: transcriptFileName)
                session.status = .completed
                session.lastErrorMessage = "Partial transcript — stopped early by user."
                storeTranscriptionRun(session)
                try? persistTranscriptFile(text: partial, fileName: transcriptFileName)
                exportToProjectFolder(.transcript, text: partial, sessionID: session.id)
                NSLog("AppViewModel.transcribeWithParakeet: Saved partial transcript for session \(sessionID)")
            } else {
                session.status = .recorded
                session.lastErrorMessage = nil
                storeTranscriptionRun(session)
                NSLog("AppViewModel.transcribeWithParakeet: Stopped with no partial results for session \(sessionID)")
            }
        } catch is CancellationError {
            session.status = .recorded
            session.lastErrorMessage = nil
            storeTranscriptionRun(session)
            NSLog("AppViewModel.transcribeWithParakeet: Cancelled for session \(sessionID)")
        } catch {
            session.status = .failed
            session.lastErrorMessage = error.localizedDescription
            storeTranscriptionRun(session)
            self.errorMessage = error.localizedDescription
        }
    }

    func audioURL(for session: RecordingSession, channel: RecordingSession.Channel) -> URL? {
        session.fileURL(for: channel, baseURL: store.recordingsDirectory)
    }

    // MARK: - Post-Recording M4A Conversion

    /// Convert a session's .caf recordings to .m4a (AAC) and update the session filenames.
    /// Only deletes the original .caf after validating the .m4a is playable.
    /// When `persist` is false the caller is responsible for saving sessions — used by
    /// the bulk migration to avoid re-encoding the entire sessions array per file.
    @discardableResult
    private func convertRecordingsToM4A(sessionID: UUID, persist: Bool = true) async -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        var session = sessions[index]
        let baseDir = store.recordingsDirectory
        var changed = false

        // Convert microphone .caf → .m4a
        if let micName = session.micFileName, micName.hasSuffix(".caf") {
            let cafURL = baseDir.appendingPathComponent(micName)
            if FileManager.default.fileExists(atPath: cafURL.path) {
                if let m4aName = await convertAndValidate(cafURL: cafURL) {
                    session.micFileName = m4aName
                    changed = true
                }
            }
        }

        // Convert system audio .caf → .m4a
        if let sysName = session.systemFileName, sysName.hasSuffix(".caf") {
            let cafURL = baseDir.appendingPathComponent(sysName)
            if FileManager.default.fileExists(atPath: cafURL.path) {
                if let m4aName = await convertAndValidate(cafURL: cafURL) {
                    session.systemFileName = m4aName
                    changed = true
                }
            }
        }

        // Persist updated filenames onto the current session: the user may have picked a
        // project or renamed the meeting while the files were converting.
        if changed, let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].takeConvertedAudio(from: session)
            if persist {
                try? store.saveSessions(sessions)
            }
        }
        return changed
    }

    /// Convert a single .caf file to .m4a, validate the output, then delete the original.
    /// Returns the new filename on success, nil on failure (original .caf is kept).
    private func convertAndValidate(cafURL: URL) async -> String? {
        do {
            let m4aURL = try await audioProcessor.convertToM4A(from: cafURL)

            // Validate: verify the .m4a is readable as audio
            let asset = AVAsset(url: m4aURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else {
                NSLog("AppViewModel: M4A validation failed (no audio tracks) — keeping .caf")
                try? FileManager.default.removeItem(at: m4aURL)
                return nil
            }

            // Only now delete the original
            try? FileManager.default.removeItem(at: cafURL)
            NSLog("AppViewModel: Converted \(cafURL.lastPathComponent) → \(m4aURL.lastPathComponent)")
            return m4aURL.lastPathComponent
        } catch {
            NSLog("AppViewModel: M4A conversion failed, keeping .caf — \(error.localizedDescription)")
            return nil
        }
    }

    /// Tracks whether a migration is already in progress to prevent overlapping runs.
    private var isMigratingToM4A = false

    /// One-shot migration that moves waveform data out of sessions.json into per-session
    /// sidecar files. Self-healing: detects work by checking whether any in-memory session
    /// has waveform samples (which only happens when decoded from a legacy sessions.json).
    /// After this runs once, all subsequent loads have nil waveforms in memory (because
    /// the new encoder doesn't write them), so the loop short-circuits in microseconds.
    private func migrateWaveformsToSidecar() {
        var migrated = 0
        for index in sessions.indices {
            guard let samples = sessions[index].waveformSamples,
                  let duration = sessions[index].waveformDuration else { continue }

            let sidecar = WaveformSidecar(
                samples: samples,
                duration: duration,
                speechSegments: (sessions[index].waveformSpeechSegments ?? [])
                    .map { ($0.startTime, $0.endTime) },
                channel: sessions[index].waveformChannel ?? "microphone"
            )
            try? waveformStore.save(sessionID: sessions[index].id, sidecar)

            // Clear in-memory waveform so it doesn't keep getting re-encoded. The next
            // generateWaveform() call will read from the sidecar transparently.
            sessions[index].waveformSamples = nil
            sessions[index].waveformDuration = nil
            sessions[index].waveformSpeechSegments = nil
            sessions[index].waveformChannel = nil
            migrated += 1
        }

        if migrated > 0 {
            NSLog("AppViewModel: Migrated \(migrated) waveform(s) to sidecar files")
            // Single save — this is the last time sessions.json will contain Float data.
            try? store.saveSessions(sessions)
        }
    }

    /// Convert any pending legacy .caf recordings to .m4a. Self-healing: filename
    /// suffix is the source of truth — `.caf` means "needs conversion", `.m4a` means
    /// "done, never touch again". On every launch we do an O(N) in-memory suffix
    /// scan (microseconds) and only do real work when something is pending. Once a
    /// session is migrated, its filename never reverts, so it's skipped forever
    /// without needing a separate persisted flag.
    ///
    /// Also handles a small recovery branch for the legacy bug where metadata says
    /// `.m4a` but the file is missing and the original `.caf` still exists.
    func migrateOldRecordingsToM4A() {
        guard !isMigratingToM4A else { return }

        // Cheap in-memory check: anything still pointing at a .caf? If not, return
        // immediately. No disk I/O, no JSON encoding, no flag bookkeeping.
        let hasAnyCafReference = sessions.contains { session in
            session.micFileName?.hasSuffix(".caf") == true
                || session.systemFileName?.hasSuffix(".caf") == true
        }
        guard hasAnyCafReference else { return }

        isMigratingToM4A = true
        let baseDir = store.recordingsDirectory
        Task {
            defer { isMigratingToM4A = false }
            var anyChanged = false

            for (index, session) in sessions.enumerated() {
                guard session.status != .recording && session.status != .transcribing else { continue }

                // Recovery: session points to .m4a but the file is missing/corrupt,
                // and the original .caf still exists → revert to .caf filename so
                // the conversion step below picks it up.
                var needsRecovery = false
                if let micName = session.micFileName, micName.hasSuffix(".m4a") {
                    let m4aPath = baseDir.appendingPathComponent(micName).path
                    let cafPath = baseDir.appendingPathComponent(
                        micName.replacingOccurrences(of: ".m4a", with: ".caf")).path
                    if !FileManager.default.fileExists(atPath: m4aPath),
                       FileManager.default.fileExists(atPath: cafPath) {
                        needsRecovery = true
                    }
                }
                if let sysName = session.systemFileName, sysName.hasSuffix(".m4a") {
                    let m4aPath = baseDir.appendingPathComponent(sysName).path
                    let cafPath = baseDir.appendingPathComponent(
                        sysName.replacingOccurrences(of: ".m4a", with: ".caf")).path
                    if !FileManager.default.fileExists(atPath: m4aPath),
                       FileManager.default.fileExists(atPath: cafPath) {
                        needsRecovery = true
                    }
                }

                if needsRecovery {
                    NSLog("AppViewModel: Recovering broken migration for '\(session.title)'")
                    if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                        if let micName = sessions[idx].micFileName, micName.hasSuffix(".m4a") {
                            let cafName = micName.replacingOccurrences(of: ".m4a", with: ".caf")
                            if FileManager.default.fileExists(atPath: baseDir.appendingPathComponent(cafName).path) {
                                sessions[idx].micFileName = cafName
                            }
                        }
                        if let sysName = sessions[idx].systemFileName, sysName.hasSuffix(".m4a") {
                            let cafName = sysName.replacingOccurrences(of: ".m4a", with: ".caf")
                            if FileManager.default.fileExists(atPath: baseDir.appendingPathComponent(cafName).path) {
                                sessions[idx].systemFileName = cafName
                            }
                        }
                        anyChanged = true
                    }
                }

                // Convert .caf → .m4a (skips if neither filename ends in .caf).
                let hasCafMic = sessions.first(where: { $0.id == session.id })?.micFileName?.hasSuffix(".caf") == true
                let hasCafSys = sessions.first(where: { $0.id == session.id })?.systemFileName?.hasSuffix(".caf") == true
                guard hasCafMic || hasCafSys else { continue }

                NSLog("AppViewModel: Converting session '\(session.title)' recordings to M4A")
                let converted = await convertRecordingsToM4A(sessionID: session.id, persist: false)
                anyChanged = anyChanged || converted

                if index % 5 == 4 { await Task.yield() }
            }

            // Single save at the end, instead of after every per-session conversion.
            if anyChanged {
                try? store.saveSessions(sessions)
                NSLog("AppViewModel: M4A conversion pass complete")
            }
        }
    }

    func openTranscript(_ session: RecordingSession) {
        guard let transcript = session.transcript, !transcript.text.isEmpty else {
            errorMessage = "Transcript not available yet."
            return
        }

        let fileName = transcript.fileName ?? transcriptFileName(for: session)
        do {
            try persistTranscriptFile(text: transcript.text, fileName: fileName)
            let url = store.transcriptsDirectory.appendingPathComponent(fileName)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func minutesURL(for session: RecordingSession) -> URL? {
        session.meetingMinutesURL(baseURL: store.minutesDirectory)
    }

    func openMinutes(_ session: RecordingSession) {
        // Find the open window action from the environment?
        // Since we are in ViewModel, we can't emit OpenWindowAction directly.
        // We will maintain the 'selectedMinutesSession' for other views to react,
        // OR we rely on the View layer to call openWindow.
        //
        // Strategy: We will add a published event or property that the View can observe
        // to trigger openWindow.
        // HOWEVER, to keep it simple and consistent:
        // We will repurpose `selectedMinutesSession` to be observed by ContentView
        // which will then calculate the window opening.
        // BUT `ContentView` is in a different WindowGroup.
        //
        // Correct Approach for multiple windows:
        // The buttons (ProjectRecordingCard) should call `openWindow` directly.
        //
        // So I will deprecate `openMinutes` in ViewModel or leave it empty?
        // Wait, other views call `viewModel.openMinutes`.
        // Let's change `openMinutes` to just set `selectedMinutesSessionIDForWindow`
        // and have `ContentView` (or the root view) listen and open the window.
        //
        // Actually, since `MinuteMindApp` creates `ContentView`, and `ContentView` is in the main window...

        // For now, let's just utilize a Published property that ContentView observes
        // and triggers the window opening.
        selectedMinutesSession = session
    }

    func deleteMinutes(for session: RecordingSession) {
        guard var existing = sessions.first(where: { $0.id == session.id }) else { return }
        if let fileName = existing.meetingMinutesFileName {
            let url = store.minutesDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
        }
        existing.meetingMinutesFileName = nil
        existing.updatedAt = Date()
        updateSession(existing, persist: true)
        // Knowledge extracted from these minutes goes with them; notes, manual entries and agent
        // commits carry other source ids and stay.
        try? knowledgeStore?.replaceMeetingDocuments(meetingID: session.id, with: [])
    }

    /// True when the AI engine (Claude Code) is installed: summaries, titles, todos, the task
    /// brief, time blocks and the board summary need it.
    var isAIAvailable: Bool { AIClient.isAvailable }

    /// The background jobs' AI, with the model chosen in Settings, AI.
    var aiClient: AIClient { AIClient(model: automationSettings.claudeModel) }

    var canGenerateMeetingMinutes: Bool { isAIAvailable }

    func isGeneratingMinutes(for session: RecordingSession) -> Bool {
        minutesGenerationInProgress.contains(session.id) || processingStage[session.id] != nil
    }

    /// Generates the meeting minutes with Claude, using the selected summary prompt (or the
    /// default prompt when none is selected).
    func generateMeetingMinutes(for session: RecordingSession) async {
        guard isAIAvailable else {
            errorMessage = ClaudeCodeService.ServiceError.notInstalled.localizedDescription
            return
        }
        guard let transcript = session.transcript?.text, !transcript.isEmpty else {
            errorMessage = "Transcript required before generating minutes."
            return
        }
        let promptContent = activeSummaryPrompt?.content ?? SystemPrompt.defaultPrompt().content
        if minutesGenerationInProgress.contains(session.id) {
            return
        }
        minutesGenerationInProgress.insert(session.id)
        do {
            let minutes = try await aiClient.chat(system: promptContent, user: transcript, timeout: 600)
            let fileName = meetingMinutesFileName(for: session)
            try persistMinutesFile(text: minutes, fileName: fileName)
            // The current copy, not the one passed in: the user may have moved or renamed the
            // meeting while the summary was being written.
            var updated = sessions.first(where: { $0.id == session.id }) ?? session
            updated.meetingMinutesFileName = fileName
            updated.updatedAt = Date()
            updateSession(updated, persist: true)
            exportToProjectFolder(.summary, text: minutes, sessionID: session.id)

            // Notify the user that the summary is ready
            await sendSummaryReadyNotification(for: updated)

            // Knowledge is no longer extracted here: the knowledge agent curates the workspace's
            // knowledge/ files once the meeting is processed (runMeetingProcessing).
        } catch {
            errorMessage = error.localizedDescription
        }
        minutesGenerationInProgress.remove(session.id)
    }

    /// Generate an AI title for a session based on its meeting minutes content.
    /// Silently falls back to the existing title if generation fails.
    func generateSessionTitle(for sessionID: UUID) async {
        guard isAIAvailable,
              let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let minutesFileName = sessions[index].meetingMinutesFileName,
              let minutesContent = try? String(contentsOf: store.minutesDirectory.appendingPathComponent(minutesFileName), encoding: .utf8),
              !minutesContent.isEmpty else { return }
        let system = "Generate a concise, descriptive meeting title (3 to 8 words) in the language of the minutes. Return ONLY the title text, no quotes, no prefix, no explanation."
        if let title = try? await aiClient.chat(system: system, user: String(minutesContent.prefix(4000))),
           !title.isEmpty {
            renameSession(sessions[index], newTitle: title.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n")))
        }
    }

    /// Sends a local notification when a meeting summary finishes generating.
    /// Silently skipped if notification permission has not been granted.
    private func sendSummaryReadyNotification(for session: RecordingSession) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Meeting Summary Ready"
        content.body = "\"\(session.title)\" — your meeting summary has been generated."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "mm.summary.\(session.id.uuidString)",
            content: content,
            trigger: nil  // deliver immediately
        )
        try? await center.add(request)
    }

    /// Removes pre-scheduled static "Time to review your tasks" notifications left over
    /// from before AI-powered briefs replaced them.
    private func removeLegacyStaticReminders() async {
        // UNUserNotificationCenter.current() crashes in test environments with no bundle.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.filter { $0.identifier.hasPrefix("mm.taskReview.") }.map(\.identifier)
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        NSLog("AppViewModel: Removed %d legacy static task-review notification(s)", ids.count)
    }

    // MARK: - Daily Task Brief

    /// Runs the AI-powered daily task brief:
    /// 1. Selects top 10 incomplete tasks due within 7 days (by priority + due date).
    /// 2. Fetches calendar events for the same window.
    /// 3. Calls TodoBriefService to get an AI summary + per-task time slot suggestions.
    /// 4. Fires a local notification with a "Block Calendar" action that creates all suggested events.
    func runTodoBrief() async {
        guard isAIAvailable else {
            NSLog("AppViewModel: Skipping daily brief, Claude Code is not installed")
            return
        }

        let sevenDays: TimeInterval = 7 * 24 * 3600
        let deadline = Date().addingTimeInterval(sevenDays)

        let candidateTasks = tasks
            .filter { !$0.isCompleted && ($0.dueDate.map { $0 <= deadline } ?? false) }
            .sorted { a, b in
                let ap = priorityOrdinal(a.priority), bp = priorityOrdinal(b.priority)
                if ap != bp { return ap > bp }
                return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture)
            }
            .prefix(10)
            .map { $0 }

        guard !candidateTasks.isEmpty else {
            NSLog("AppViewModel: No tasks due in next 7 days — skipping brief")
            return
        }

        let calendarEvents = calendarService.fetchEvents(from: Date(), to: deadline)

        NSLog("AppViewModel: Running daily brief for %d tasks, %d calendar events",
              candidateTasks.count, calendarEvents.count)

        let service = TodoBriefService()
        let brief: TodoBrief
        do {
            brief = try await service.generateBrief(
                tasks: candidateTasks,
                calendarEvents: calendarEvents,
                ai: aiClient
            )
        } catch {
            NSLog("AppViewModel: Daily brief AI call failed: %@", error.localizedDescription)
            return
        }

        // Store brief for the sheet, then fire notification
        pendingTodoBrief = brief
        await sendTodoBriefNotification(brief)
    }

    private func priorityOrdinal(_ priority: TaskPriority?) -> Int {
        switch priority {
        case .critical: return 4
        case .high:     return 3
        case .medium:   return 2
        case .low:      return 1
        case nil:       return 0
        }
    }

    /// Fires a notification with a "Review & Schedule" action. Slot data lives in memory
    /// (`pendingTodoBrief`) — the notification just opens the selection sheet.
    private func sendTodoBriefNotification(_ brief: TodoBrief) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let reviewAction = UNNotificationAction(
            identifier: "REVIEW_BRIEF",
            title: "Review & Schedule",
            options: [.foreground]   // bring app to front
        )
        let category = UNNotificationCategory(
            identifier: "mm.todoBrief",
            actions: [reviewAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        let slotCount = brief.items.reduce(0) { $0 + $1.suggestedSlots.count }

        let content = UNMutableNotificationContent()
        content.title = "Task Brief"
        content.body = brief.summary
        content.sound = .default
        content.categoryIdentifier = "mm.todoBrief"

        let request = UNNotificationRequest(
            identifier: "mm.todoBrief.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
        NSLog("AppViewModel: Daily brief notification sent (%d tasks, %d slot options)", brief.items.count, slotCount)
    }

    /// The summary prompt in use: the selected one.
    var activeSummaryPrompt: SystemPrompt? {
        summaryPrompts.first(where: \.isSelected)
    }

    func addPrompt(title: String, content: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedContent.isEmpty else { return }
        mutateSummaryPrompts { prompts in
            var prompt = SystemPrompt(title: trimmedTitle, content: trimmedContent)
            if !prompts.contains(where: \.isSelected) {
                prompt.isSelected = true
            }
            prompts.append(prompt)
        }
    }

    func selectPrompt(_ prompt: SystemPrompt) {
        mutateSummaryPrompts { prompts in
            for idx in prompts.indices {
                prompts[idx].isSelected = (prompts[idx].id == prompt.id)
                if prompts[idx].isSelected { prompts[idx].isEnabled = true }
            }
        }
    }

    func deletePrompt(_ prompt: SystemPrompt) {
        mutateSummaryPrompts { prompts in
            prompts.removeAll(where: { $0.id == prompt.id })
            if !prompts.contains(where: \.isSelected), !prompts.isEmpty {
                prompts[0].isSelected = true
            }
        }
    }

    private func mutateSummaryPrompts(_ update: (inout [SystemPrompt]) -> Void) {
        update(&summaryPrompts)
        try? summaryPromptStore.save(summaryPrompts)
    }

    private func resolvedSessionTitle() -> String {
        let trimmed = pendingSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultSessionTitle() : trimmed
    }

    private func defaultSessionTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }

    private func fileSafeSlug(for title: String, id: UUID) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned =
            title
            .lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return cleaned.isEmpty ? id.uuidString : "\(cleaned)-\(id.uuidString.prefix(6))"
    }

    private func transcriptFileName(for session: RecordingSession) -> String {
        "\(session.id.uuidString).txt"
    }

    private func persistTranscriptFile(text: String, fileName: String) throws {
        try store.ensureDirectories()
        let fileURL = store.transcriptsDirectory.appendingPathComponent(fileName)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Exports a freshly generated transcript/summary into the session's project export
    /// folder (versioned, never overwriting). No-op when the session has no project or
    /// the project has no export folder / opted out. Called only on new generation —
    /// not when re-writing existing content (e.g. openTranscript).
    private func exportToProjectFolder(
        _ artifact: ProjectExportService.Artifact, text: String, sessionID: UUID
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = sessions[index]
        guard let projectID = session.projectID,
            let project = projects.first(where: { $0.id == projectID })
        else { return }
        do {
            guard
                let relativeFolder = try ProjectExportService.export(
                    artifact, text: text, session: session, project: project)
            else { return }
            if relativeFolder != session.exportFolderName {
                sessions[index].exportFolderName = relativeFolder
                try? store.saveSessions(sessions)
            }
            NSLog("AppViewModel: Exported \(artifact.baseName) to '\(relativeFolder)'")
        } catch {
            NSLog("AppViewModel: Project export failed — \(error.localizedDescription)")
            // The transcript/summary itself was saved successfully; only the copy into the
            // project's export folder failed. Make that explicit so it doesn't read as a
            // failed transcription.
            errorMessage = "Transcript saved, but copying it into the project's export folder failed: \(error.localizedDescription)"
        }
    }

    /// Keeps the exported meeting folder in sync when a session's title changes
    /// (AI title generation or manual rename).
    private func syncExportFolderName(forSessionAt index: Int, newTitle: String) {
        let session = sessions[index]
        guard session.exportFolderName != nil,
            let projectID = session.projectID,
            let project = projects.first(where: { $0.id == projectID }),
            let newRelative = ProjectExportService.renameMeetingFolder(
                session: session, project: project, newTitle: newTitle)
        else { return }
        sessions[index].exportFolderName = newRelative
        try? store.saveSessions(sessions)
    }

    private func meetingMinutesFileName(for session: RecordingSession) -> String {
        "\(session.id.uuidString)-minutes.md"
    }

    func saveMinutesContent(for session: RecordingSession, content: String) throws {
        guard let fileName = session.meetingMinutesFileName else {
            throw NSError(
                domain: "AppViewModel", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No minutes file exists"])
        }
        try persistMinutesFile(text: content, fileName: fileName)
    }

    private func persistMinutesFile(text: String, fileName: String) throws {
        try store.ensureDirectories()
        let fileURL = store.minutesDirectory.appendingPathComponent(fileName)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Project Management

    func createProject(name: String, colorHex: String = Project.defaultColors[0], companion: MascotAvatar? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var project = Project(name: trimmed, colorHex: colorHex)
        project.companionAvatar = companion?.rawValue
        projects.insert(project, at: 0)
        projectStore.debouncedSaveProjects(projects)
        selectedProjectID = project.id
    }

    /// Puts the projects in the order the user arranged in the sidebar. IDs not listed keep
    /// their place after the listed ones.
    func reorderProjects(_ ids: [UUID]) {
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let listed = ids.compactMap { id in projects.first { $0.id == id } }
        let rest = projects.filter { rank[$0.id] == nil }
        var reordered = listed + rest
        for index in reordered.indices { reordered[index].sortOrder = index }
        guard reordered.map(\.id) != projects.map(\.id) || projects.contains(where: { $0.sortOrder == nil }) else { return }
        projects = reordered
        projectStore.debouncedSaveProjects(projects)
    }

    func deleteProject(_ project: Project) {
        // Remove project assignment from all sessions
        for i in sessions.indices where sessions[i].projectID == project.id {
            sessions[i].projectID = nil
        }
        try? store.saveSessions(sessions)

        // Delete all tasks for this project
        tasks.removeAll { $0.projectID == project.id }
        projectStore.debouncedSaveTasks(tasks)

        // Delete all epics for this project
        epics.removeAll { $0.projectID == project.id }
        projectStore.debouncedSaveEpics(epics)

        // Calendar series routed to this project record unassigned from now on
        try? eventProjectStore.removeMappings(to: project.id)

        // Remove the project
        projects.removeAll { $0.id == project.id }
        projectStore.debouncedSaveProjects(projects)

        // Clear selection if this was selected
        if selectedProjectID == project.id {
            selectedProjectID = nil
        }
    }

    func renameProject(_ project: Project, newName: String) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projects[index].name = trimmed
        projects[index].updatedAt = Date()
        projectStore.debouncedSaveProjects(projects)
    }

    /// Adds a Shared Project joined from its repo, with the id its manifest gives
    /// (AppViewModel+SharedSetup.swift). Does nothing when a project with that id exists.
    func addJoinedProject(_ project: Project) {
        guard !projects.contains(where: { $0.id == project.id }) else { return }
        projects.insert(project, at: 0)
        projectStore.debouncedSaveProjects(projects)
    }

    /// Turns a project into a Shared Project (info) or back to Private (nil).
    func setProjectShared(_ projectID: UUID, _ info: SharedProjectInfo?) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].shared = info
        projects[index].updatedAt = Date()
        projectStore.debouncedSaveProjects(projects)
    }

    /// Stores publish choices made outside the saved card (the share-project skill) for the
    /// project's sessions, without mirroring: the files are already where the choice puts them.
    func recordPublications(_ choices: [UUID: MeetingPublication], in projectID: UUID) {
        var changed = false
        for index in sessions.indices where sessions[index].projectID == projectID {
            guard let choice = choices[sessions[index].id], sessions[index].publication != choice else { continue }
            sessions[index].publication = choice
            changed = true
        }
        if changed { try? store.saveSessions(sessions) }
    }

    /// Stars or unstars a project (sidebar right click): starred ones lead the companion's wheel.
    func setProjectStarred(_ project: Project, _ starred: Bool) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].isStarred = starred ? true : nil
        projects[index].updatedAt = Date()
        projectStore.debouncedSaveProjects(projects)
    }

    /// Gives a project its own companion creature (nil: none).
    func setProjectCompanion(_ project: Project, _ avatar: MascotAvatar?) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].companionAvatar = avatar?.rawValue
        projects[index].updatedAt = Date()
        projectStore.debouncedSaveProjects(projects)
    }

    func updateProjectAutoAccept(_ project: Project, value: Bool?) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].autoAcceptExtractedTasks = value
        projects[index].updatedAt = Date()
        projectStore.debouncedSaveProjects(projects)
    }

    func updateProjectExportSettings(_ project: Project, folderPath: String?, optOut: Bool) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let trimmed = folderPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        projects[index].exportFolderPath = (trimmed?.isEmpty ?? true) ? nil : trimmed
        projects[index].exportOptOut = optOut ? true : nil
        projects[index].updatedAt = Date()
        projectStore.debouncedSaveProjects(projects)
    }

    /// Writes a session's publish choice onto the stored session (AppViewModel+SharedPublishing.swift).
    func storePublication(_ publication: MeetingPublication?, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].publication = publication
        sessions[index].updatedAt = Date()
        if currentSession?.id == sessionID { currentSession?.publication = publication }
        try? store.saveSessions(sessions)
    }

    /// `ProjectRepositoryService.generalProjectID` files the meeting to the General workspace
    /// (the pickers' "General" entry); nil removes the assignment. Picking one starts processing
    /// an unprocessed meeting (MeetingProcessingRule).
    func assignSessionToProject(_ session: RecordingSession, projectID requested: UUID?) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let toGeneral = requested == ProjectRepositoryService.generalProjectID
        let projectID = toGeneral ? nil : requested
        let before = sessions[index]
        sessions[index].projectID = projectID
        sessions[index].assignedToGeneral = toGeneral ? true : nil
        // The publish choice belongs to a Shared Project: another project asks again.
        if before.projectID != projectID { sessions[index].publication = nil }
        sessions[index].updatedAt = Date()
        try? store.saveSessions(sessions)
        if before.projectID != projectID, before.meetingMinutesFileName != nil {
            // Processed already: its files and knowledge move to the new workspace.
            moveWorkspaceKnowledge(from: before)
        } else {
            mirrorToWorkspaceIfReady(session.id)
        }
        if sessions[index].hasProcessingTarget,
           before.projectID != projectID || before.assignedToGeneral != sessions[index].assignedToGeneral {
            meetingAssigned(session.id)
        }

        // Cascade project to any unassigned tasks extracted from this session.
        // Pending tasks keep needsReview=true so the user accepts them manually in the project view.
        if let projectID {
            var changed = false
            for i in tasks.indices {
                guard tasks[i].sourceSessionID == session.id else { continue }
                if tasks[i].projectID == nil {
                    tasks[i].projectID = projectID
                    changed = true
                }
            }
            if changed { projectStore.debouncedSaveTasks(tasks) }
        }
    }

    // MARK: - Auto-Accept Resolution

    /// Resolves whether extracted tasks should be auto-accepted for a given project.
    /// Per-project setting overrides the global default.
    func shouldAutoAcceptTasks(for projectID: UUID?) -> Bool {
        if let projectID,
           let project = projects.first(where: { $0.id == projectID }),
           let override = project.autoAcceptExtractedTasks {
            return override
        }
        return automationSettings.autoAcceptExtractedTasks
    }

    /// Accept a pending extracted task — sets projectID and clears needsReview.
    func acceptExtractedTask(_ task: ProjectTask, projectID: UUID?) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].needsReview = false
        if let projectID {
            tasks[index].projectID = projectID
        }
        projectStore.debouncedSaveTasks(tasks)
    }

    /// Reject (delete) a pending extracted task.
    func rejectExtractedTask(_ task: ProjectTask) {
        tasks.removeAll { $0.id == task.id }
        projectStore.debouncedSaveTasks(tasks)
    }

    /// Accept all pending tasks for a session.
    func acceptAllExtractedTasks(for sessionID: UUID, projectID: UUID?) {
        var changed = false
        for i in tasks.indices {
            guard tasks[i].sourceSessionID == sessionID,
                  tasks[i].needsReview == true else { continue }
            tasks[i].needsReview = false
            if let projectID {
                tasks[i].projectID = projectID
            }
            changed = true
        }
        if changed { projectStore.debouncedSaveTasks(tasks) }
    }

    /// Returns tasks extracted from a specific session (both pending and accepted).
    func tasksForSession(_ sessionID: UUID) -> [ProjectTask] {
        tasks.filter { $0.sourceSessionID == sessionID }
    }

    /// Returns only pending (needsReview) tasks for a session.
    func pendingTasksForSession(_ sessionID: UUID) -> [ProjectTask] {
        tasks.filter { $0.sourceSessionID == sessionID && $0.needsReview == true }
    }

    // MARK: - Task Management

    func reloadTasks() {
        if let loadedTasks = try? projectStore.loadTasks() {
            self.tasks = loadedTasks
        }
    }

    func createTask(title: String, projectID: UUID, notes: String = "") {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = ProjectTask(
            projectID: projectID,
            title: trimmed,
            notes: notes,
            dueDate: Self.endOfCurrentWeek,
            hasDueTime: true,
            priority: .medium
        )
        tasks.append(task)
        projectStore.debouncedSaveTasks(tasks)
    }

    func createDetailedTask(
        title: String,
        projectID: UUID,
        notes: String = "",
        assignee: String? = nil,
        dueDate: Date? = nil,
        priority: TaskPriority? = .medium,
        estimatedDurationMinutes: Int? = nil
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = ProjectTask(
            projectID: projectID,
            title: trimmed,
            notes: notes,
            assignee: assignee,
            dueDate: dueDate ?? Self.endOfCurrentWeek,
            hasDueTime: true,
            priority: priority,
            estimatedDurationMinutes: estimatedDurationMinutes
        )
        tasks.append(task)
        projectStore.debouncedSaveTasks(tasks)
    }

    /// Returns Friday 16:00 of the current week. If today is Friday, returns today at 16:00.
    static var endOfCurrentWeek: Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let daysUntilFriday = (6 - weekday + 7) % 7  // 0 if today is Friday
        let friday = cal.date(byAdding: .day, value: daysUntilFriday, to: today) ?? today
        return cal.date(bySettingHour: 16, minute: 0, second: 0, of: friday) ?? friday
    }

    /// Next working day (Mon–Fri) at 16:00, always at least tomorrow.
    static func nextWorkingDayAt16(after date: Date) -> Date {
        let cal = Calendar.current
        var candidate = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: date) ?? date)
        while cal.isDateInWeekend(candidate) {
            candidate = cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return cal.date(bySettingHour: 16, minute: 0, second: 0, of: candidate) ?? candidate
    }

    /// Rolls forward any incomplete task whose due date is before today's midnight
    /// to the next working day at 16:00. Called on launch and daily by AutomationCoordinator.
    func rollForwardOverdueTasks() {
        let todayStart = Calendar.current.startOfDay(for: Date())
        var changed = false
        for i in tasks.indices {
            guard !tasks[i].isCompleted,
                  let due = tasks[i].dueDate,
                  due < todayStart else { continue }
            tasks[i].dueDate = Self.nextWorkingDayAt16(after: Date())
            tasks[i].hasDueTime = true
            changed = true
        }
        if changed {
            projectStore.debouncedSaveTasks(tasks)
            NSLog("AppViewModel: Rolled forward overdue tasks to next working day")
        }
    }

    func toggleTask(_ task: ProjectTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].toggleCompleted()
        projectStore.debouncedSaveTasks(tasks)

        // Sync with Reminders if enabled
        if tasks[index].reminderEnabled {
            Task {
                await syncTaskToReminders(tasks[index])
            }
        }
    }

    /// Toggle reminder sync for a task (add to or remove from Apple Reminders)
    @MainActor
    func toggleTaskReminder(_ task: ProjectTask) async {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }

        let wasEnabled = tasks[index].reminderEnabled
        tasks[index].reminderEnabled = !wasEnabled

        if tasks[index].reminderEnabled {
            // Enable: sync to Reminders
            await syncTaskToReminders(tasks[index])
        } else if let reminderID = tasks[index].reminderID {
            // Disable: remove from Reminders
            try? await remindersService.deleteReminder(withID: reminderID)
            tasks[index].reminderID = nil
        }

        projectStore.debouncedSaveTasks(tasks)
    }

    func deleteTask(_ task: ProjectTask) {
        // Delete from Reminders if synced
        if let reminderID = task.reminderID {
            Task {
                try? await remindersService.deleteReminder(withID: reminderID)
            }
        }
        tasks.removeAll { $0.id == task.id }
        projectStore.debouncedSaveTasks(tasks)
    }

    /// Accept an auto-extracted task, clearing its review banner.
    func acceptTaskReview(_ task: ProjectTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].needsReview = nil
        projectStore.debouncedSaveTasks(tasks)
    }

    func updateTaskNotes(_ task: ProjectTask, notes: String) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].notes = notes
        projectStore.debouncedSaveTasks(tasks)
    }

    func updateTaskTitle(_ task: ProjectTask, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].title = trimmed
        projectStore.debouncedSaveTasks(tasks)
    }

    func updateTaskAssignee(_ task: ProjectTask, assignee: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let trimmed = assignee?.trimmingCharacters(in: .whitespacesAndNewlines)
        tasks[index].assignee = (trimmed?.isEmpty == true) ? nil : trimmed
        projectStore.debouncedSaveTasks(tasks)
    }

    func updateTaskDueDate(_ task: ProjectTask, dueDate: Date?) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].dueDate = dueDate
        projectStore.debouncedSaveTasks(tasks)
    }

    func updateTaskPriority(_ task: ProjectTask, priority: TaskPriority?) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].priority = priority
        projectStore.debouncedSaveTasks(tasks)
    }

    func updateTask(
        _ task: ProjectTask, title: String, assignee: String?, dueDate: Date?, hasDueTime: Bool,
        priority: TaskPriority?, notes: String, reminderEnabled: Bool, estimatedDuration: Int? = nil
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let trimmedAssignee = assignee?.trimmingCharacters(in: .whitespacesAndNewlines)

        let wasReminderEnabled = tasks[index].reminderEnabled

        tasks[index].title = trimmedTitle
        tasks[index].assignee = (trimmedAssignee?.isEmpty == true) ? nil : trimmedAssignee
        tasks[index].dueDate = dueDate
        tasks[index].hasDueTime = hasDueTime
        tasks[index].priority = priority
        tasks[index].notes = notes
        tasks[index].reminderEnabled = reminderEnabled
        tasks[index].estimatedDurationMinutes = estimatedDuration
        tasks[index].needsReview = nil  // Clear review state on edit
        projectStore.debouncedSaveTasks(tasks)

        // Handle reminder sync
        if reminderEnabled {
            Task {
                await syncTaskToReminders(tasks[index])
            }
        } else if wasReminderEnabled, let reminderID = tasks[index].reminderID {
            // Remove reminder if disabled
            Task {
                try? await remindersService.deleteReminder(withID: reminderID)
                if let idx = self.tasks.firstIndex(where: { $0.id == task.id }) {
                    self.tasks[idx].reminderID = nil
                    self.projectStore.debouncedSaveTasks(self.tasks)
                }
            }
        }
    }

    // MARK: - Reminders Sync

    /// Sync a task to Apple Reminders
    func syncTaskToReminders(_ task: ProjectTask) async {
        guard task.reminderEnabled else { return }
        guard let project = projects.first(where: { $0.id == task.projectID }) else { return }

        do {
            if let reminderID = try await remindersService.syncTask(task, projectName: project.name)
            {
                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[index].reminderID = reminderID
                    projectStore.debouncedSaveTasks(tasks)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sync all reminder-enabled tasks
    func syncAllReminders() async {
        for task in tasks where task.reminderEnabled {
            await syncTaskToReminders(task)
        }
    }

    /// Pull updates from Reminders back to app
    func pullRemindersUpdates() async {
        for (index, task) in tasks.enumerated() {
            guard let reminderID = task.reminderID else { continue }

            if let status = remindersService.fetchReminderStatus(reminderID: reminderID) {
                var needsSave = false

                if tasks[index].isCompleted != status.isCompleted {
                    if status.isCompleted {
                        tasks[index].isCompleted = true
                        tasks[index].completedAt = Date()
                    } else {
                        tasks[index].isCompleted = false
                        tasks[index].completedAt = nil
                    }
                    needsSave = true
                }

                if needsSave {
                    projectStore.debouncedSaveTasks(tasks)
                }
            }
        }
    }

    // MARK: - Calendar Time Blockers

    /// Get AI-suggested time blocks for a task
    func suggestTimeBlocks(for task: ProjectTask, timingPreferences: String? = nil) async throws
        -> (blocks: [ProposedTimeBlock], explanation: String)
    {
        guard let dueDate = task.dueDate else {
            throw CalendarBlockerService.ServiceError.noDueDate
        }
        guard let duration = task.estimatedDurationMinutes, duration > 0 else {
            throw CalendarBlockerService.ServiceError.noDuration
        }
        guard isAIAvailable else { throw ClaudeCodeService.ServiceError.notInstalled }

        // Request calendar access if not authorized
        if !calendarService.isAuthorized {
            let granted = await calendarService.requestAccess()
            if !granted {
                throw NSError(
                    domain: "AppViewModel", code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Calendar access is required to suggest time blocks."
                    ])
            }
        }

        // Fetch existing calendar events from now until due date
        let existingEvents = calendarService.fetchEvents(from: Date(), to: dueDate)

        return try await calendarBlockerService.suggestTimeBlocks(
            taskTitle: task.title,
            taskNotes: task.notes,
            estimatedDurationMinutes: duration,
            dueDate: dueDate,
            existingEvents: existingEvents,
            timingPreferences: timingPreferences,
            ai: aiClient
        )
    }

    /// Add time blockers to calendar for a task
    func addTimeBlockers(_ blocks: [ProposedTimeBlock], for task: ProjectTask) async throws {
        guard !blocks.isEmpty else { return }

        if !calendarService.isAuthorized {
            let granted = await calendarService.requestAccess()
            if !granted {
                throw NSError(
                    domain: "AppViewModel", code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Calendar access is required to add time blockers."
                    ])
            }
        }

        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }

        // Delete existing blockers if any
        if !tasks[index].calendarBlockerIDs.isEmpty {
            try? calendarService.deleteEvents(withIDs: tasks[index].calendarBlockerIDs)
            tasks[index].calendarBlockerIDs = []
        }

        // Create new blockers
        let eventIDs = try calendarService.createTimeBlockers(blocks, taskNotes: task.notes)
        tasks[index].calendarBlockerIDs = eventIDs
        projectStore.debouncedSaveTasks(tasks)
    }

    /// Remove calendar blockers for a task
    func removeTimeBlockers(for task: ProjectTask) throws {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }

        if !tasks[index].calendarBlockerIDs.isEmpty {
            try calendarService.deleteEvents(withIDs: tasks[index].calendarBlockerIDs)
            tasks[index].calendarBlockerIDs = []
            projectStore.debouncedSaveTasks(tasks)
        }
    }

    /// Update estimated duration for a task
    func updateTaskEstimatedDuration(_ task: ProjectTask, minutes: Int?) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].estimatedDurationMinutes = minutes
        projectStore.debouncedSaveTasks(tasks)
    }

    // MARK: - Board / Status Management

    /// Create a task pre-assigned to a board column
    func createTaskWithStatus(title: String, projectID: UUID, status: TaskStatus) {
        let task = ProjectTask(
            projectID: projectID,
            title: title,
            dueDate: Self.endOfCurrentWeek,
            hasDueTime: true,
            priority: .medium,
            status: status,
            epicID: nil
        )
        tasks.append(task)
        projectStore.debouncedSaveTasks(tasks)
    }

    /// Update a task's board status, syncing isCompleted/completedAt accordingly
    func updateTaskStatus(_ task: ProjectTask, status: TaskStatus) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].status = status
        if status == .done {
            tasks[index].isCompleted = true
            tasks[index].completedAt = tasks[index].completedAt ?? Date()
        } else {
            tasks[index].isCompleted = false
            tasks[index].completedAt = nil
        }
        projectStore.debouncedSaveTasks(tasks)
    }

    /// Update a task's epic assignment
    func updateTaskEpic(_ task: ProjectTask, epicID: UUID?) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].epicID = epicID
        projectStore.debouncedSaveTasks(tasks)
    }

    /// Update a project's timeline dates
    func updateProjectTimeline(_ project: Project, startDate: Date?, targetDate: Date?) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].startDate = startDate
        projects[index].targetDate = targetDate
        projects[index].updatedAt = Date()
        projectStore.debouncedSaveProjects(projects)
    }

    // MARK: - Epic Management

    func epicsForProject(_ projectID: UUID) -> [Epic] {
        epics.filter { $0.projectID == projectID }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func createEpic(title: String, projectID: UUID, colorHex: String = Project.defaultColors[0], summary: String = "") {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let maxOrder = epics.filter { $0.projectID == projectID }.map(\.sortOrder).max() ?? -1
        let epic = Epic(
            projectID: projectID,
            title: trimmed,
            summary: summary,
            colorHex: colorHex,
            sortOrder: maxOrder + 1
        )
        epics.append(epic)
        projectStore.debouncedSaveEpics(epics)
    }

    func updateEpic(_ epic: Epic) {
        guard let index = epics.firstIndex(where: { $0.id == epic.id }) else { return }
        epics[index] = epic
        projectStore.debouncedSaveEpics(epics)
    }

    func deleteEpic(_ epic: Epic) {
        // Clear epicID from tasks assigned to this epic
        var tasksChanged = false
        for i in tasks.indices where tasks[i].epicID == epic.id {
            tasks[i].epicID = nil
            tasksChanged = true
        }
        if tasksChanged { projectStore.debouncedSaveTasks(tasks) }

        epics.removeAll { $0.id == epic.id }
        projectStore.debouncedSaveEpics(epics)
    }

    func reorderEpics(_ reordered: [Epic]) {
        for epic in reordered {
            if let index = epics.firstIndex(where: { $0.id == epic.id }) {
                epics[index].sortOrder = epic.sortOrder
            }
        }
        projectStore.debouncedSaveEpics(epics)
    }

    // MARK: - AI Todo Extraction

    /// Check if todo extraction is in progress for a session
    func isExtractingTodos(for session: RecordingSession) -> Bool {
        todoExtractionInProgress.contains(session.id)
    }

    /// Check if we can extract todos (same requirements as meeting minutes)
    var canExtractTodos: Bool {
        canGenerateMeetingMinutes
    }

    /// Read the content of a meeting minutes file
    func readMinutesContent(for session: RecordingSession) throws -> String {
        guard let url = minutesURL(for: session) else {
            throw TodoExtractionService.ServiceError.noMinutesContent
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Extract todos from meeting minutes with Claude, like the summary and the title.
    /// `quiet`: no message when nothing new was found (processing runs this on its own; the card's
    /// button reports it). New todos are never announced: they show on the card.
    func extractTodosFromMinutes(for session: RecordingSession, quiet: Bool = false) async {
        guard canExtractTodos else {
            errorMessage = ClaudeCodeService.ServiceError.notInstalled.localizedDescription
            return
        }
        guard session.meetingMinutesFileName != nil else {
            errorMessage = "Generate meeting minutes first before extracting todos."
            return
        }
        if todoExtractionInProgress.contains(session.id) {
            return
        }
        todoExtractionInProgress.insert(session.id)

        do {
            // Read meeting minutes content
            let minutesContent = try readMinutesContent(for: session)

            // Get existing tasks for this session's project (nil = unassigned)
            let existingTasks = session.projectID.map { tasksForProject($0) } ?? []

            // Extract new todos using AI
            let extractedTodos = try await todoExtractionService.extractTodos(
                minutesContent: minutesContent,
                existingTodos: existingTasks,
                ai: aiClient
            )

            // Determine auto-accept: per-project override > global setting
            let autoAccept = shouldAutoAcceptTasks(for: session.projectID)

            // Convert extracted todos to ProjectTask objects
            var newTasks = TodoExtractionService.convertToTasks(
                extractedTodos,
                projectID: autoAccept ? session.projectID : nil,
                sourceSessionID: session.id
            )

            // When not auto-accepting, mark all tasks as needing review
            if !autoAccept {
                for i in newTasks.indices {
                    newTasks[i].needsReview = true
                }
            }

            if newTasks.isEmpty {
                if !quiet { errorMessage = "No new todos found in the meeting minutes." }
            } else {
                tasks.append(contentsOf: newTasks)
                projectStore.debouncedSaveTasks(tasks)
                NSLog("AppViewModel: extracted \(newTasks.count) todo(s) for \(session.id), review: \(!autoAccept)")
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        todoExtractionInProgress.remove(session.id)
    }

    func isExtractingKnowledge(for session: RecordingSession) -> Bool {
        knowledgeExtractionInProgress.contains(session.id)
    }

    /// "Update Knowledge" on a card: the knowledge agent curates this meeting into its workspace.
    func extractKnowledgeFromMinutes(for session: RecordingSession) async {
        curateKnowledge(for: session.id)
    }

    func addKnowledgeEntry(content: String, category: String, projectID: UUID?) async throws {
        guard let knowledgeStore = knowledgeStore else { return }

        // 1. Create Document
        var document = KnowledgeDocument(
            fullContent: content,
            title: "Manual Entry - \(Date().formatted())",
            category: category,
            sourceMeetingID: UUID(),  // Manual entries don't have a source meeting
            sourceMeetingTitle: "Manual Entry",
            projectID: projectID,
            date: Date()
        )

        try knowledgeStore.saveDocument(&document)
        guard let docID = document.id else { return }

        // 2. Chunking (Simple implementation matching migration logic)
        // Ideally this should be a shared service
        let maxChunkSize = 2000
        var chunks: [KnowledgeChunk] = []
        var currentChunk = ""

        let sentences = content.components(separatedBy: ". ")
        var currentIndex = 0
        var currentStart = 0

        // Note: simplified chunking for manual entry to avoid duplication complexity overhead here
        // For production, this should be unified.
        for sentence in sentences {
            let s = sentence + ". "
            if currentChunk.count + s.count > maxChunkSize {
                let chunkText = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)

                chunks.append(
                    KnowledgeChunk(
                        documentID: docID,
                        content: chunkText,
                        chunkIndex: currentIndex,
                        startOffset: currentStart,
                        endOffset: currentStart + chunkText.count,
                        embedding: nil
                    ))
                currentStart += chunkText.count + 1  // rough approx
                currentIndex += 1
                currentChunk = s
            } else {
                currentChunk += s
            }
        }
        if !currentChunk.isEmpty {
            let chunkText = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            chunks.append(
                KnowledgeChunk(
                    documentID: docID,
                    content: chunkText,
                    chunkIndex: currentIndex,
                    startOffset: currentStart,
                    endOffset: currentStart + chunkText.count,
                    embedding: nil
                ))
        }

        try knowledgeStore.saveChunks(chunks, forDocumentID: docID)
    }

    func updateKnowledgeEntry(_ entry: KnowledgeDocument, newContent: String, newCategory: String)
        async throws
    {
        guard let knowledgeStore = knowledgeStore else { return }
        var updatedEntry = entry
        updatedEntry.fullContent = newContent
        updatedEntry.category = newCategory
        try knowledgeStore.saveDocument(&updatedEntry)

        // Re-chunk the updated content
        if let docID = updatedEntry.id {
            let chunks = createKnowledgeChunks(from: newContent, documentID: docID)
            // Save chunks (automatically deletes old chunks first)
            try knowledgeStore.saveChunks(chunks, forDocumentID: docID)
        }
    }
    
    // Helper for chunking knowledge content
    private func createKnowledgeChunks(from content: String, documentID: Int64) -> [KnowledgeChunk] {
        let maxChunkSize = 2000
        var chunks: [KnowledgeChunk] = []
        var currentChunk = ""

        let sentences = content.components(separatedBy: ". ")
        var currentIndex = 0
        var currentStart = 0

        for sentence in sentences {
            let s = sentence + ". "
            if currentChunk.count + s.count > maxChunkSize {
                let chunkText = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
                chunks.append(
                    KnowledgeChunk(
                        documentID: documentID,
                        content: chunkText,
                        chunkIndex: currentIndex,
                        startOffset: currentStart,
                        endOffset: currentStart + chunkText.count,
                        embedding: nil
                    ))
                currentStart += chunkText.count + 1
                currentIndex += 1
                currentChunk = s
            } else {
                currentChunk += s
            }
        }
        if !currentChunk.isEmpty {
            let chunkText = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            chunks.append(
                KnowledgeChunk(
                    documentID: documentID,
                    content: chunkText,
                    chunkIndex: currentIndex,
                    startOffset: currentStart,
                    endOffset: currentStart + chunkText.count,
                    embedding: nil
                ))
        }
        return chunks
    }

    // MARK: - Notes → Knowledge Base Embedding

    /// Embeds or re-embeds a note into the knowledge base.
    /// Finds existing KB document by sourceNoteID; if found, updates it (deletes old chunks, re-chunks, re-embeds).
    /// If not found, creates a new document.
    private func embedNoteInKnowledgeBase(_ note: EventNote) async {
        guard let knowledgeStore else { return }
        let content = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            // If content is empty, remove the KB doc if one exists
            if let existing = try? knowledgeStore.fetchDocument(byNoteID: note.id),
               let docID = existing.id {
                try? knowledgeStore.deleteDocument(id: docID)
            }
            return
        }

        do {
            if var existing = try knowledgeStore.fetchDocument(byNoteID: note.id) {
                // Update existing document
                existing.fullContent = content
                existing.title = note.eventTitle
                existing.projectID = note.projectId
                existing.date = note.updatedAt
                try knowledgeStore.saveDocument(&existing)

                if let docID = existing.id {
                    let chunks = createKnowledgeChunks(from: content, documentID: docID)
                    try knowledgeStore.saveChunks(chunks, forDocumentID: docID)
                }
            } else {
                // Create new document
                var document = KnowledgeDocument(
                    fullContent: content,
                    title: note.eventTitle,
                    category: "Note",
                    sourceMeetingID: UUID(),
                    sourceMeetingTitle: note.isManual ? "Manual Note" : "Calendar Note",
                    projectID: note.projectId,
                    date: note.updatedAt,
                    sourceNoteID: note.id
                )
                try knowledgeStore.saveDocument(&document)

                if let docID = document.id {
                    let chunks = createKnowledgeChunks(from: content, documentID: docID)
                    try knowledgeStore.saveChunks(chunks, forDocumentID: docID)
                }
            }
        } catch {
            print("Failed to embed note in KB: \(error.localizedDescription)")
        }
    }

    // MARK: - Knowledge Base

    /// Rebuilds the search index from the workspaces' knowledge files (the files are the source;
    /// notes are indexed separately and stay). Settings, Storage, Search Index.
    func rebuildKnowledgeBase() async {
        await reindexAllWorkspaceKnowledge()
    }
}
