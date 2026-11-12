// Purpose: Becoming a Shared Project: "Make Shared Project..." opens a Claude session in the
//          workspace running the share-project migration skill, the MCP tool that skill calls
//          when it has pushed (completeSharedProjectSetup), and joining a Shared Project from its
//          repo URL.
// Dependencies: Sources/App/Models/SharedProject.swift,
//               Sources/App/Services/SharedProjectSkill.swift (skill text, first prompt),
//               Sources/App/Services/SharedProjectSetupService.swift (git and file work),
//               Sources/App/Services/ProjectRepositoryService.swift (repo folders),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (Claude session),
//               Sources/App/ViewModels/AppViewModel.swift (claudeLaunch(initialPrompt:),
//               addJoinedProject, setProjectShared, recordPublications),
//               Sources/App/ViewModels/AppViewModel+SharedSync.swift (syncSharedProjectNow)
// RBAC: Every user can share a project; whoever shares it first is its admin
//       (SharedProjectManifest.admin, written by the skill). Joining needs read access to the
//       repo, which the git host grants to the repo's collaborators.
// Dependents: Sources/App/Views/ProjectsSidebarView.swift (context menu, New Project sheet),
//             Sources/App/Services/MCP/MCPSharedProjectTools.swift (complete_shared_project_setup)
// Notes: The callers make sure a display name is set (ContributorName.current) before calling.
//        The migration runs in a normal workspace Claude session, so the user sees and steers
//        every step; the app only checks the result (completeSharedProjectSetup) before it flips
//        the project to Shared. Before flipping, each of the user's sessions gets the publish
//        choice the skill made (read from the local indexes), so later mirroring keeps published
//        items in meetings/ and private ones in private/meetings/.
//        A restarted migration session starts plain Claude (the view's launcher): the first
//        prompt belongs to the first launch only.

import AppKit
import Foundation

extension AppViewModel {
    /// Writes the migration skill into the project's workspace and opens a Claude session that
    /// runs it. The caller has made sure a display name is set (ContributorName.current).
    func beginMakeShared(_ project: Project) {
        let current = projects.first { $0.id == project.id } ?? project
        guard !ProjectRepositoryService.isGeneral(current), !current.isShared else { return }
        guard let displayName = ContributorName.current else {
            errorMessage = SharedProjectSetupError.noDisplayName.errorDescription
            return
        }
        let repo = projectRepositories.ensureRepository(for: current)
        do {
            try SharedProjectSkill.install(in: repo)
        } catch {
            errorMessage = "Could not prepare the sharing assistant: \(error.localizedDescription)"
            return
        }
        let prompt = SharedProjectSkill.initialPrompt(
            projectID: current.id, projectName: current.name, colorHex: current.colorHex,
            displayName: displayName, folderSuffix: ContributorName.folderSuffix(displayName))

        showWorkspaceTab(of: current.id)
        let launch: WorkspaceTerminalStore.Launcher = { kind in
            if case .claude(let model) = kind {
                return self.claudeLaunch(for: current, model: model, initialPrompt: prompt)
            }
            return self.workspaceLaunch(for: current, kind: kind)
        }
        // The first session of a workspace not opened yet this launch runs the skill; otherwise
        // the skill gets a session of its own.
        let terminals = workspaceTerminals
        let before = Set(terminals.sessions(rootedAt: current.id).map(\.id))
        terminals.ensureSession(in: current.id, projectID: current.id, launch: launch)
        if Set(terminals.sessions(rootedAt: current.id).map(\.id)) == before,
           terminals.addSession(in: current.id, kind: .claude(model: "opus"), launch: launch) == nil {
            errorMessage = SharedProjectSetupError.sessionLimit.errorDescription
        }
    }

    /// Clones a Shared Project's workspace repo, creates the local project with the id from its
    /// manifest, registers the user as a member and clones the listed code repos.
    func joinSharedProject(remoteURL: String) async throws -> Project {
        guard let displayName = ContributorName.current else { throw SharedProjectSetupError.noDisplayName }
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = projectRepositories.rootDirectory
        let existing = Set(projects.map(\.id))
        let joined = try await Task.detached(priority: .userInitiated) {
            try SharedProjectSetup.cloneWorkspace(
                remoteURL: url, into: root, displayName: displayName, existingProjectIDs: existing)
        }.value

        let manifest = joined.manifest
        var project = Project(
            id: manifest.projectID, name: manifest.name, colorHex: manifest.colorHex ?? Project.defaultColors[0])
        project.shared = SharedProjectInfo(remoteURL: url, sharedAt: Date())
        addJoinedProject(project)

        let failures = await Task.detached(priority: .utility) {
            SharedProjectSetup.cloneCodeRepos(manifest.codeRepos, into: joined.repo)
        }.value
        for failure in failures { print("[SharedProjects] Code repo not cloned for \(manifest.name): \(failure)") }

        syncSharedProjectNow(project.id)
        return project
    }

