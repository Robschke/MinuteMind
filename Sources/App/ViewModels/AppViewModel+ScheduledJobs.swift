// Purpose: AppViewModel+ScheduledJobs, wires the scheduled jobs into the app: the store's access to
//          workspaces, models and the MCP server, the notification after a run, and the way to a
//          job or run in the Jobs tab (from a notification or the run's "Open in Workspace").
// Dependencies: Sources/App/Supporting/ScheduledJobStore.swift, Sources/App/Services/ProjectRepositoryService.swift,
//               Sources/App/Services/MCP/MinuteMindMCPServer.swift (tool names),
//               Sources/App/Supporting/WorkspaceEditorStore.swift (opening a run file)
// RBAC: None.
// Dependents: Sources/App/ViewModels/AppViewModel.swift (setup at launch, notification clicks),
//             Sources/App/Views/ScheduledJobsView.swift, Sources/App/Views/ProjectDetailView.swift,
//             Sources/App/Views/GeneralWorkspaceView.swift, Sources/App/Services/MCP/MCPJobTools.swift
// Notes: Jobs belong to workspaces: every project and the General workspace. A workspace whose
//        project was deleted keeps its files but its jobs never run (workspaceName is nil).
//        Notifications follow each job's own setting (every run, failures, never).

import AppKit
import Foundation
import UserNotifications

/// A job, and optionally one of its runs, to show in the Jobs tab.
struct ScheduledJobRunReference: Equatable {
    let projectID: UUID
    let jobID: String
    let runID: String?
}

extension AppViewModel {
    static let jobRunNotificationCategory = "mm.jobRun"

    /// The workspace's name for jobs: the project's, "General", or nil for a deleted project.
    func scheduledJobWorkspaceName(_ projectID: UUID) -> String? {
        if projectID == ProjectRepositoryService.generalProjectID { return ProjectRepositoryService.generalProject.name }
        return projects.first { $0.id == projectID }?.name
    }

    private func scheduledJobProject(_ projectID: UUID) -> Project? {
        if projectID == ProjectRepositoryService.generalProjectID { return ProjectRepositoryService.generalProject }
        return projects.first { $0.id == projectID }
    }

    /// Connects the store and starts its scheduler. Called once at launch; the scheduler does
    /// not run in test processes.
    func setupScheduledJobs() {
        let store = scheduledJobs
        store.repoURL = { [weak self] projectID in
            guard let self else { return FileManager.default.temporaryDirectory }
            if let project = self.scheduledJobProject(projectID) {
                return self.projectRepositories.ensureRepository(for: project)
            }
            return self.projectRepositories.repoURL(for: projectID)
        }
        store.repositories = { [weak self] in self?.projectRepositories.existingRepositories() ?? [] }
        store.workspaceName = { [weak self] in self?.scheduledJobWorkspaceName($0) }
        store.defaultModel = { [weak self] in self?.automationSettings.claudeModel ?? "sonnet" }
        store.mcpConfig = { [weak self] in self?.assistantMCPConfig() }
        store.minuteMindTools = { MinuteMindMCPServer.exposedToolNames() }
        store.onRunFinished = { [weak self] projectID, job, run in
            guard let self else { return }
            Task { await self.notifyJobRun(projectID: projectID, job: job, run: run) }
        }
        guard !Self.isTestProcess else { return }
        store.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak store] _ in
            MainActor.assumeIsolated { store?.flushPendingWrites() }
        }
    }

    // MARK: - Navigation

    /// Shows the Jobs tab of the job's workspace, with the run open when one is given.
    func openScheduledJob(_ reference: ScheduledJobRunReference) {
        NSApp.activate(ignoringOtherApps: true)
        isShowingInbox = false
        isShowingClipboard = false
        isShowingAllTasks = false
        isShowingCalendar = false
        selectedProjectID = reference.projectID
        requestedProjectTab = .jobs
        requestedJobRun = reference
    }

    /// Opens a run's Markdown file in the workspace editor and switches to the Workspace tab.
    func openJobRunInWorkspace(_ key: ScheduledJobKey, runID: String) {
        let url = scheduledJobs.runFileURL(key, runID: runID)
        _ = workspaceEditors.state(for: key.projectID).open(url)
        selectedProjectID = key.projectID
        requestedProjectTab = .workspaces
    }

    func openJobRun(fromNotification userInfo: [String: String]) {
        guard let raw = userInfo["projectID"], let projectID = UUID(uuidString: raw), let jobID = userInfo["jobID"] else { return }
        openScheduledJob(ScheduledJobRunReference(projectID: projectID, jobID: jobID, runID: userInfo["runID"]))
    }

    // MARK: - Notifications

    private func notifyJobRun(projectID: UUID, job: ScheduledJob, run: ScheduledJobRun) async {
        switch job.notify {
        case .never: return
        case .failures where run.status != .failed: return
        default: break
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        switch run.status {
        case .succeeded: content.title = job.title
        case .failed: content.title = "\(job.title) failed"
        case .cancelled: content.title = "\(job.title) stopped"
        }
        if let name = scheduledJobWorkspaceName(projectID) { content.subtitle = name }
        content.body = run.headline.isEmpty ? "Finished." : String(run.headline.prefix(180))
        content.sound = run.status == .failed ? .default : nil
        content.categoryIdentifier = Self.jobRunNotificationCategory
        content.userInfo = ["projectID": projectID.uuidString, "jobID": job.id, "runID": run.id]
        let request = UNNotificationRequest(identifier: "mm.jobRun.\(projectID.uuidString).\(job.id).\(run.id)", content: content, trigger: nil)
        try? await center.add(request)
    }
}
