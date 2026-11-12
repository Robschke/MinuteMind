// Purpose: WorkspaceFileTreeView, the file tree on the left of a project workspace: the repo's
//          files and folders with Finder-like file management (move by drag and drop, rename in
//          place, new file and folder, duplicate, copy path, trash), Quick Look and drops from
//          Finder. Its selection drives the editor.
// Dependencies: Sources/App/Views/WorkspaceFileOutlineView.swift (the AppKit outline: rows, drags,
//               inline rename, keys), Sources/App/Supporting/WorkspaceFileOperations.swift (file
//               work and the managed-folder rules), Sources/App/Supporting/WorkspaceEditorStore.swift
//               (documentMoved, so the open file follows a move), Sources/App/Supporting/
//               WorkspaceTerminalStore.swift (sessions for "Reference in Claude"),
//               QuickLook (SwiftUI .quickLookPreview), Sources/App/Views/WorkspaceGitBranchBar.swift
//               (branch row at the bottom), Sources/App/ViewModels/AppViewModel+SharedPublishing.swift
//               (publishPrivateItem)
// Used by: Sources/App/Views/ProjectWorkspaceView.swift
// Notes: Extracted from ProjectWorkspaceView (2026-10-13), then given file management the same
//        day. Decisions:
//        - Selection: a click on a text or Markdown file shows it in the editor (the workspace
//          reacts to the selection), double click opens a file in its default app, Space opens
//          Quick Look. Moved, renamed, duplicated, created and imported items become the
//          selection, so they stay visible (their folders expand) and a single text file opens.
//        - Context menu (VS Code order, Finder words): New File, New Folder | Reference in Claude
//          | Quick Look, Open, Show in Finder | Rename, Duplicate | Copy Path, Copy Relative Path
//          | Move to Trash. New items go into the clicked folder, beside a clicked file, or into
//          the repo root on empty space. Copy Path copies one path per line for a selection.
//        - New File creates an empty "untitled.md" (the editor renders Markdown and the repo is
//          for notes and plans) and New Folder "untitled folder"; both start in rename mode.
//        - Name clash on a move or Option-copy inside the tree: one alert for all clashing
//          items, Keep Both (default, numbers the incoming item " 2") / Replace (the existing
//          item goes to the Trash) / Cancel, like Finder. Replace is not offered when an existing
//          item is one MinuteMind manages. Files dropped from Finder keep the earlier behaviour
//          and are numbered without asking (a copy never loses anything).
//        - Trash keeps its old behaviour: no confirmation (the Trash is the undo).
//        - App-managed parts (meetings/, recordings/, knowledge/, CLAUDE.md; rules and reasons
//          in WorkspaceFileOperations): Rename and New File stay in the menu and explain in a
//          notice at the bottom of the tree why they do not apply, instead of being greyed out
//          without a word. Drags out of them copy.
//        - Renames and moves inside the repo are a rename on disk and run on the main actor so
//          the editor can follow before its next disk check; copies (duplicate, Option-drag,
//          Finder drops) and tree loads run off the main actor. The tree reloads right after
//          every operation and otherwise every 2 s; an older load never overwrites a newer one.
//          Meetings are listed newest first.
//        - Only open folders are read (Finder, VS Code): the top level always, a folder's
//          contents once it is expanded, and the 2 s reload rereads only those. A total entry
//          budget used to cut the tree off silently once cloned repos filled the workspace
//          (folders after the cut were missing); now cost follows what the user opens. One folder
//          lists at most 5,000 entries.
//        - Dotfiles and dot folders are shown, as in VS Code; only .git and .DS_Store stay out
//          (VS Code's default files.exclude), at every depth.
//        - Nothing is committed: the app commits only what it writes itself.
//        - The branch row (WorkspaceGitBranchBar) sits below the tree and its notice, always
//          visible; its messages use the same notice.
//        - Shared Projects: private/ follows the managed-folder rules too (WorkspaceFileOperations,
//          `isShared`). A right click on a meeting or recording folder directly in
//          private/meetings/ or private/recordings/ offers Publish… in its own group after
//          Reference in Claude; an alert confirms it (publishing cannot be recalled), the result
//          shows in the notice. private/meetings/ lists newest first like meetings/.

import AppKit
import QuickLook
import SwiftUI

struct WorkspaceFileTreeView: View {
    let project: Project
    let terminals: WorkspaceTerminalStore
    let repo: URL
    @Binding var selection: Set<URL>
    @Environment(AppViewModel.self) private var viewModel

