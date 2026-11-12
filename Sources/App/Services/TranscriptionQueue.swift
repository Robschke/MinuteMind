// Purpose: Serial transcription queue — enqueues transcription jobs and processes them one at a time.
//          Prevents concurrent transcriptions from overwriting shared state and provides UI-observable
//          queue status via @Published properties.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (weak reference for executing transcriptions)
// Used by: Sources/App/ViewModels/AppViewModel.swift (transcriptionQueue property)
// Notes: @MainActor ObservableObject (not an actor) so SwiftUI can bind to @Published properties.
//        Serial processing avoids GPU/CPU contention, especially with on-device Parakeet.

import Foundation

@MainActor
final class TranscriptionQueue: ObservableObject {

    // MARK: - Types

    enum TranscriptionModel: Equatable {
        case appleSpeech(language: String?)
        case parakeet(language: String?)
    }

    struct Job: Identifiable {
        let id = UUID()
        let sessionID: UUID
        let sessionTitle: String
        let model: TranscriptionModel
        var status: JobStatus = .pending
    }

    enum JobStatus: Equatable {
        case pending
        case running
        case completed
        case cancelled
        case failed(String)
    }

    // MARK: - Published State

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var currentJob: Job? = nil

    var pendingCount: Int { jobs.filter { $0.status == .pending }.count }
    var isProcessing: Bool { currentJob != nil }
    /// Total queued + in-progress count for UI badges.
    var activeCount: Int { pendingCount + (isProcessing ? 1 : 0) }

    // MARK: - Internal

    private weak var appViewModel: AppViewModel?
    private var processingTask: Task<Void, Never>?

    func setAppViewModel(_ vm: AppViewModel) {
        self.appViewModel = vm
    }

    // MARK: - Public API

    func enqueue(sessionID: UUID, title: String, model: TranscriptionModel) {
        // Don't enqueue duplicates for the same session.
        guard !jobs.contains(where: { $0.sessionID == sessionID && ($0.status == .pending || $0.status == .running) }) else {
            NSLog("TranscriptionQueue: Skipping duplicate enqueue for session \(sessionID)")
            return
        }

        let job = Job(sessionID: sessionID, sessionTitle: title, model: model)
        jobs.append(job)
        NSLog("TranscriptionQueue: Enqueued '\(title)' (\(sessionID)) — \(pendingCount) pending")

        // Mark the session as queued so the UI can reflect it.
        appViewModel?.markSessionQueued(sessionID: sessionID)

        processNextIfIdle()
    }

