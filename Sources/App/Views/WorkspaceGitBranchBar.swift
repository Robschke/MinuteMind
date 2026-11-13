// Purpose: WorkspaceGitBranchBar, the branch row at the bottom of a workspace's file tree: shows
//          which branch is checked out and whether there are uncommitted changes, and switches or
//          creates branches from a popover, asking before anything could surprise the user.
// Dependencies: Sources/App/Services/WorkspaceGitService.swift (all git work),
//               Sources/App/Services/GitAvailability.swift (git missing: hint and install),
//               Sources/App/Services/ProjectRepositoryService.swift (switchingRepos pauses the
//               app's own commits), Sources/App/Services/KnowledgeCurationService.swift
//               (runningRepo), Sources/App/Supporting/WorkspaceEditorStore.swift (save before a
//               switch), Sources/App/Supporting/WorkspaceTerminalStore.swift (Claude sessions),
//               Sources/App/Views/SharedProjectStatusViews.swift (WorkspaceSharedSyncStatus)
// Used by: Sources/App/Views/WorkspaceFileTreeView.swift
// Notes: Modelled on VS Code's status bar item, reviewed by a design pass:
//        - Bottom left like VS Code, always visible, below the tree's notice. Icon, branch name
//          (truncated in the middle), "*" for uncommitted changes, chevron. Off the main branch
//          (main or master) and on a detached HEAD it turns orange: the app's meeting and
//          knowledge commits land on the checked-out branch, so the user should notice.
//        - A merge, rebase, cherry-pick or revert in progress shows "(git busy)"; a click explains
//          that it is finished in the terminal (a disabled button would show no tooltip).
//        - Popover, not a Menu: a Menu label loses its colours on macOS, and the popover holds
//          the inline New Branch form (spaces become hyphens while typing, the name is checked
//          before Create is enabled). Local branches only, most recent commit first; delete,
//          rename, merge and remotes stay with Claude in the terminal.
//        - Switching never forces. Clean tree and no Claude session working: switch at once.
//          Uncommitted changes: one alert, Bring Changes (plain git switch) or Leave Changes
//          Here (stashed under the branch name, restored when the user comes back). git
//          refusing because a change clashes leads to a second alert offering Leave Changes
//          Here and Switch. A working Claude session adds a line, or its own confirm on a clean
//          tree. Branch names never go into button labels (long names make huge buttons).
//        - Blocked while MinuteMind's knowledge job runs in this repo; while a switch runs the
//          app's own add and commit pause. Before a switch the app commits what it wrote itself
//          (meetings, knowledge) and has not committed yet, so that never counts or gets stashed
//          as the user's changes. Leaving a detached HEAD whose commits are on no branch asks
//          first (they would be lost). Alerts wait 200 ms for the popover to close.
//        - After a switch: changes left on the target come back, a vanished open file is
//          reported (the editor closes it), the first visit to a side branch explains where
//          meetings go now, and the repo's knowledge is reindexed.
//        - git status every 2 s while the workspace shows (no optional locks, so Claude's git
//          commands never wait on it).
//        - Without a real git (no Command Line Tools) the row says so and offers Apple's installer;
//          it switches to the branch by itself once git is there, creating the repository first.
//        - A Shared Project shows its sync state right after the branch ("Synced 2 min ago",
//          "Syncing…", or the problem in orange) and a Sync now button. The branch button then
//          hugs its label instead of filling the row, so the sync state sits beside it.

import SwiftUI

struct WorkspaceGitBranchBar: View {
    let project: Project
    let repo: URL
    let terminals: WorkspaceTerminalStore
    /// Shows a message in the tree's notice area.
    let notify: (String) -> Void
    @Environment(AppViewModel.self) private var viewModel

    @State private var state: WorkspaceGitState?
    @State private var isPickerShown = false
    @State private var isSwitching = false
    @State private var prompt: Prompt?
    /// Side branches whose "meetings go here now" note was shown this session.
    @State private var explainedBranches: Set<String> = []
    /// No real git on this Mac: the row offers Apple's Command Line Tools instead of a branch.
    @State private var isGitMissing = false

    private enum Prompt {
        case changes(from: String?, to: String, count: Int, claudeWorking: Bool, claudeOpen: Bool)
        case conflicts(from: String?, to: String, files: [String])
        case claudeWorking(to: String)
        case message(title: String, text: String)
        case leavesCommits(to: String, count: Int)
    }

    /// main, else master, when the repo has one: the branch the app's history starts on.
    private var mainBranch: String? {
        guard let branches = state?.branches else { return nil }
        return ["main", "master"].first { branches.contains($0) }
    }

