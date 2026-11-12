// Purpose: WorkspaceFileOutline, the AppKit outline view behind the workspace file tree: rows,
//          selection, expansion, drag and drop inside the tree and from Finder, inline rename
//          and the tree's keys. It reports intents; WorkspaceFileTreeView does the file work.
// Dependencies: AppKit (NSOutlineView), Sources/App/Supporting/WorkspaceFileOperations.swift
//               (paths, drop rules), FileNode (Sources/App/Views/WorkspaceFileTreeView.swift)
// Used by: Sources/App/Views/WorkspaceFileTreeView.swift
// Notes: NSOutlineView instead of a SwiftUI List (decided 2026-10-13): on macOS 14 a List
//        drags only the row under the pointer (not the selection), OutlineGroup's expansion
//        cannot be set from code (needed to reveal a moved item), and List has no drop-on-folder
//        highlight. The outline gives Finder's behaviour natively: dragging a selected row drags
//        all selected rows, folders highlight as targets, a drop on a file goes into its folder,
//        a drop on empty space goes to the repo root.
//        Drags inside the tree move; Option-drag copies (Finder); items MinuteMind manages are
//        always copied out (their originals stay where the app expects them). Drags to Finder or
//        the terminal copy and never take a file out of the repo. Drops into managed folders
//        show no target.
//        Rename edits the row in place: Return or Enter on one selected row (Finder), the menu,
//        or right after New File / New Folder. Return commits, Esc cancels, clicking elsewhere
//        commits (Finder). The name is selected without its extension. Rows are never edited
//        by clicking a selected name, because a click on a text file already opens it in the
//        editor and a slow second click would start a rename by accident.
//        Keys: Space toggles Quick Look, Cmd+Delete or Forward Delete moves the selection to the
//        Trash (Finder's shortcut; plain Delete does nothing, so a stray key press while the
//        tree has focus trashes nothing). Double click opens a file in its default app and
//        toggles a folder (the tree is where folders are browsed).
//        Expansion is kept per repo for the app session (WorkspaceTreeExpansion), so tab and
//        project switches and moves keep folders open; a moved item's parents are expanded so it
//        stays visible and selected. Reloads wait while a row is being renamed or a drag runs.
//        Closed folders are not read (FileNode.load): expanding one reads it on the spot, so it
//        opens with its contents, and asks the owner to reload; revealing an item inside unread
//        folders marks them open first.

import AppKit
import SwiftUI

/// One entry of the tree's context menu, built by WorkspaceFileTreeView.
enum WorkspaceTreeMenuEntry {
    case action(title: String, enabled: Bool, shortcut: (key: String, modifiers: NSEvent.ModifierFlags)?, perform: @MainActor () -> Void)
    case submenu(title: String, [WorkspaceTreeMenuEntry])
    case separator

    static func item(_ title: String, enabled: Bool = true,
                     shortcut: (key: String, modifiers: NSEvent.ModifierFlags)? = nil,
                     _ perform: @escaping @MainActor () -> Void) -> Self {
        .action(title: title, enabled: enabled, shortcut: shortcut, perform: perform)
    }
}

/// What the outline asks its owner to do.
struct WorkspaceFileOutlineActions {
    /// Menu for the clicked items (the selection when the click was on it), empty for empty space.
    var menu: @MainActor ([URL]) -> [WorkspaceTreeMenuEntry]
    var open: @MainActor ([URL]) -> Void
    var toggleQuickLook: @MainActor () -> Void
    var beginRename: @MainActor (URL) -> Void
    /// The new name, or nil when the rename was cancelled.
    var endRename: @MainActor (URL, String?) -> Void
    var trash: @MainActor ([URL]) -> Void
    /// Items dragged inside the tree, the folder they were dropped on, and whether to copy.
    var transfer: @MainActor ([URL], URL, Bool) -> Void
    /// Files dropped from outside the app.
    var importFiles: @MainActor ([URL], URL) -> Void
    /// Folders were expanded whose contents the tree has not read yet; reload it.
    var foldersOpened: @MainActor () -> Void
}

/// Expanded folders per repo, for the app session.
@MainActor
enum WorkspaceTreeExpansion {
    static var byRepo: [String: Set<String>] = [:]

    nonisolated static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Moved folders stay expanded at their new place.
    static func remap(repo: URL, moves: [WorkspaceFileOperations.Move]) {
        guard let expanded = byRepo[key(repo)], !moves.isEmpty else { return }
        byRepo[key(repo)] = Set(expanded.map { path in
            WorkspaceFileOperations.relocated(URL(fileURLWithPath: path), by: moves).map(key) ?? path
        })
    }
}

