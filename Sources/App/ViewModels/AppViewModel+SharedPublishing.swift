// Purpose: Publishing in Shared Projects: whether a project is shared, recording the publish
//          choice of a meeting or quick recording, and publishing a private item later. Publishing
//          moves the item's folder from private/ to meetings/ or recordings/ (with the contributor's
//          name), takes its facts out of private/knowledge/ and curates it into the shared
//          knowledge/.
// Dependencies: Sources/App/Models/SharedProject.swift,
//               Sources/App/Services/ProjectRepositoryService.swift (mirroring, moving folders),
//               Sources/App/ViewModels/AppViewModel+WorkspaceKnowledge.swift (curation routing),
//               Sources/App/ViewModels/AppViewModel+SharedSync.swift (sync after publishing)
// RBAC: None.
// Dependents: the pill's saved card (MeetingPillController), the workspace file tree's
//             Publish action (WorkspaceFileOutlineView), Tests/SharedProjectBackendTests.swift.
// Notes: Publishing is one-way: once pushed, the content is in the other members' clones, so a
//        published session never goes back to private here. The choice is written onto the
//        stored session in place (never a stale copy written back whole).
//        A folder under private/ that no session of this Mac owns (made by hand, or the session
//        is gone) is still moved, with the name suffix, and curated when it has a summary.md.

import Foundation

extension AppViewModel {
    /// True when the project with this id is a Shared Project.
    func isSharedProject(_ projectID: UUID?) -> Bool {
        guard let projectID else { return false }
        return projects.first { $0.id == projectID }?.isShared ?? false
    }

    /// Records the publish choice for a session (saved card: Publish / Keep private) and mirrors
    /// it into the matching folder. A published session stays published.
    func setPublication(_ publication: MeetingPublication, for sessionID: UUID) {
        guard let current = sessions.first(where: { $0.id == sessionID }),
              current.publication != .published, current.publication != publication else { return }
        storePublication(publication, for: sessionID)
        guard publication == .published, let session = sessions.first(where: { $0.id == sessionID }),
              let project = workspaceProject(for: session), project.isShared else { return }
        publishMirroredItem(sessionID, in: project)
    }

    /// Publishes an item that sits under private/ (file tree: right click, Publish). The path is
    /// relative to the repo root, e.g. "private/meetings/2026-11-12-weekly". Returns false when
    /// the path is not a publishable meeting or recording folder.
    @discardableResult
    func publishPrivateItem(relativePath: String, projectID: UUID) async -> Bool {
        guard let project = projects.first(where: { $0.id == projectID }), project.isShared,
              let item = ProjectRepositoryService.privateItem(relativePath) else { return false }
        let repo = projectRepositories.ensureRepository(for: project)
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(relativePath).path) else { return false }

        if let id = projectRepositories.sessionID(forMirroredFolder: relativePath, in: repo),
           let session = sessions.first(where: { $0.id == id }),
           workspaceProject(for: session)?.id == projectID,
           session.isQuickRecording == (item.kind == "recordings") {
            projectRepositories.adoptMirroredFolder(relativePath, sessionID: id, in: repo)
            if session.publication == .published {
                publishMirroredItem(id, in: project)
            } else {
                setPublication(.published, for: id)
            }
            guard let folder = projectRepositories.mirroredFolder(for: session, in: project) else { return false }
            return !SharedProjectLayout.isPrivate(folder)
        }

        // No session of this Mac owns the folder: move it as it is.
        guard let published = projectRepositories.publishFolder(relativePath, in: project) else { return false }
        if privateKnowledgeCites(relativePath, in: repo) {
            retractKnowledge(ofItemAt: relativePath, title: item.name, in: project)
        }
        if FileManager.default.fileExists(atPath: repo.appendingPathComponent("\(published)/summary.md").path) {
            knowledgeCurator.enqueue(.shared(repo: repo, step: .curate(meetingFolder: published), title: item.name, sessionID: nil))
        } else {
            sharedSync.requestSync(projectID, repo: repo)
        }
        return true
    }

    /// Moves a published session's mirrored folder out of private/ (mirroring follows the
    /// session's area), retracts it from private/knowledge/ when that cites it, and curates it
    /// into the shared knowledge. The mirror commit triggers the sync.
    private func publishMirroredItem(_ sessionID: UUID, in project: Project) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let repo = projectRepositories.repoURL(for: project.id)
        let oldFolder = projectRepositories.mirroredFolder(for: session, in: project)
        mirrorToWorkspaceIfReady(sessionID)
        guard session.meetingMinutesFileName != nil else { return }
        // A private curation still waiting would cite a folder that is gone.
        knowledgeCurator.cancelPending(sessionID: sessionID)
        if let oldFolder, SharedProjectLayout.isPrivate(oldFolder), privateKnowledgeCites(oldFolder, in: repo) {
            retractKnowledge(ofItemAt: oldFolder, title: session.title, in: project)
        }
        curateKnowledge(for: sessionID)
    }

    /// True when a file in private/knowledge/ cites the folder (relative to the repo root).
    func privateKnowledgeCites(_ folder: String, in repo: URL) -> Bool {
        let root = repo.appendingPathComponent(SharedProjectLayout.privateKnowledgeFolder, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "md" {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(folder) { return true }
        }
        return false
    }
}