    /// Folds the tree to its rail (ProjectWorkspaceView); nil: no fold button.
    var onCollapse: (() -> Void)?
    @State private var tree: [FileNode] = []
    @State private var hasLoaded = false
    /// Bumped by every load; a load that finishes after a newer one started is dropped.
    @State private var loadGeneration = 0
    @State private var previewURL: URL?
    @State private var renaming: URL?
    @State private var notice: String?
    @State private var noticeGeneration = 0
    @State private var pendingTransfer: PendingTransfer?
    /// A private meeting or recording folder waiting for the Publish confirmation.
    @State private var pendingPublish: PendingPublish?
    /// Set once a file was opened in the editor; until then the tree explains how.
    @AppStorage("mm.workspaceEditorHintSeen") private var editorHintSeen = false

    private typealias Ops = WorkspaceFileOperations

    /// A move or copy waiting for the user's answer to a name clash.
    private struct PendingTransfer {
        let items: [URL]
        let folder: URL
        let copy: Bool
        let clashes: [URL]
        let canReplace: Bool
    }

    /// A folder in private/meetings/ or private/recordings/ of a Shared Project to publish.
    private struct PendingPublish {
        let url: URL
        /// Repo-relative, as publishPrivateItem takes it.
        let relativePath: String
        var noun: String { relativePath.hasPrefix("\(SharedProjectLayout.privateFolder)/recordings/") ? "recording" : "meeting" }
    }