struct WorkspaceFileOutline: NSViewRepresentable {
    let tree: [FileNode]
    let repo: URL
    @Binding var selection: Set<URL>
    /// The item whose name is being edited (set by the owner for Rename and new items).
    let renaming: URL?
    /// A Shared Project's repo: private/ follows the managed-folder rules too.
    var isShared = false
    let actions: WorkspaceFileOutlineActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let outline = FileOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.rowHeight = 22
        outline.backgroundColor = .clear
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        outline.keyHandler = coordinator
        coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        outline.sizeLastColumnToFit()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        weak var outline: FileOutlineView?
        private var parent: WorkspaceFileOutline?
        private var roots: [FileTreeItem] = []
        private var items: [String: FileTreeItem] = [:]
        private var shownTree: [FileNode]?
        /// The owner's selection as last applied (or reported), to tell its changes apart.
        private var appliedSelection: Set<URL> = []
        /// Newly selected items not shown yet (a move before the reload): revealed when they appear.
        private var pendingReveal: Set<String> = []
        private var isApplying = false
        private var isDragging = false
        private var editingItem: FileTreeItem?
        private var editCancelled = false
        private var reloadRequested = false

        private static let cellID = NSUserInterfaceItemIdentifier("WorkspaceFileCell")

        private var repoKey: String { parent.map { WorkspaceTreeExpansion.key($0.repo) } ?? "" }
        private var expanded: Set<String> {
            get { WorkspaceTreeExpansion.byRepo[repoKey] ?? [] }
            set { WorkspaceTreeExpansion.byRepo[repoKey] = newValue }
        }

        func update(from parent: WorkspaceFileOutline) {
            self.parent = parent
            guard outline != nil, editingItem == nil else { return }
            if !isDragging, parent.tree != shownTree { reload(parent.tree) }
            syncSelection(parent.selection)
            if let renaming = parent.renaming { beginEditing(renaming) }
        }

        // MARK: Tree

        private func reload(_ tree: [FileNode]) {
            guard let outline else { return }
            shownTree = tree
            var next: [String: FileTreeItem] = [:]
            func build(_ node: FileNode) -> FileTreeItem {
                let key = WorkspaceTreeExpansion.key(node.url)
                // The same object for the same path keeps NSOutlineView's row state.
                let item = items[key].flatMap { $0.isDirectory == node.isDirectory ? $0 : nil }
                    ?? FileTreeItem(url: node.url, isDirectory: node.isDirectory)
                item.url = node.url
                item.children = node.children.map(build)
                item.isLoaded = node.isLoaded
                next[key] = item
                return item
            }
            roots = tree.map(build)
            items = next
            isApplying = true
            outline.reloadData()
            let open = expanded
            func expand(_ list: [FileTreeItem]) {
                for item in list where item.isDirectory && open.contains(WorkspaceTreeExpansion.key(item.url)) {
                    outline.expandItem(item)
                    expand(item.children)
                }
            }
            expand(roots)
            isApplying = false
        }