    func cancel(jobID: UUID) {
        if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            let job = jobs[idx]
            if job.status == .pending {
                jobs.remove(at: idx)
                NSLog("TranscriptionQueue: Cancelled pending job for '\(job.sessionTitle)'")
            }
        }
    }

    func cancelAll() {
        jobs.removeAll { $0.status == .pending }
        NSLog("TranscriptionQueue: Cancelled all pending jobs")
    }

    /// Cancel the currently running transcription job. The underlying Task is cancelled,
    /// which causes the transcription service to throw `TranscriptionInterruptedError`
    /// with any partial text already transcribed.
    func cancelCurrentJob() {
        guard let job = currentJob else { return }
        NSLog("TranscriptionQueue: Stopping current job '\(job.sessionTitle)'")
        processingTask?.cancel()
    }

    // MARK: - Processing

    private func processNextIfIdle() {
        guard currentJob == nil else { return }
        guard let idx = jobs.firstIndex(where: { $0.status == .pending }) else { return }

        jobs[idx].status = .running
        currentJob = jobs[idx]
        let job = jobs[idx]

        processingTask = Task { [weak self] in
            await self?.execute(job)
        }
    }

    private func execute(_ job: Job) async {
        guard let vm = appViewModel else {
            markJobCompleted(job.id, error: "AppViewModel unavailable")
            return
        }

        NSLog("TranscriptionQueue: Processing '\(job.sessionTitle)' with \(job.model)")

        switch job.model {
        case .appleSpeech(let language):
            let lang = language.flatMap { AppViewModel.LanguageOption(rawValue: $0) }
            await vm.transcribe(sessionID: job.sessionID, language: lang)
        case .parakeet(let language):
            let lang = language.flatMap { AppViewModel.LanguageOption(rawValue: $0) } ?? .auto
            await vm.transcribeWithParakeet(sessionID: job.sessionID, language: lang)
        }

        // Check session status to determine outcome.
        let session = vm.sessions.first(where: { $0.id == job.sessionID })
        let status = session?.status

        if status == .completed {
            // Completed (possibly with partial results from an interrupted transcription)
            let wasPartial = session?.lastErrorMessage?.contains("stopped early") == true
            if wasPartial {
                markJobCancelled(job.id)
            } else {
                markJobCompleted(job.id, error: nil)
            }

            // Run full processing only for complete (non-partial) transcriptions: when the user
            // pressed Process while this job waited, or when the recording has a project, picked
            // before or during the transcription (MeetingProcessingRule). Otherwise it waits for one.
            // The cleanup starts now in the background, so Process later is mostly the summary.
            if !wasPartial { vm.startEarlyCleanup(job.sessionID) }
            let processRequested = vm.takeProcessRequest(for: job.sessionID)
            if !wasPartial && (processRequested || vm.shouldProcessAfterTranscription(job.sessionID)) {
                NSLog("TranscriptionQueue: Running post-transcription processing for '\(job.sessionTitle)'")
                await vm.runMeetingProcessing(sessionID: job.sessionID)
            }
            // A quick recording with a project lands in its workspace as soon as it has words.
            vm.mirrorToWorkspaceIfReady(job.sessionID)
        } else if status == .recorded {
            // Session was reset to recorded — user stopped with no partial results
            markJobCancelled(job.id)
        } else {
            let errorMsg = session?.lastErrorMessage ?? "Unknown error"
            markJobCompleted(job.id, error: errorMsg)
        }
    }

    private func markJobCancelled(_ jobID: UUID) {
        if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[idx].status = .cancelled
            NSLog("TranscriptionQueue: Job cancelled — '\(jobs[idx].sessionTitle)'")
        }
        currentJob = nil
        processNextIfIdle()
    }

    private func markJobCompleted(_ jobID: UUID, error: String?) {
        if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
            if let error {
                jobs[idx].status = .failed(error)
                NSLog("TranscriptionQueue: Job failed — \(error)")
            } else {
                jobs[idx].status = .completed
            }
        }
        currentJob = nil

        // Clean up finished jobs, keeping the last 10 for UI display.
        let finishedCount = jobs.filter { $0.status != .pending && $0.status != .running }.count
        if finishedCount > 10 {
            jobs.removeAll { $0.status == .completed || $0.status == .cancelled }
        }

        processNextIfIdle()
    }

    /// Post-transcription pipeline: minutes, then title and todos side by side. Mirrors AutomationCoordinator.runAutoPipeline.
    func runPostTranscriptionPipeline(sessionID: UUID, vm: AppViewModel) async {
        guard let session = vm.sessions.first(where: { $0.id == sessionID }),
              session.status == .completed, session.transcript != nil else {
            NSLog("TranscriptionQueue: Pipeline skipped — transcription incomplete for \(sessionID)")
            return
        }

        NSLog("TranscriptionQueue: Auto-generating meeting minutes for \(sessionID)")
        await vm.generateMeetingMinutes(for: session)

        guard let updated = vm.sessions.first(where: { $0.id == sessionID }),
              updated.meetingMinutesFileName != nil else {
            NSLog("TranscriptionQueue: Meeting minutes missing — skipping title + todo extraction")
            return
        }

        // Title and todos both read only the summary: side by side.
        NSLog("TranscriptionQueue: Auto-generating title and todos for \(sessionID)")
        async let title: Void = vm.generateSessionTitle(for: sessionID)
        async let todos: Void = vm.extractTodosFromMinutes(for: updated, quiet: true)
        _ = await (title, todos)
    }
}
