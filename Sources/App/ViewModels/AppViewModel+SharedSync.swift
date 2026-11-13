// Purpose: Wires SharedProjectSync into the app: starts the periodic sync of Shared Projects,
//          syncs after mirror commits and publishing, runs shared knowledge curation as a replay
//          in the clean worktree, merges conflicted text with the chosen Claude model, lets a
//          held back large file sync anyway, and reindexes knowledge after a pull.
// Dependencies: Sources/App/Services/SharedProjectSyncService.swift,
//               Sources/App/Services/KnowledgeCurationService.swift (sharedReplay, runStep),
//               Sources/App/Services/ProjectRepositoryService.swift (repos),
//               Sources/App/ViewModels/AppViewModel+WorkspaceKnowledge.swift (reindex)
// RBAC: None.
// Dependents: Sources/App/ViewModels/AppViewModel.swift (setupSharedSync at launch,
//             mirrorMeetingToWorkspace), AppViewModel+SharedPublishing.swift,
//             Sources/App/Views/WorkspaceGitBranchBar (Sync Now)
// Notes: The periodic loop does not run in test processes. The clean worktrees for shared
//        knowledge live in <Application Support>/MinuteMind/SharedCuration/<project id>/, next to
//        Workspaces/ and outside every workspace.

import Foundation

extension AppViewModel {
    /// Connects the sync to the curator and the knowledge index and starts the periodic sync.
    /// Called once at launch.
    func setupSharedSync() {
        let curator = knowledgeCurator
        let sync = sharedSync
        let curationRoot = projectRepositories.rootDirectory.deletingLastPathComponent()
            .appendingPathComponent("SharedCuration", isDirectory: true)
        sync.worktreeDirectory = { projectID in curationRoot.appendingPathComponent(projectID.uuidString, isDirectory: true) }
        sync.onPulled = { [weak self] _, repo in
            guard let self else { return }
            Task { await self.reindexWorkspaceKnowledge(repo: repo) }
        }
        sync.mergeText = { [weak self] merge in
            try await SharedTextMerger.mergeWithClaude(merge, model: self?.automationSettings.claudeModel ?? "sonnet")
        }
        curator.sharedReplay = { [weak self] repo, step, title in
            guard let self, let projectID = UUID(uuidString: repo.lastPathComponent) else { return }
            let message: String
            switch step {
            case .retract: message = "Knowledge: remove \(title)"
            default: message = "Knowledge: \(title)"
            }
            let pushed = await sync.replayKnowledge(projectID, repo: repo, message: message) { worktree in
                _ = try await curator.runStep(step, in: worktree)
            }
            if pushed { await self.reindexWorkspaceKnowledge(repo: repo) }
        }
        guard !Self.isTestProcess else { return }
        sync.start { [weak self] in self?.sharedRepositories() ?? [] }
    }

    /// Every Shared Project with its repo (created and prepared if needed).
    func sharedRepositories() -> [(projectID: UUID, repo: URL)] {
        projects.filter(\.isShared).map { ($0.id, projectRepositories.ensureRepository(for: $0)) }
    }

    /// Fetches, rebases and pushes one Shared Project now ("Sync now" in the branch row).
    func syncSharedProjectNow(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }), project.isShared else { return }
        sharedSync.requestSync(projectID, repo: projectRepositories.ensureRepository(for: project))
    }

    /// Sync anyway for a held back file: remembers the path on this Mac and syncs now.
    func syncLargeFileAnyway(_ path: String, in projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }), project.isShared else { return }
        let repo = projectRepositories.ensureRepository(for: project)
        SharedLargeFiles.allow(path, in: repo)
        sharedSync.requestSync(projectID, repo: repo)
    }
}