        private func children(of item: Any?) -> [FileTreeItem] {
            (item as? FileTreeItem)?.children ?? roots
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileTreeItem)?.isDirectory ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? FileTreeItem else { return nil }
            let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: nil) as? FileCellView ?? FileCellView()
            cell.identifier = Self.cellID
            cell.show(item)
            return cell
        }

        /// Typing a name jumps to it, as in Finder.
        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            (item as? FileTreeItem)?.url.lastPathComponent
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? FileTreeItem else { return }
            expanded.insert(WorkspaceTreeExpansion.key(item.url))
            guard !item.isLoaded else { return }
            // Read this one folder now so it opens with its contents; the owner's reload then
            // takes over (and reads the folders inside that were open before).
            item.isLoaded = true
            item.children = FileNode.load(item.url, open: []).map { node in
                let child = FileTreeItem(url: node.url, isDirectory: node.isDirectory)
                items[WorkspaceTreeExpansion.key(node.url)] = child
                return child
            }
            outline?.reloadItem(item, reloadChildren: true)
            requestReload()
        }

        /// Asks the owner for a reload once, after the current expansions settle.
        private func requestReload() {
            guard !reloadRequested else { return }
            reloadRequested = true
            DispatchQueue.main.async { [weak self] in
                self?.reloadRequested = false
                self?.parent?.actions.foldersOpened()
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isApplying, let item = notification.userInfo?["NSObject"] as? FileTreeItem else { return }
            expanded.remove(WorkspaceTreeExpansion.key(item.url))
        }

        /// Marks the folders above a path (inside the repo) open and asks for a reload.
        private func openAncestors(ofPath path: String) {
            guard let repo = parent?.repo else { return }
            var current = URL(fileURLWithPath: path).deletingLastPathComponent()
            var opened = expanded
            while WorkspaceFileOperations.isSameOrInside(current, repo), !WorkspaceFileOperations.isSame(current, repo) {
                opened.insert(WorkspaceTreeExpansion.key(current))
                current = current.deletingLastPathComponent()
            }
            guard opened != expanded else { return }
            expanded = opened
            requestReload()
        }

        private func expandAncestors(of url: URL) {
            guard let outline, let repo = parent?.repo else { return }
            var chain: [FileTreeItem] = []
            var current = url.deletingLastPathComponent()
            while WorkspaceFileOperations.isSameOrInside(current, repo), !WorkspaceFileOperations.isSame(current, repo) {
                if let item = items[WorkspaceTreeExpansion.key(current)] { chain.append(item) }
                current = current.deletingLastPathComponent()
            }
            for item in chain.reversed() { outline.expandItem(item) }
        }

        // MARK: Selection

        private var selectedItems: [FileTreeItem] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileTreeItem }
        }

        private func syncSelection(_ wanted: Set<URL>) {
            guard let outline else { return }
            let keys = Set(wanted.map(WorkspaceTreeExpansion.key))
            if wanted != appliedSelection {
                appliedSelection = wanted
                pendingReveal = keys
            }
            var revealed = false
            for key in pendingReveal {
                guard let item = items[key] else {
                    // Inside a folder not read yet: open its folders so the next reload shows it.
                    openAncestors(ofPath: key)
                    continue
                }
                expandAncestors(of: item.url)
                pendingReveal.remove(key)
                revealed = true
            }
            let rows = IndexSet(keys.compactMap { items[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
            if rows != outline.selectedRowIndexes {
                isApplying = true
                outline.selectRowIndexes(rows, byExtendingSelection: false)
                isApplying = false
            }
            if revealed, let first = rows.first { outline.scrollRowToVisible(first) }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let parent else { return }
            let urls = Set(selectedItems.map(\.url))
            appliedSelection = urls
            pendingReveal = []
            parent.selection = urls
        }

        // MARK: Rename

        private func beginEditing(_ url: URL) {
            guard let outline, outline.window != nil,
                  let item = items[WorkspaceTreeExpansion.key(url)] else { return }  // retried once it shows
            expandAncestors(of: item.url)
            let row = outline.row(forItem: item)
            guard row >= 0 else { return }
            outline.scrollRowToVisible(row)
            if outline.selectedRowIndexes != IndexSet(integer: row) {
                isApplying = true
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isApplying = false
            }
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView,
                  let field = cell.textField else { return }
            editingItem = item
            editCancelled = false
            cell.setEditing(true)
            field.delegate = self
            outline.window?.makeFirstResponder(field)
            // Finder selects the name without its extension.
            let name = item.url.lastPathComponent as NSString
            let stem = item.isDirectory ? name.length : name.deletingPathExtension.utf16.count
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: stem > 0 ? stem : name.length)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            editCancelled = true
            outline?.window?.makeFirstResponder(outline)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let item = editingItem else { return }
            let name = editCancelled ? nil : field.stringValue
            field.delegate = nil
            field.stringValue = item.url.lastPathComponent
            (field.superview as? FileCellView)?.setEditing(false)
            editingItem = nil
            let movement = notification.userInfo?["NSTextMovement"] as? Int
            if movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue {
                outline?.window?.makeFirstResponder(outline)
            }
            parent?.actions.endRename(item.url, name)
        }

        // MARK: Keys, clicks, menu

        /// Returns true when the key was the tree's.
        func handleKey(_ event: NSEvent) -> Bool {
            guard let parent else { return false }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            let selected = selectedItems.map(\.url)
            switch event.keyCode {
            case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty:  // Return, Enter
                guard selected.count == 1, let url = selected.first else { return false }
                parent.actions.beginRename(url)
                return true
            case 49 where modifiers.isEmpty:  // Space
                parent.actions.toggleQuickLook()
                return true
            case 51 where modifiers == .command, 117 where modifiers.isEmpty:  // Cmd+Delete, Forward Delete
                guard !selected.isEmpty else { return false }
                parent.actions.trash(selected)
                return true
            default:
                return false
            }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, let parent, outline.clickedRow >= 0,
                  let item = outline.item(atRow: outline.clickedRow) as? FileTreeItem else { return }
            if item.isDirectory {
                if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
                return
            }
            let urls = outline.selectedRowIndexes.contains(outline.clickedRow)
                ? selectedItems.filter { !$0.isDirectory }.map(\.url) : [item.url]
            parent.actions.open(urls)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, let parent else { return }
            var urls: [URL] = []
            let row = outline.clickedRow
            if row >= 0, let item = outline.item(atRow: row) as? FileTreeItem {
                urls = outline.selectedRowIndexes.contains(row) ? selectedItems.map(\.url) : [item.url]
            }
            for entry in parent.actions.menu(urls) { menu.addItem(Self.menuItem(entry)) }
        }

        private static func menuItem(_ entry: WorkspaceTreeMenuEntry) -> NSMenuItem {
            switch entry {
            case .separator:
                return .separator()
            case let .submenu(title, entries):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                for child in entries { submenu.addItem(menuItem(child)) }
                item.submenu = submenu
                return item
            case let .action(title, enabled, shortcut, perform):
                let action = MenuAction(perform)
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
                item.target = action
                item.representedObject = action
                item.isEnabled = enabled
                if let shortcut {
                    item.keyEquivalent = shortcut.key
                    item.keyEquivalentModifierMask = shortcut.modifiers
                }
                return item
            }
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard editingItem == nil, let item = item as? FileTreeItem else { return nil }
            return item.url as NSURL
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
            isDragging = true
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            isDragging = false
            if let parent { update(from: parent) }
        }

        private static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        /// Copy instead of move: Option held (the source then offers copy only) or a managed item.
        private func copies(_ info: NSDraggingInfo, _ urls: [URL], repo: URL) -> Bool {
            !info.draggingSourceOperationMask.contains(.move)
                || urls.contains { WorkspaceFileOperations.lockReason(for: $0, in: repo, isShared: parent?.isShared ?? false) != nil }
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let parent else { return [] }
            let urls = Self.fileURLs(info)
            guard !urls.isEmpty else { return [] }
            // A drop on a file goes into its folder; between rows into the folder around them.
            var target = item as? FileTreeItem
            if let file = target, !file.isDirectory { target = outlineView.parent(forItem: file) as? FileTreeItem }
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            let folder = target?.url ?? parent.repo
            guard WorkspaceFileOperations.dropRefusal(into: folder, in: parent.repo, isShared: parent.isShared) == nil,
                  WorkspaceFileOperations.privateLeakRefusal(urls, into: folder, in: parent.repo, isShared: parent.isShared) == nil
            else { return [] }
            guard (info.draggingSource as? NSOutlineView) === outlineView else { return .copy }
            if urls.contains(where: { WorkspaceFileOperations.isSameOrInside(folder, $0) }) { return [] }
            if copies(info, urls, repo: parent.repo) { return .copy }
            let staying = urls.allSatisfy { WorkspaceFileOperations.isSame($0.deletingLastPathComponent(), folder) }
            return staying ? [] : .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let parent else { return false }
            let urls = Self.fileURLs(info)
            guard !urls.isEmpty else { return false }
            let folder = (item as? FileTreeItem)?.url ?? parent.repo
            if (info.draggingSource as? NSOutlineView) === outlineView {
                parent.actions.transfer(urls, folder, copies(info, urls, repo: parent.repo))
            } else {
                parent.actions.importFiles(urls, folder)
            }
            return true
        }
    }
}

