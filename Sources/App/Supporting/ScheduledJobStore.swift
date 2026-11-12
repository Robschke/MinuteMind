// Purpose: ScheduledJobStore, the app's state for scheduled jobs: the jobs of every workspace, the
//          scheduler loop that finds due slots, the queue that runs one job at a time, autosave
//          with delayed git commits, and the run history the Jobs tab and MCP read.
// Dependencies: Sources/App/Store/ScheduledJobFiles.swift (files), Sources/App/Services/ScheduledJobRunner.swift
//               (Claude run), Sources/App/Models/ScheduledJob.swift, Sources/App/Models/JobSchedule.swift,
//               Sources/App/Services/ProjectRepositoryService.swift (git)
// RBAC: None here; each job's access level is applied by ScheduledJobRunner.
// Dependents: Sources/App/ViewModels/AppViewModel+ScheduledJobs.swift (wiring, notifications,
//             navigation), Sources/App/Services/MCP/MCPJobTools.swift, Sources/App/Views/ScheduledJobsView.swift
// Notes: The job files are the source of truth; this store mirrors them and rereads them on every
//        tick (30 s) and on wake, so edits Claude makes in the terminal show up and run as written.
//        A job with an unsaved edit keeps its in-memory copy until the write lands.
//        Runs execute one at a time across all workspaces (a run can take minutes and the machine
//        is shared). A due slot is recorded as handled when it is queued, so a long run never gets
//        queued twice. A slot older than five minutes runs as a catch-up.
//        UI edits are written after 0.6 s and committed after 4 s of quiet; edits over MCP are
//        written and committed at once. Commits only touch jobs/. Files Claude changes during a
//        run are left uncommitted, like any change made in the workspace.

import AppKit
import Foundation
import Observation

/// A job in a workspace.
struct ScheduledJobKey: Hashable, Sendable {
    let projectID: UUID
    let jobID: String
}

@MainActor
@Observable
final class ScheduledJobStore {
    struct QueuedRun: Equatable {
        let key: ScheduledJobKey
        let trigger: ScheduledJobRun.Trigger
        let slot: Date?
    }

    struct RunningJob: Equatable {
        let key: ScheduledJobKey
        let started: Date
    }

    // MARK: - Wiring (set by AppViewModel)

    /// The repo of a workspace, created if needed.
    @ObservationIgnored var repoURL: (UUID) -> URL = { _ in FileManager.default.temporaryDirectory }
    /// Existing workspace repos with their project id.
    @ObservationIgnored var repositories: () -> [(projectID: UUID, repo: URL)] = { [] }
    /// The workspace's display name, nil when the project no longer exists (its jobs never run).
    @ObservationIgnored var workspaceName: (UUID) -> String? = { _ in nil }
    /// Settings, AI: the model for jobs without their own.
    @ObservationIgnored var defaultModel: () -> String = { "sonnet" }
    /// MinuteMind's MCP config for Claude, nil while the server is off.
    @ObservationIgnored var mcpConfig: () -> URL? = { nil }
    /// The MCP server's tool names (without the mcp__ prefix).
    @ObservationIgnored var minuteMindTools: () -> [String] = { [] }
    /// Called after every run with the job as it ran.
    @ObservationIgnored var onRunFinished: (UUID, ScheduledJob, ScheduledJobRun) -> Void = { _, _, _ in }

    // MARK: - State

    private(set) var jobsByProject: [UUID: [ScheduledJob]] = [:]
    private(set) var running: RunningJob?
    private(set) var queue: [QueuedRun] = []
    /// The newest run of each job, for list rows.
    private(set) var latestRuns: [ScheduledJobKey: ScheduledJobRun] = [:]
    /// Bumped whenever a run file is written, so views reload their run lists.
    private(set) var runsRevision = 0

    @ObservationIgnored private var lastScheduled: [ScheduledJobKey: Date] = [:]
    @ObservationIgnored private var pendingWrites: [ScheduledJobKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingCommits: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    // MARK: - Scheduler

    /// Starts the 30 s scheduler loop and the wake check. The first tick catches up missed slots.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Rereads every workspace's jobs and queues the due ones.
    func tick(now: Date = Date()) {
        for (projectID, repo) in repositories() where workspaceName(projectID) != nil {
            reloadFromDisk(projectID, repo: repo)
            // A job without a prompt has nothing to run yet (a fresh "New Job").
            for job in jobsByProject[projectID] ?? []
            where job.enabled && !job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let key = ScheduledJobKey(projectID: projectID, jobID: job.id)
                let last = lastScheduled[key] ?? ScheduledJobFiles.lastScheduledSlot(job.id, in: repo)
                if let last { lastScheduled[key] = last }
                guard let slot = job.schedule.dueSlot(now: now, activeSince: job.activeSince, lastScheduled: last) else { continue }
                lastScheduled[key] = slot
                let trigger: ScheduledJobRun.Trigger = now.timeIntervalSince(slot) > 5 * 60 ? .catchUp : .schedule
                enqueue(QueuedRun(key: key, trigger: trigger, slot: slot))
            }
        }
    }

