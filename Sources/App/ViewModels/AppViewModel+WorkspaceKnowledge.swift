// Purpose: Knowledge in the workspaces: which repo a meeting's knowledge belongs to, curating it
//          after Process, moving it when a meeting changes project, the one-time move of the old
//          knowledge base into the repos, and keeping the search index in step with the files.
// Dependencies: Sources/App/Services/KnowledgeCurationService.swift (KnowledgeCurator),
//               Sources/App/Models/SharedProject.swift (layout of Shared Projects),
//               Sources/App/Services/KnowledgeIndexer.swift,
//               Sources/App/Services/ProjectRepositoryService.swift (repos, General workspace),
//               Sources/App/Store/KnowledgeStore.swift
// RBAC: None.
// Dependents: Sources/App/ViewModels/AppViewModel.swift (runMeetingProcessing,
//             assignSessionToProject, startup), Sources/App/Services/ToolExecutor.swift
//             (commit_to_knowledge_base)
// Notes: User decisions 2026-10-04: knowledge is kept by an agent in knowledge/*.md of each
//        workspace after every Process; meetings without a project feed the General workspace;
//        a meeting assigned to another project after processing is retracted from the old
//        workspace and curated into the new one. Quick recordings without a project stay out of
//        General: they are the user's own notes, not meetings (agreed with the quick recording
//        work of the same day).
//        Shared Projects: an item under private/ is curated into private/knowledge/ in the repo
//        itself; a published one goes to the shared knowledge/ through a `.shared` curator job,
//        which the app replays in a clean worktree and pushes (AppViewModel+SharedSync.swift).
//        Where the item's folder sits decides the route, not the session's publication or
//        whether the project is Shared yet, so a private folder can never feed the shared knowledge.

import Foundation

extension AppViewModel {
    /// The workspace a session's files and knowledge belong to: its project, or General for a
    /// processed meeting without one. Nil for quick recordings without a project.
    func workspaceProject(for session: RecordingSession) -> Project? {
        if let id = session.projectID {
            return projects.first { $0.id == id }
        }
        guard !session.isQuickRecording else { return nil }
        return ProjectRepositoryService.generalProject
    }

    /// Wires the curator and indexes what is on disk. Called once at launch.
    func setupWorkspaceKnowledge() {
        guard !Self.isTestProcess else { return }
        knowledgeCurator.modelProvider = { [weak self] in self?.automationSettings.claudeModel ?? "sonnet" }
        knowledgeCurator.onRepoChanged = { [weak self] repo in
            guard let self else { return }
            Task { await self.reindexWorkspaceKnowledge(repo: repo) }
        }
        knowledgeCurator.onJobFinished = { [weak self] sessionID in
            if let sessionID { self?.knowledgeExtractionInProgress.remove(sessionID) }
        }
        Task {
            await migrateKnowledgeBaseToWorkspaces()
            await reindexAllWorkspaceKnowledge()
        }
    }

    /// Asks the knowledge agent to fold a processed session into its workspace's knowledge.
    func curateKnowledge(for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              session.meetingMinutesFileName != nil,
              let project = workspaceProject(for: session) else { return }
        mirrorMeetingToWorkspace(sessionID)
        guard let folder = projectRepositories.mirroredFolder(for: session, in: project) else { return }
        knowledgeExtractionInProgress.insert(sessionID)
        let repo = projectRepositories.repoURL(for: project.id)
        if project.isShared, !SharedProjectLayout.isPrivate(folder) {
            projectRepositories.markCited(session: session, in: project)
            knowledgeCurator.enqueue(.shared(
                repo: repo, step: .curate(meetingFolder: folder), title: session.title, sessionID: sessionID))
        } else {
            knowledgeCurator.enqueue(.curate(
                repo: repo, meetingFolder: folder, title: session.title, sessionID: sessionID,
                knowledgeFolder: Self.knowledgeFolder(forItemAt: folder)))
        }
    }

    /// knowledge/, or private/knowledge/ for an item under private/. That holds while the
    /// project is still Private too: the share-project skill moves items into private/ before the
    /// project turns Shared, and their facts must not land in the knowledge/ it is about to push.
    static func knowledgeFolder(forItemAt folder: String) -> String {
        SharedProjectLayout.isPrivate(folder) ? SharedProjectLayout.privateKnowledgeFolder : "knowledge"
    }

    /// Takes an item's knowledge out of the knowledge layer its folder fed: the shared knowledge
    /// through the replay, otherwise the repo's own knowledge/ or private/knowledge/.
    func retractKnowledge(ofItemAt folder: String, title: String, in project: Project) {
        let repo = projectRepositories.repoURL(for: project.id)
        if project.isShared, !SharedProjectLayout.isPrivate(folder) {
            knowledgeCurator.enqueue(.shared(repo: repo, step: .retract(meetingFolder: folder), title: title, sessionID: nil))
        } else {
            knowledgeCurator.enqueue(.retract(
                repo: repo, meetingFolder: folder, title: title,
                knowledgeFolder: Self.knowledgeFolder(forItemAt: folder)))
        }
    }

    /// A processed session changed project: take it and its knowledge out of the old workspace,
    /// then mirror and curate it into the new one. `oldSession` is the session before the change.
    func moveWorkspaceKnowledge(from oldSession: RecordingSession) {
        guard oldSession.meetingMinutesFileName != nil else { return }
        if let oldProject = workspaceProject(for: oldSession),
           let folder = projectRepositories.unmirror(session: oldSession, from: oldProject) {
            retractKnowledge(ofItemAt: folder, title: oldSession.title, in: oldProject)
        }
        curateKnowledge(for: oldSession.id)
    }