/// A row's model object; the same instance per path across reloads.
final class FileTreeItem: NSObject {
    var url: URL
    let isDirectory: Bool
    var children: [FileTreeItem] = []
    /// A folder whose contents were read (closed folders are not).
    var isLoaded = false

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

/// The outline with the tree's keys (Return renames, Space previews, Cmd+Delete trashes).
final class FileOutlineView: NSOutlineView {
    weak var keyHandler: WorkspaceFileOutline.Coordinator?

    override func keyDown(with event: NSEvent) {
        if keyHandler?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Icon and name; the name turns into a text field while renaming.
private final class FileCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingTail
        name.cell?.usesSingleLineMode = true
        name.cell?.wraps = false
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(icon)
        addSubview(name)
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ item: FileTreeItem) {
        name.stringValue = item.url.lastPathComponent
        icon.image = NSWorkspace.shared.icon(forFile: item.url.path)
    }

    func setEditing(_ editing: Bool) {
        name.isEditable = editing
        name.isSelectable = editing
        name.drawsBackground = editing
        name.backgroundColor = editing ? .textBackgroundColor : .clear
        name.focusRingType = editing ? .exterior : .none
    }
}

/// Runs a menu item's closure; kept alive as the item's representedObject (targets are weak).
@MainActor
private final class MenuAction: NSObject {
    private let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }

    @objc func run(_ sender: Any?) { perform() }
}