    // MARK: - Reading

    /// The jobs as last read; views call `reload` when they appear, so this never touches disk
    /// while SwiftUI evaluates a body.
    func jobs(for projectID: UUID) -> [ScheduledJob] {
        jobsByProject[projectID] ?? []
    }

    func job(_ key: ScheduledJobKey) -> ScheduledJob? {
        jobs(for: key.projectID).first { $0.id == key.jobID }
    }

    /// Rereads one workspace's job files (the Jobs tab calls this when it appears).
    func reload(_ projectID: UUID) {
        reloadFromDisk(projectID, repo: repoURL(projectID))
    }

    private func reloadFromDisk(_ projectID: UUID, repo: URL) {
        var loaded = ScheduledJobFiles.loadJobs(in: repo)
        // Unsaved edits win over the file until they are written.
        let current = jobsByProject[projectID] ?? []
        for (index, job) in loaded.enumerated() {
            let key = ScheduledJobKey(projectID: projectID, jobID: job.id)
            if pendingWrites[key] != nil, let mine = current.first(where: { $0.id == job.id }) { loaded[index] = mine }
        }
        for job in current where pendingWrites[ScheduledJobKey(projectID: projectID, jobID: job.id)] != nil
            && !loaded.contains(where: { $0.id == job.id }) {
            loaded.append(job)
        }
        loaded.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if jobsByProject[projectID] != loaded { jobsByProject[projectID] = loaded }
        for job in loaded {
            let key = ScheduledJobKey(projectID: projectID, jobID: job.id)
            if latestRuns[key] == nil, let id = ScheduledJobFiles.runIDs(job.id, in: repo).first,
               let run = ScheduledJobFiles.loadRun(id, jobID: job.id, in: repo) {
                latestRuns[key] = run
            }
        }
    }

    func runs(_ key: ScheduledJobKey, limit: Int = 100) -> [ScheduledJobRun] {
        ScheduledJobFiles.loadRuns(key.jobID, in: repoURL(key.projectID), limit: limit)
    }

    func run(_ key: ScheduledJobKey, runID: String) -> ScheduledJobRun? {
        ScheduledJobFiles.loadRun(runID, jobID: key.jobID, in: repoURL(key.projectID))
    }

    func runFileURL(_ key: ScheduledJobKey, runID: String) -> URL {
        ScheduledJobFiles.runFile(runID, jobID: key.jobID, in: repoURL(key.projectID))
    }

    /// When the job runs next (nil when it is off).
    func nextRun(of job: ScheduledJob, now: Date = Date()) -> Date? {
        guard job.enabled else { return nil }
        return job.schedule.nextSlot(after: max(now, job.activeSince))
    }

    func isRunning(_ key: ScheduledJobKey) -> Bool { running?.key == key }
    func isQueued(_ key: ScheduledJobKey) -> Bool { queue.contains { $0.key == key } }

    // MARK: - Changing

    /// Creates a job with a slug from its title and saves it at once.
    @discardableResult
    func create(
        in projectID: UUID, title: String, prompt: String, configure: (inout ScheduledJob) -> Void = { _ in }
    ) throws -> ScheduledJob {
        let repo = repoURL(projectID)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var job = ScheduledJob(id: ScheduledJobFiles.uniqueSlug(for: name, in: repo), title: name.isEmpty ? "New Job" : name, prompt: prompt)
        configure(&job)
        let now = Date()
        job.created = now
        job.activeSince = now
        try ScheduledJobFiles.save(job, in: repo)
        jobsByProject[projectID] = ((jobsByProject[projectID] ?? []) + [job])
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        commit(projectID, message: "Jobs: create \(job.title)")
        return job
    }