    /// Called by the share-project skill (MCP `complete_shared_project_setup`) once it pushed:
    /// checks origin, manifest and the pushed main, records the publish choice of the user's
    /// sessions and turns the project Shared. Returns a short report for Claude.
    func completeSharedProjectSetup(projectID: UUID, remoteURL: String) async throws -> String {
        guard let project = projects.first(where: { $0.id == projectID }),
              !ProjectRepositoryService.isGeneral(project) else {
            throw SharedProjectSetupError.projectNotFound
        }
        let repo = projectRepositories.repoURL(for: projectID)
        let origin = try await Task.detached(priority: .userInitiated) {
            try SharedProjectSetup.validateSetup(repo: repo, projectID: projectID, remoteURL: remoteURL)
        }.value

        let choices = SharedProjectSetup.publications(in: repo)
        recordPublications(choices, in: projectID)
        setProjectShared(projectID, SharedProjectInfo(remoteURL: origin, sharedAt: project.shared?.sharedAt ?? Date()))
        syncSharedProjectNow(projectID)

        let published = choices.values.filter { $0 == .published }.count
        return """
            "\(project.name)" is now a Shared Project, synced with \(origin). MinuteMind recorded \
            \(published) published and \(choices.count - published) private meetings and recordings \
            of this user and keeps the workspace in sync in the background.
            """
    }

    /// Shows the project's Workspace tab in the main window.
    private func showWorkspaceTab(of projectID: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        isShowingAllTasks = false
        isShowingCalendar = false
        isShowingInbox = false
        isShowingClipboard = false
        selectedProjectID = projectID
        requestedProjectTab = .workspaces
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

enum SharedProjectSetupError: LocalizedError, Equatable {
    case noDisplayName
    case sessionLimit
    case invalidRemoteURL
    case cloneFailed(String)
    case notSharedProject
    case alreadyJoined(String)
    case workspaceFolderExists(String)
    case gitFailed(String)
    case projectNotFound
    case workspaceMissing
    case noOrigin
    case originMismatch(expected: String, actual: String)
    case manifestMissing
    case manifestMismatch(UUID)
    case mainMissing
    case remoteUnreachable(String)
    case notPushed
    case manifestNotPushed
    case privateContentPushed
    case historyNotFresh
    case extraRefsPushed([String])
    case jobsPushed

    var errorDescription: String? {
        switch self {
        case .noDisplayName:
            return "Set your display name first: it is shown to the other members and added to the folders you publish."
        case .sessionLimit:
            return "This project already runs six Claude sessions. Close one, then choose Make Shared Project again."
        case .invalidRemoteURL:
            return "Paste the URL of the Shared Project's git repo, for example git@github.com:team/acme-minutemind.git."
        case .cloneFailed(let reason):
            return "Could not clone the repo: \(reason) Check the URL and that you were invited to the repo."
        case .notSharedProject:
            return "This repo is not a MinuteMind Shared Project."
        case .alreadyJoined(let name):
            return "You already have the project \"\(name)\" in MinuteMind."
        case .workspaceFolderExists(let name):
            return "A workspace folder for \"\(name)\" already exists on this Mac. Move it out of MinuteMind's Workspaces folder, then join again."
        case .gitFailed(let reason):
            return "Could not register you as a member: \(reason) Check that git knows your name and email (git config --global user.name / user.email)."
        case .projectNotFound:
            return "There is no MinuteMind project with that id (see list_projects)."
        case .workspaceMissing:
            return "The project's workspace repo does not exist."
        case .noOrigin:
            return "The workspace has no git remote named origin yet. Add it with git remote add origin <url>."
        case .originMismatch(let expected, let actual):
            return "origin points to \(actual), not to \(expected). Pass the exact output of git remote get-url origin."
        case .manifestMissing:
            return ".minutemind/project.json is missing or not valid (projectID, name, admin, members, codeRepos)."
        case .manifestMismatch(let id):
            return ".minutemind/project.json names the project \(id.uuidString), not this one."
        case .mainMissing:
            return "There is no local branch main. The shared history must be on main."
        case .remoteUnreachable(let reason):
            return "Could not reach origin: \(reason)"
        case .notPushed:
            return "main is not pushed to origin yet (or origin's main is not this history). Run git push -u origin main."
        case .manifestNotPushed:
            return "origin's main does not contain .minutemind/project.json. Commit it and push main."
        case .privateContentPushed:
            return "The history of origin's main contains files under private/. They were pushed and are visible to everyone with access to the repo, also in older commits. Delete the remote repo, rebuild the shared history as one fresh commit without them, and push again."
        case .historyNotFresh:
            return "origin's main does not start with a fresh shared history: its first commit must be the one that adds .minutemind/project.json, with nothing before it. The workspace's old history holds meetings that are private now. Delete the remote repo, rebuild main as one new root commit (step 7 of the skill) and push again."
        case .extraRefsPushed(let refs):
            return "origin holds more than main: \(refs.joined(separator: ", ")). Only main may be pushed; the backup branch and tags hold the old history with private meetings. Delete those refs on the remote (or delete the repo and push main alone)."
        case .jobsPushed:
            return "The history of origin's main contains files under jobs/. Jobs and their results stay private. Delete the remote repo, add /jobs/ to .gitignore, rebuild the shared history as one fresh commit without them, and push again."
        }
    }
}