    private var editor: WorkspaceEditorState { viewModel.workspaceEditors.state(for: project.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            WorkspaceFileOutline(tree: tree, repo: repo, selection: $selection, renaming: renaming,
                                 isShared: project.isShared, actions: actions)
                .overlay {
                    if hasLoaded && tree.isEmpty {
                        Text("Files you and Claude create appear here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                            .allowsHitTesting(false)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                // On the outline, not beside the clash alert: two alerts on one view can swallow each other.
                .alert("Publish to the \(project.name) team?",
                       isPresented: Binding(get: { pendingPublish != nil }, set: { if !$0 { pendingPublish = nil } }),
                       presenting: pendingPublish) { pending in
                    Button("Publish") { publish(pending) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel", role: .cancel) {}
                } message: { pending in
                    Text("The other members of \(project.name) get a copy of this \(pending.noun). Publishing cannot be recalled.")
                }
            Divider()
            WorkspaceGitBranchBar(project: project, repo: repo, terminals: terminals) { show($0) }
        }
        .background(DesignSystem.Colors.surfaceSecondary)
        .quickLookPreview($previewURL)
        .alert(clashTitle, isPresented: Binding(get: { pendingTransfer != nil }, set: { if !$0 { pendingTransfer = nil } }),
               presenting: pendingTransfer) { pending in
            Button("Keep Both") { performTransfer(pending.items, into: pending.folder, copy: pending.copy, resolution: .keepBoth) }
            if pending.canReplace {
                Button("Replace", role: .destructive) {
                    performTransfer(pending.items, into: pending.folder, copy: pending.copy, resolution: .replace)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.canReplace
                 ? "Keep Both adds a number to the name of the incoming \(pending.clashes.count == 1 ? "item" : "items"). Replace moves the existing \(pending.clashes.count == 1 ? "item" : "items") to the Trash."
                 : "Keep Both adds a number to the name of the incoming \(pending.clashes.count == 1 ? "item" : "items").")
        }
        .task(id: repo) {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([repo])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("Hide Files")
                .accessibilityLabel("Hide Files")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let notice {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(notice)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    self.notice = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background.secondary)
        } else if !editorHintSeen {
            Text("Click a file to open it here. Double-click opens it in its app.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary)
        }
    }

    private var clashTitle: String {
        guard let pending = pendingTransfer else { return "" }
        let folder = Ops.isSame(pending.folder, repo) ? "the workspace" : "\"\(pending.folder.lastPathComponent)\""
        if pending.clashes.count == 1, let clash = pending.clashes.first {
            return "An item named \"\(clash.lastPathComponent)\" already exists in \(folder)."
        }
        return "\(pending.clashes.count) items with these names already exist in \(folder)."
    }

    // MARK: - Outline wiring

    private var actions: WorkspaceFileOutlineActions {
        WorkspaceFileOutlineActions(
            menu: { menu(for: $0) },
            open: { urls in urls.forEach { NSWorkspace.shared.open($0) } },
            toggleQuickLook: {
                guard let first = selection.first else { return }
                previewURL = previewURL == nil ? first : nil
            },
            beginRename: { startRename($0) },
            endRename: { finishRename($0, to: $1) },
            trash: { moveToTrash($0) },
            transfer: { requestTransfer($0, into: $1, copy: $2) },
            importFiles: { importFiles($0, into: $1) },
            foldersOpened: { reloadSoon() })
    }

    private func menu(for urls: [URL]) -> [WorkspaceTreeMenuEntry] {
        let target = folderForNewItems(urls)
        var entries: [WorkspaceTreeMenuEntry] = [
            .item("New File") { create(folder: false, in: target) },
            .item("New Folder") { create(folder: true, in: target) },
        ]
        guard !urls.isEmpty else { return entries }
        let urlSet = Set(urls)
        entries.append(.separator)
        let claudeSessions = terminals.sessions(rootedAt: project.id).filter { $0.foreground == .claude }
        if claudeSessions.count > 1 {
            entries.append(.submenu(title: "Reference in Claude", claudeSessions.map { session in
                .item(session.displayName) { reference(urlSet, in: session) }
            }))
        } else {
            entries.append(.item("Reference in Claude", enabled: !claudeSessions.isEmpty) {
                if let session = claudeSessions.first { reference(urlSet, in: session) }
            })
        }
        if project.isShared, urls.count == 1, let url = urls.first, let path = Ops.publishablePath(url, in: repo) {
            entries += [.separator, .item("Publish…") { pendingPublish = PendingPublish(url: url, relativePath: path) }]
        }
        entries += [
            .separator,
            .item("Quick Look") { previewURL = urls.first },
            .item("Open") { urls.forEach { NSWorkspace.shared.open($0) } },
            .item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) },
            .separator,
            .item("Rename", enabled: urls.count == 1, shortcut: ("\r", [])) { if let url = urls.first { startRename(url) } },
            .item("Duplicate") { duplicate(urls) },
            .separator,
            .item("Copy Path") { copyToPasteboard(urls.map(\.path)) },
            .item("Copy Relative Path") { copyToPasteboard(urls.map { Ops.relativePath($0, in: repo) }) },
            .separator,
            .item("Move to Trash", shortcut: ("\u{8}", .command)) { moveToTrash(urls) },
        ]
        return entries
    }

    /// The clicked folder, the folder of a clicked file, or the repo root for empty space.
    private func folderForNewItems(_ urls: [URL]) -> URL {
        guard let first = urls.first else { return repo }
        return urls.count == 1 && Ops.isDirectory(first) ? first : first.deletingLastPathComponent()
    }

    // MARK: - Operations

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let repo = self.repo
        let open = WorkspaceTreeExpansion.byRepo[WorkspaceTreeExpansion.key(repo)] ?? []
        let loaded = await Task.detached(priority: .userInitiated) { FileNode.load(repo, open: open) }.value
        guard generation == loadGeneration else { return }
        if loaded != tree { tree = loaded }
        hasLoaded = true
    }

    private func reloadSoon() { Task { await reload() } }

    private func show(_ message: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(8))
            if noticeGeneration == generation { notice = nil }
        }
    }

    private func show(_ error: any Error) { show(error.localizedDescription) }

    /// The open file and expanded folders follow, the moved items become the selection.
    private func followMoves(_ moves: [Ops.Move]) {
        guard !moves.isEmpty else { return }
        for move in moves { editor.documentMoved(from: move.from, to: move.to) }
        WorkspaceTreeExpansion.remap(repo: repo, moves: moves)
        selection = Set(moves.map(\.to))
        reloadSoon()
    }

    private func create(folder: Bool, in directory: URL) {
        if let refusal = Ops.dropRefusal(into: directory, in: repo, isShared: project.isShared) { show(refusal); return }
        do {
            let url = folder ? try Ops.createFolder(in: directory) : try Ops.createFile(in: directory)
            selection = [url]
            renaming = url
            reloadSoon()
        } catch {
            show(error)
        }
    }

    private func startRename(_ url: URL) {
        if let reason = Ops.lockReason(for: url, in: repo, isShared: project.isShared) { show(reason); return }
        selection = [url]
        renaming = url
    }

    private func finishRename(_ url: URL, to name: String?) {
        renaming = nil
        guard let name, name.trimmingCharacters(in: .whitespacesAndNewlines) != url.lastPathComponent else { return }
        do {
            let renamed = try Ops.rename(url, to: name)
            followMoves([Ops.Move(from: url, to: renamed)])
        } catch {
            show(error)
        }
    }

    private func requestTransfer(_ items: [URL], into folder: URL, copy: Bool) {
        if let refusal = Ops.dropRefusal(into: folder, in: repo, isShared: project.isShared) { show(refusal); return }
        if let refusal = Ops.privateLeakRefusal(items, into: folder, in: repo, isShared: project.isShared) { show(refusal); return }
        let clashes = Ops.clashes(items, into: folder, copy: copy)
        guard !clashes.isEmpty else {
            performTransfer(items, into: folder, copy: copy, resolution: .keepBoth)
            return
        }
        pendingTransfer = PendingTransfer(
            items: items, folder: folder, copy: copy, clashes: clashes,
            canReplace: clashes.allSatisfy { Ops.lockReason(for: $0, in: repo, isShared: project.isShared) == nil })
    }

    private func performTransfer(_ items: [URL], into folder: URL, copy: Bool, resolution: Ops.ClashResolution) {
        guard copy else {
            do {
                let outcome = try Ops.transfer(items, into: folder, copy: false, resolution: resolution)
                followMoves(outcome.moves)
                if let failure = outcome.failure { show(failure); reloadSoon() }
            } catch {
                show(error)
            }
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Ops.transfer(items, into: folder, copy: true, resolution: resolution) }
            }.value
            switch result {
            case .success(let outcome):
                if !outcome.moves.isEmpty { selection = Set(outcome.moves.map(\.to)) }
                if let failure = outcome.failure { show(failure) }
            case .failure(let error):
                show(error)
            }
            await reload()
        }
    }

    private func importFiles(_ files: [URL], into folder: URL) {
        if let refusal = Ops.dropRefusal(into: folder, in: repo, isShared: project.isShared) { show(refusal); return }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Ops.importItems(files, into: folder) }.value
            if !outcome.moves.isEmpty { selection = Set(outcome.moves.map(\.to)) }
            if let failure = outcome.failure { show(failure) }
            await reload()
        }
    }

    private func duplicate(_ urls: [URL]) {
        if let refusal = urls.lazy.compactMap({ Ops.dropRefusal(into: $0.deletingLastPathComponent(), in: repo, isShared: project.isShared) }).first {
            show(refusal)
            return
        }
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                urls.map { url in Result { try Ops.duplicate(url) } }
            }.value
            let copies = results.compactMap { try? $0.get() }
            if !copies.isEmpty { selection = Set(copies) }
            for case .failure(let error) in results { show(error); break }
            await reload()
        }
    }

    /// Publishes a private meeting or recording folder; the flow moves it out of private/.
    private func publish(_ pending: PendingPublish) {
        let name = pending.url.lastPathComponent
        let projectName = project.name
        Task {
            let published = await viewModel.publishPrivateItem(relativePath: pending.relativePath, projectID: project.id)
            if published {
                selection = selection.filter { !Ops.isSameOrInside($0, pending.url) }
                show("\"\(name)\" is published to the \(projectName) team.")
            } else {
                show("\"\(name)\" could not be published.")
            }
            await reload()
        }
    }

    private func moveToTrash(_ urls: [URL]) {
        urls.forEach { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        selection.subtract(urls)
        reloadSoon()
    }

    private func copyToPasteboard(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Types @path references for the files into the session's Claude prompt.
    private func reference(_ urls: Set<URL>, in session: WorkspaceTerminalSession) {
        let references = urls.sorted { $0.path < $1.path }.map { url -> String in
            let relative = url.path.replacingOccurrences(of: repo.path + "/", with: "")
            return "@" + (relative.contains(" ") ? "\"\(relative)\"" : relative)
        }
        terminals.send(references.joined(separator: " ") + " ", to: session)
    }
}

/// A file or folder in the project repo.
struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// A folder's contents; empty for files and for folders not read (closed ones).
    let children: [FileNode]
    /// The folder was read: its `children` are its contents.
    let isLoaded: Bool

    var id: URL { url }

    /// Dotfiles and dot folders are listed (.gitignore, .claude, .minutemind), like VS Code;
    /// only what VS Code leaves out by default stays hidden (git's database, Finder's metadata).
    private static let excludedNames: Set<String> = [".git", ".DS_Store"]
    private static func isHidden(_ name: String) -> Bool { excludedNames.contains(name) }

    /// Most entries listed for one folder; a runaway folder cannot stall the tree.
    static let maxEntriesPerFolder = 5000

    /// Loads a folder: folders first, then files, both alphabetically; inside `meetings/` and
    /// `private/meetings/` newest first (folder names start with the date). Subfolders are read only when their path is in
    /// `open` (the expanded folders, `WorkspaceTreeExpansion.key` form); the others stay unread.
    static func load(_ directory: URL, open: Set<String>, depth: Int = 0) -> [FileNode] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        else { return [] }
        var nodes: [FileNode] = []
        for url in entries.prefix(maxEntriesPerFolder) where !isHidden(url.lastPathComponent) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isOpen = isDirectory && open.contains(WorkspaceTreeExpansion.key(url))
            nodes.append(FileNode(
                url: url, name: url.lastPathComponent, isDirectory: isDirectory,
                children: isOpen ? load(url, open: open, depth: depth + 1) : [],
                isLoaded: isOpen))
        }
        let newestFirst = directory.lastPathComponent == "meetings"
            && (depth == 1 || (depth == 2 && directory.deletingLastPathComponent().lastPathComponent == SharedProjectLayout.privateFolder))
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let ascending = $0.name.localizedStandardCompare($1.name) == .orderedAscending
            return newestFirst ? !ascending : ascending
        }
    }
}