    /// Reindexes one repo's knowledge files into the knowledge base.
    func reindexWorkspaceKnowledge(repo: URL) async {
        guard let knowledgeStore, let repoID = UUID(uuidString: repo.lastPathComponent) else { return }
        let projectID: UUID? = repoID == ProjectRepositoryService.generalProjectID ? nil : repoID
        await KnowledgeIndexer.index(
            repoID: repoID, repo: repo, files: projectRepositories.knowledgeFiles(in: repo),
            projectID: projectID, store: knowledgeStore)
    }

    func reindexAllWorkspaceKnowledge() async {
        for (_, repo) in projectRepositories.existingRepositories() {
            await reindexWorkspaceKnowledge(repo: repo)
        }
    }

    /// Adds knowledge to a workspace file directly (agent tool, assistant output): appended under
    /// the category's topic file, committed and indexed. Returns the file path relative to the repo.
    /// In a Shared Project it goes to private/knowledge/ and is not committed: the sync would push
    /// knowledge/ to every member, and nothing leaves the Mac without the user publishing it.
    @discardableResult
    func commitKnowledgeToWorkspace(title: String, category: String, content: String, projectID: UUID?) async -> String {
        let project = projectID.flatMap { id in projects.first { $0.id == id } } ?? ProjectRepositoryService.generalProject
        let repo = projectRepositories.ensureRepository(for: project)
        let slug = ProjectRepositoryService.slug(category.isEmpty ? "notes" : category).lowercased()
        let folder = project.isShared ? SharedProjectLayout.privateKnowledgeFolder : "knowledge"
        let relative = "\(folder)/\(slug.isEmpty ? "notes" : slug).md"
        let url = repo.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# \(category.isEmpty ? "Notes" : category)\n"
        let day = Date().formatted(.iso8601.year().month().day())
        text += "\n## \(title)\n\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n\n(added by the assistant, \(day))\n"
        try? Data(text.utf8).write(to: url, options: .atomic)
        if !project.isShared {
            ProjectRepositoryService.git(["add", relative], in: repo)
            ProjectRepositoryService.git(["commit", "-q", "-m", "Knowledge: \(title) (assistant)"], in: repo)
        }
        await reindexWorkspaceKnowledge(repo: repo)
        return relative
    }

    // MARK: - One-time move of the old knowledge base

    /// Writes every document of the old knowledge base (except notes, which stay database-only)
    /// into knowledge/imported/<yyyy-MM>.md of its project's workspace (General without one),
    /// commits, removes the documents from the database and lets the agent merge the imports
    /// into the topic files, one file per run. Runs once; a marker file records that it ran.
    /// By month, not by category: the old base had hundreds of one-off categories, which would
    /// have meant hundreds of files and no workable unit for the agent.
    func migrateKnowledgeBaseToWorkspaces() async {
        guard let knowledgeStore else { return }
        let marker = projectRepositories.rootDirectory.deletingLastPathComponent()
            .appendingPathComponent(".knowledge-moved-to-workspaces")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        // A copy of the database as it was, in case anything about the move needs undoing.
        let database = marker.deletingLastPathComponent().appendingPathComponent("knowledge.sqlite")
        let backup = marker.deletingLastPathComponent().appendingPathComponent("knowledge.before-workspaces.sqlite")
        if FileManager.default.fileExists(atPath: database.path), !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: database, to: backup)
        }

        let documents = ((try? knowledgeStore.fetchAllDocuments()) ?? []).filter {
            $0.sourceNoteID == nil && !$0.sourceMeetingTitle.hasPrefix(KnowledgeIndexer.sourcePrefix)
        }
        var imports: [(repo: URL, file: String, bytes: Int)] = []
        let grouped = Dictionary(grouping: documents) { doc -> UUID in
            doc.projectID.flatMap { id in projects.contains { $0.id == id } ? id : nil }
                ?? ProjectRepositoryService.generalProjectID
        }
        for (projectID, docs) in grouped {
            let project = projects.first { $0.id == projectID } ?? ProjectRepositoryService.generalProject
            let repo = projectRepositories.ensureRepository(for: project)
            let folder = repo.appendingPathComponent("knowledge/imported", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let byMonth = Dictionary(grouping: docs) { $0.date.formatted(.iso8601.year().month()) }
            for (month, items) in byMonth {
                var text = "# Imported knowledge, \(month)\n"
                for doc in items.sorted(by: { $0.date < $1.date }) {
                    let day = doc.date.formatted(.iso8601.year().month().day())
                    text += "\n## \(doc.category.isEmpty ? "" : doc.category + ": ")\(doc.title)\n\n_From: \(doc.sourceMeetingTitle), \(day)_\n\n"
                        + doc.fullContent.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                }
                let name = "knowledge/imported/\(month).md"
                try? Data(text.utf8).write(to: repo.appendingPathComponent(name), options: .atomic)
                imports.append((repo, name, text.utf8.count))
            }
            ProjectRepositoryService.git(["add", "-A", "knowledge"], in: repo)
            ProjectRepositoryService.git(["commit", "-q", "-m", "Import knowledge from the old knowledge base"], in: repo)
        }
        for doc in documents {
            if let id = doc.id { try? knowledgeStore.deleteDocument(id: id) }
        }
        try? Data().write(to: marker)
        NSLog("AppViewModel: moved \(documents.count) knowledge document(s) into \(imports.count) import file(s)")
        // Oldest first, so later months correct earlier ones as the agent works forward.
        for item in imports.sorted(by: { $0.file < $1.file }) where item.bytes <= KnowledgeCurator.maxImportBytesToConsolidate {
            knowledgeCurator.enqueue(.consolidateImport(repo: item.repo, file: item.file))
        }
    }
}