    private var isOffMain: Bool {
        guard let state else { return false }
        switch state.head {
        case .detached: return true
        case .branch(let name): return mainBranch.map { $0 != name } ?? false
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if isGitMissing {
                gitMissingRow
            } else {
                branchButton
                    .layoutPriority(1)
                if project.isShared {
                    WorkspaceSharedSyncStatus(projectID: project.id)
                        .padding(.trailing, 12)
                    Spacer(minLength: 0)
                }
            }
        }
        .alert(promptTitle(prompt), isPresented: isPromptShown, presenting: prompt) { promptActions($0) } message: {
            Text(promptMessage($0))
        }
        .task(id: repo) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var branchButton: some View {
        Button {
            if let operation = state?.operation {
                prompt = .message(title: "A \(operation.noun) is in progress",
                                  text: "Finish or abort it in the terminal, then switch branches.")
            } else {
                isPickerShown.toggle()
            }
        } label: {
            label
        }
        .buttonStyle(.plain)
        // Not disabled while git is busy: a disabled button shows no tooltip, so a click explains.
        .disabled(state == nil || isSwitching)
        .help(tooltip)
        .popover(isPresented: $isPickerShown, arrowEdge: .top) {
            if let state {
                WorkspaceBranchPicker(
                    state: state, repo: repo,
                    switchTo: { target in
                        isPickerShown = false
                        requestSwitch(to: target)
                    },
                    create: { name in
                        isPickerShown = false
                        createBranch(name)
                    })
            }
        }
    }

    // MARK: - Row

    /// Shown instead of the branch while git is missing. Turns back into the branch by itself
    /// once the tools are installed (the poll keeps checking).
    private var gitMissingRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
            Text("git is not installed")
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Install\u{2026}") { GitAvailability.installDeveloperTools() }
                .controlSize(.mini)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Without git this workspace keeps no history and Shared Projects cannot sync. Install opens Apple's installer for the Command Line Tools, which include git.")
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            if isSwitching {
                ProgressView().controlSize(.mini)
            } else if state?.operation == nil, state != nil {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if !project.isShared { Spacer(minLength: 0) }
        }
        .font(.system(size: 11))
        .foregroundStyle(isOffMain ? Color.orange : Color.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .frame(maxWidth: project.isShared ? nil : .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var title: String {
        guard let state else { return "No git repository" }
        let dirty = state.changedFiles > 0 ? "*" : ""
        switch state.head {
        case .branch(let name):
            return state.operation == nil ? name + dirty : "\(name) (git busy)"
        case .detached(let commit):
            return state.operation == nil ? "\(commit) (detached)\(dirty)" : "\(commit) (git busy)"
        }
    }

    private var tooltip: String {
        guard let state else { return "This workspace is not a git repository." }
        if let operation = state.operation {
            return "A \(operation.noun) is in progress. Finish or abort it in the terminal to switch branches."
        }
        let changes = state.changedFiles == 0 ? "No uncommitted changes."
            : state.changedFiles == 1 ? "1 uncommitted change." : "\(state.changedFiles) uncommitted changes."
        switch state.head {
        case .detached(let commit):
            return "No branch checked out (commit \(commit)). \(changes) MinuteMind holds its own commits until a branch is checked out. Click to switch branches."
        case .branch(let name):
            let side = isOffMain ? " Meetings and knowledge processed now are saved on this branch." : ""
            return "On branch \(name). \(changes)\(side) Click to switch branches."
        }
    }

    // MARK: - Switching

    private func refresh() async {
        let repo = repo
        let installed = await Task.detached { GitAvailability.isInstalled }.value
        guard installed else {
            if !isGitMissing { isGitMissing = true }
            return
        }
        if isGitMissing {
            isGitMissing = false
            // A workspace opened while git was missing has no repository yet.
            viewModel.projectRepositories.ensureRepository(for: project)
        }
        let fresh = await Task.detached { WorkspaceGit.state(of: repo) }.value
        if fresh != state { state = fresh }
    }

    private func requestSwitch(to target: String, acceptingLeftCommits: Bool = false) {
        viewModel.workspaceEditors.state(for: project.id).save()
        let repo = repo
        Task {
            // An alert set while the popover closes is often never shown.
            try? await Task.sleep(for: .milliseconds(200))
            if viewModel.knowledgeCurator.runningRepo?.standardizedFileURL == repo.standardizedFileURL {
                prompt = .message(title: "MinuteMind is updating this workspace's knowledge",
                                  text: "Switch branches when it is done, in a minute or two.")
                return
            }
            await Task.detached { WorkspaceGit.commitAppManagedChanges(in: repo) }.value
            await refresh()
            guard let state, state.operation == nil else { return }
            if !acceptingLeftCommits, case .detached = state.head {
                let left = await Task.detached { WorkspaceGit.commitsOnNoBranch(in: repo) }.value
                if left > 0 {
                    prompt = .leavesCommits(to: target, count: left)
                    return
                }
            }
            let claude = terminals.sessions(rootedAt: project.id).filter { !$0.isTerminal }
            let working = claude.contains { $0.status == .working }
            if state.changedFiles > 0 {
                prompt = .changes(from: state.branchName, to: target, count: state.changedFiles,
                                  claudeWorking: working, claudeOpen: !claude.isEmpty)
            } else if working {
                prompt = .claudeWorking(to: target)
            } else {
                perform(to: target, leavingChangesOn: nil)
            }
        }
    }

    /// Switches, first stashing the changes under `leavingChangesOn` when given.
    private func perform(to target: String, leavingChangesOn current: String?) {
        let repo = repo
        let from = state?.branchName
        isSwitching = true
        let key = repo.standardizedFileURL.path
        ProjectRepositoryService.switchingRepos.insert(key)
        Task {
            let outcome = await Task.detached {
                if let current { return WorkspaceGit.leaveChangesAndSwitch(from: current, to: target, in: repo) }
                return WorkspaceGit.switchBranch(to: target, in: repo)
            }.value
            ProjectRepositoryService.switchingRepos.remove(key)
            isSwitching = false
            switch outcome {
            case .switched:
                await arrived(at: target)
            case .conflicts(let files):
                prompt = .conflicts(from: from, to: target, files: files)
            case .failed(let reason):
                prompt = .message(title: "Could not switch to \(target)", text: reason)
            }
            await refresh()
        }
    }

    private func createBranch(_ name: String) {
        let repo = repo
        isSwitching = true
        Task {
            let outcome = await Task.detached { WorkspaceGit.createBranch(name, in: repo) }.value
            isSwitching = false
            if case .failed(let reason) = outcome {
                prompt = .message(title: "Could not create \(name)", text: reason)
            }
            await refresh()
            if outcome == .switched, let note = sideBranchNote(name) { notify(note) }
        }
    }

    /// Restores changes left on `target`, reports a vanished open file, explains a side branch.
    private func arrived(at target: String) async {
        let repo = repo
        var notes: [String] = []
        let restored = await Task.detached { WorkspaceGit.restoreLeftChanges(on: target, in: repo) }.value
        switch restored {
        case .nothing: break
        case .restored: notes.append("Your uncommitted changes from \(target) are back.")
        case .kept(let reason): notes.append(reason)
        }
        if let open = viewModel.workspaceEditors.state(for: project.id).document?.url,
           !FileManager.default.fileExists(atPath: open.path) {
            notes.append("\(open.lastPathComponent) doesn't exist on \(target).")
        }
        await refresh()
        if let side = sideBranchNote(target) { notes.append(side) }
        if !notes.isEmpty { notify(notes.joined(separator: " ")) }
        Task { await viewModel.reindexWorkspaceKnowledge(repo: repo) }
    }

    /// Explains once per branch and session where meetings go while a side branch is checked out.
    private func sideBranchNote(_ branch: String) -> String? {
        guard isOffMain, let mainBranch, !explainedBranches.contains(branch) else { return nil }
        explainedBranches.insert(branch)
        return "Meetings and knowledge processed now are saved on \(branch). On \(mainBranch) they appear once the branches are merged."
    }

    // MARK: - Alerts

    private var isPromptShown: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private func promptTitle(_ prompt: Prompt?) -> String {
        switch prompt {
        case .changes(let from, _, let count, _, _)?:
            let noun = count == 1 ? "1 uncommitted change" : "\(count) uncommitted changes"
            return from.map { "\($0) has \(noun)" } ?? "You have \(noun)"
        case .conflicts(_, let to, _)?: return "Can't bring your changes to \(to)"
        case .claudeWorking?: return "Claude is working in this workspace"
        case .message(let title, _)?: return title
        case .leavesCommits(_, let count)?:
            return count == 1 ? "1 commit is on no branch" : "\(count) commits are on no branch"
        case nil: return ""
        }
    }

    @ViewBuilder
    private func promptActions(_ prompt: Prompt) -> some View {
        switch prompt {
        case .changes(let from, let to, _, _, _):
            Button("Bring Changes") { perform(to: to, leavingChangesOn: nil) }
                .keyboardShortcut(.defaultAction)
            if let from {
                Button("Leave Changes Here") { perform(to: to, leavingChangesOn: from) }
            }
            Button("Cancel", role: .cancel) {}
        case .conflicts(let from, let to, _):
            if let from {
                Button("Leave Changes Here and Switch") { perform(to: to, leavingChangesOn: from) }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        case .claudeWorking(let to):
            Button("Switch Anyway", role: .destructive) { perform(to: to, leavingChangesOn: nil) }
            Button("Cancel", role: .cancel) {}
        case .message:
            Button("OK", role: .cancel) {}
        case .leavesCommits(let to, _):
            Button("Switch Anyway", role: .destructive) { requestSwitch(to: to, acceptingLeftCommits: true) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func promptMessage(_ prompt: Prompt) -> String {
        switch prompt {
        case .changes(let from, let to, _, let working, let claudeOpen):
            var lines = [from.map { "Bring them to \(to), or leave them on \($0) until you come back." }
                         ?? "Bring them to \(to)."]
            if working {
                lines.append("Claude is working in this workspace right now; switching changes the files under it.")
            } else if claudeOpen {
                lines.append("Claude sessions in this workspace will see the files of \(to).")
            }
            return lines.joined(separator: "\n\n")
        case .conflicts(let from, let to, let files):
            let shown = files.prefix(3).joined(separator: ", ")
            let more = files.count > 3 ? " (+\(files.count - 3) more)" : ""
            let advice = from == nil ? " Commit or discard them in the terminal first." : ""
            return "These files differ on \(to): \(shown)\(more).\(advice)"
        case .claudeWorking(let to):
            return "Switching to \(to) changes the files under it."
        case .message(_, let text):
            return text
        case .leavesCommits(let to, _):
            return "No branch is checked out, so switching to \(to) leaves these commits behind and git cleans them up later. To keep them, cancel and create a new branch here first."
        }
    }
}

/// The popover: local branches to switch to, and an inline form for a new branch.
private struct WorkspaceBranchPicker: View {
    let state: WorkspaceGitState
    let repo: URL
    let switchTo: (String) -> Void
    let create: (String) -> Void

    @State private var isCreating = false
    @State private var newName = ""
    @State private var problem: String?
    @State private var filter = ""
    @State private var hovered: String?
    @FocusState private var nameFocused: Bool

    private var shownBranches: [String] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return state.branches }
        return state.branches.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isCreating { creationForm } else { branchList }
        }
        .frame(width: 280)
        .padding(.vertical, 8)
    }

    private var branchList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Switch Branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            if state.branches.count > 8 {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shownBranches, id: \.self) { branch in
                        row(branch)
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            rowButton(key: "+new", systemImage: "plus", title: "New Branch…", isCurrent: false) {
                isCreating = true
            }
        }
    }

    private func row(_ branch: String) -> some View {
        let isCurrent = state.branchName == branch
        return rowButton(key: branch, systemImage: isCurrent ? "checkmark" : nil, title: branch, isCurrent: isCurrent) {
            switchTo(branch)
        }
        .disabled(isCurrent)
    }

    private func rowButton(key: String, systemImage: String?, title: String, isCurrent: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage ?? "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(systemImage == nil ? 0 : 1)
                    .frame(width: 12)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(hovered == key && !isCurrent ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) }
    }

    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Branch")
                .font(.system(size: 13, weight: .semibold))
            TextField("feature-name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(submit)
                .onChange(of: newName) { _, value in
                    let hyphenated = value.replacingOccurrences(of: " ", with: "-")
                    if hyphenated != value { newName = hyphenated }
                    check()
                }
            if let problem, !newName.isEmpty {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(state.branchName.map { "Starts from \($0). Your uncommitted changes come along." }
                     ?? "Starts from the current commit. Your uncommitted changes come along.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    isCreating = false
                    newName = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.isEmpty || problem != nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .onAppear {
            check()
            // The field exists only now; focusing it together with isCreating did nothing.
            nameFocused = true
        }
    }

    private func check() {
        let name = newName
        let branches = state.branches
        let repo = repo
        Task {
            let found = await Task.detached { WorkspaceGit.problem(withNewBranchName: name, existing: branches, in: repo) }.value
            if name == newName { problem = found }
        }
    }

    private func submit() {
        guard !newName.isEmpty, problem == nil else { return }
        create(newName)
    }
}