    /// Stores an edited job. `immediately` writes and commits now (MCP); otherwise the write and
    /// the commit wait for a pause in typing (the Jobs tab's autosave).
    func update(in projectID: UUID, _ edited: ScheduledJob, immediately: Bool = false) {
        var job = edited
        let key = ScheduledJobKey(projectID: projectID, jobID: job.id)
        var list = jobsByProject[projectID] ?? []
        guard let index = list.firstIndex(where: { $0.id == job.id }) else { return }
        let old = list[index]
        // A new schedule or switching on starts fresh: no slot that already passed fires.
        if old.schedule != job.schedule || (!old.enabled && job.enabled) { job.activeSince = Date() }
        guard job != old else { return }
        list[index] = job
        jobsByProject[projectID] = list
        lastScheduled[key] = nil

        pendingWrites[key]?.cancel()
        if immediately {
            pendingWrites[key] = nil
            write(job, projectID: projectID)
            commit(projectID, message: "Jobs: update \(job.title)")
        } else {
            pendingWrites[key] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self else { return }
                self.pendingWrites[key] = nil
                self.write(job, projectID: projectID)
                self.scheduleCommit(projectID, message: "Jobs: update \(job.title)")
            }
        }
    }

    /// Writes pending edits now (leaving the tab, quitting).
    func flushPendingWrites() {
        for (key, task) in pendingWrites {
            task.cancel()
            if let job = jobsByProject[key.projectID]?.first(where: { $0.id == key.jobID }) {
                write(job, projectID: key.projectID)
                commit(key.projectID, message: "Jobs: update \(job.title)")
            }
        }
        pendingWrites = [:]
    }

    /// Removes the job and its runs (git keeps both in its history).
    func delete(_ key: ScheduledJobKey) {
        pendingWrites[key]?.cancel()
        pendingWrites[key] = nil
        queue.removeAll { $0.key == key }
        if running?.key == key { runTask?.cancel() }
        let title = job(key)?.title ?? key.jobID
        ScheduledJobFiles.delete(key.jobID, in: repoURL(key.projectID))
        jobsByProject[key.projectID]?.removeAll { $0.id == key.jobID }
        latestRuns[key] = nil
        lastScheduled[key] = nil
        commit(key.projectID, message: "Jobs: delete \(title)")
    }

    private func write(_ job: ScheduledJob, projectID: UUID) {
        do {
            try ScheduledJobFiles.save(job, in: repoURL(projectID))
        } catch {
            NSLog("ScheduledJobStore: saving \(job.id) failed: \(error.localizedDescription)")
        }
    }

    private func scheduleCommit(_ projectID: UUID, message: String) {
        pendingCommits[projectID]?.cancel()
        pendingCommits[projectID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.pendingCommits[projectID] = nil
            self.commit(projectID, message: message)
        }
    }

    private func commit(_ projectID: UUID, message: String) {
        let repo = repoURL(projectID)
        ProjectRepositoryService.git(["add", "-A", "--", ScheduledJobFiles.folderName], in: repo)
        ProjectRepositoryService.git(["commit", "-q", "-m", message, "--", ScheduledJobFiles.folderName], in: repo)
    }

    // MARK: - Running

    /// Queues a manual run. Returns false when the job does not exist or already waits.
    @discardableResult
    func runNow(_ key: ScheduledJobKey) -> Bool {
        guard job(key) != nil, !isQueued(key) else { return false }
        enqueue(QueuedRun(key: key, trigger: .manual, slot: nil))
        return true
    }

    /// Stops the job's running run, or takes it out of the queue.
    func cancel(_ key: ScheduledJobKey) {
        queue.removeAll { $0.key == key }
        if running?.key == key { runTask?.cancel() }
    }

    private func enqueue(_ item: QueuedRun) {
        guard !queue.contains(where: { $0.key == item.key }) else { return }
        queue.append(item)
        drain()
    }

    private func drain() {
        guard running == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        let projectID = item.key.projectID
        let repo = repoURL(projectID)
        // The file may have changed since it was queued.
        reloadFromDisk(projectID, repo: repo)
        guard let job = jobsByProject[projectID]?.first(where: { $0.id == item.key.jobID }),
              item.trigger == .manual || job.enabled,
              let name = workspaceName(projectID)
        else {
            drain()
            return
        }
        let started = Date()
        running = RunningJob(key: item.key, started: started)
        let model = job.model ?? defaultModel()
        let prompt = ScheduledJobRunner.systemPrompt(
            job: job, workspaceName: name, projectID: projectID,
            isGeneral: projectID == ProjectRepositoryService.generalProjectID, now: started)
        let config = mcpConfig()
        let tools = minuteMindTools()
        runTask = Task { [weak self] in
            let result = await ScheduledJobRunner.execute(
                job: job, repo: repo, model: model, systemPrompt: prompt, mcpConfig: config, minuteMindTools: tools)
            self?.finish(item, job: job, repo: repo, started: started, model: model, result: result)
        }
    }

    private func finish(
        _ item: QueuedRun, job: ScheduledJob, repo: URL, started: Date, model: String,
        result: (status: ScheduledJobRun.Status, output: String)
    ) {
        let run = ScheduledJobRun(
            id: ScheduledJobFiles.newRunID(started: started, jobID: job.id, in: repo), jobID: job.id,
            status: result.status, trigger: item.trigger, scheduled: item.slot, started: started, finished: Date(),
            model: model, access: job.access, output: result.output)
        // A job deleted while it ran leaves no run behind.
        if FileManager.default.fileExists(atPath: ScheduledJobFiles.jobFile(job.id, in: repo).path) {
            do {
                try ScheduledJobFiles.writeRun(run, in: repo)
                commit(item.key.projectID, message: "Job run: \(job.title) (\(run.status.rawValue))")
            } catch {
                NSLog("ScheduledJobStore: saving the run of \(job.id) failed: \(error.localizedDescription)")
            }
            latestRuns[item.key] = run
            runsRevision += 1
            onRunFinished(item.key.projectID, job, run)
        }
        running = nil
        runTask = nil
        drain()
    }
}
