// Purpose: WorkspaceEditorStore, the file open in each project workspace's editor: text (unsaved
//          text, autosave, reload when Claude changes the file on disk) or an image or PDF shown
//          inline (reloaded when it changes on disk).
// Dependencies: Sources/App/Supporting/WorkspaceFileKinds.swift (what opens, and how), Foundation
// Used by: Sources/App/ViewModels/AppViewModel.swift (workspaceEditors),
//          Sources/App/Views/WorkspaceEditorPane.swift, Sources/App/Views/ProjectWorkspaceView.swift,
//          Sources/App/Views/WorkspaceFileTreeView.swift (documentMoved after tree moves and renames)
// Notes: Lives in AppViewModel (like WorkspaceTerminalStore) so the open file and its state
//        survive tab and project switches. One file per workspace, no editor tabs (design
//        review 3, point 4: preview tabs are a developer convention); clicking another file
//        saves and replaces it. Editing autosaves 0.8 s after the last keystroke, plus on Cmd+S,
//        on close and when the workspace disappears. A file changed on disk reloads while its
//        buffer is clean (the header says "Updated on disk" for a moment); with unsaved edits a
//        conflict is flagged and the editor asks (Reload / Keep Mine). A deleted file keeps its
//        text and offers Save Again / Close.
//        What opens (2026-10-13, "all common formats, like VS Code"): every file that
//        WorkspaceFileKind calls text, plus images and PDFs, which show inline (read only; their
//        `revision` goes up when the file changes on disk so the view reloads). Text up to 2 MB
//        is editable; 2 to 10 MB opens read-only (every keystroke would copy and compare the
//        whole buffer, and autosave would rewrite it); above 10 MB, or text that is not valid
//        UTF-8, nothing opens and the file keeps Quick Look and the default app. Saving is a
//        no-op for read-only documents, so Keep Mine can never write over an image.
//        A move or rename in the file tree calls documentMoved(from:to:) (2026-10-13): the open
//        document keeps its buffer and follows the new path, also when a folder containing it
//        moved; only changes made elsewhere (Claude, Finder) still read as a deletion.

import Foundation
import Observation

@Observable
@MainActor
final class WorkspaceDocument {
    enum Conflict: Equatable { case changedOnDisk, deletedOnDisk }
    enum Event: Equatable { case saved, updatedOnDisk }

    /// Changes only when the file tree moves or renames the file (`relocate(to:)`).
    private(set) var url: URL
    /// Text (with its highlight.js language), image or PDF; fixed for the document's life.
    let kind: WorkspaceFileKind
    /// Large text and every image or PDF: shown, never written.
    let isReadOnly: Bool
    /// Goes up when an image or PDF changed on disk, so its view reloads.
    private(set) var revision = 0
    private(set) var savedText: String
    var text: String {
        didSet { if text != oldValue { scheduleAutosave() } }
    }
    /// Markdown shows rendered unless the user switched to editing.
    var isEditingMarkdown = false
    private(set) var conflict: Conflict?
    private(set) var saveError: String?
    /// The last save or reload, shown briefly in the editor header.
    private(set) var lastEvent: (kind: Event, at: Date)?
    @ObservationIgnored private var diskDate: Date?
    @ObservationIgnored private var autosave: Task<Void, Never>?

    var isDirty: Bool { text != savedText }
    var isMarkdown: Bool { kind.isText && ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) }

    fileprivate init(url: URL, opened: WorkspaceEditorStore.Opened) {
        self.url = url
        self.kind = opened.kind
        self.isReadOnly = opened.isReadOnly
        self.text = opened.text
        self.savedText = opened.text
        self.diskDate = Self.modificationDate(url)
    }

    func save() {
        autosave?.cancel()
        guard !isReadOnly, isDirty || conflict == .deletedOnDisk else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            diskDate = Self.modificationDate(url)
            conflict = nil
            saveError = nil
            lastEvent = (.saved, Date())
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Takes the disk version, dropping unsaved edits.
    func reloadFromDisk() {
        guard kind.isText, let loaded = WorkspaceEditorStore.readText(url, limit: textLimit) else { return }
        take(loaded)
    }

    /// Keeps the edits and writes them over the disk version (or recreates a deleted file).
    func keepMine() {
        conflict = .deletedOnDisk  // forces the write even if the text equals the last save
        save()
    }

    /// The file was moved or renamed (by the file tree): keep the buffer, follow the new path.
    /// A pending autosave writes to the new path, since it reads `url` when it fires.
    fileprivate func relocate(to newURL: URL) {
        url = newURL
        diskDate = Self.modificationDate(newURL)
    }

    /// Follows the file on disk. Returns false when it is gone and the buffer is clean.
    fileprivate func checkDisk() -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if isDirty || conflict != nil {
                if conflict != .deletedOnDisk { conflict = .deletedOnDisk }
                return true
            }
            return false
        }
        if conflict == .deletedOnDisk, !isDirty { conflict = nil }
        let date = Self.modificationDate(url)
        guard date != diskDate else { return true }
        if !kind.isText {
            diskDate = date
            revision += 1
            lastEvent = (.updatedOnDisk, Date())
        } else if isDirty {
            if conflict != .changedOnDisk { conflict = .changedOnDisk }
        } else if let loaded = WorkspaceEditorStore.readText(url, limit: textLimit) {
            if loaded != text { lastEvent = (.updatedOnDisk, Date()) }
            take(loaded)
        }
        return true
    }

    private func take(_ loaded: String) {
        savedText = loaded
        text = loaded
        autosave?.cancel()
        diskDate = Self.modificationDate(url)
        conflict = nil
    }

    /// Read-only text follows the disk up to the read-only limit, editable text up to its own.
    private var textLimit: Int { isReadOnly ? WorkspaceEditorStore.maxReadOnlyBytes : WorkspaceEditorStore.maxBytes }

    private func scheduleAutosave() {
        autosave?.cancel()
        guard conflict == nil, !isReadOnly else { return }
        autosave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        // FileManager, not URL resource values: those are cached per URL and would hide Claude's edits.
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// What one workspace's editor shows.
@Observable
@MainActor
final class WorkspaceEditorState {
    private(set) var document: WorkspaceDocument?

    /// Shows the file in the editor, saving the previous one. Returns false when the editor
    /// cannot show it (the editor then stays as it is).
    @discardableResult
    func open(_ url: URL) -> Bool {
        if document?.url == url { return true }
        guard let opened = WorkspaceEditorStore.open(url) else { return false }
        document?.save()
        let next = WorkspaceDocument(url: url, opened: opened)
        next.isEditingMarkdown = document?.isEditingMarkdown ?? false
        document = next
        return true
    }

    func close() {
        document?.save()
        document = nil
    }

    func save() { document?.save() }

    /// The file tree moved or renamed `from` (a file, or a folder) to `to`: when that is the open
    /// file or a folder containing it, the editor follows the new path instead of reporting the
    /// file as deleted. Call it right after the move, before the next `refreshFromDisk`.
    func documentMoved(from: URL, to: URL) {
        guard let document else { return }
        let old = from.standardizedFileURL.pathComponents
        let path = document.url.standardizedFileURL.pathComponents
        guard path.count >= old.count, Array(path.prefix(old.count)) == old else { return }
        let moved = path.dropFirst(old.count).reduce(to) { $0.appendingPathComponent($1) }
        document.relocate(to: moved)
    }

    /// Follows changes Claude (or anyone) made on disk; closes the editor for a deleted clean file.
    func refreshFromDisk() {
        if let document, !document.checkDisk() { self.document = nil }
    }
}

@MainActor
final class WorkspaceEditorStore {
    private var states: [UUID: WorkspaceEditorState] = [:]

    func state(for projectID: UUID) -> WorkspaceEditorState {
        if let state = states[projectID] { return state }
        let state = WorkspaceEditorState()
        states[projectID] = state
        return state
    }

    /// Text up to this size is editable.
    nonisolated static let maxBytes = 2 * 1024 * 1024
    /// Text up to this size opens read-only; larger files do not open.
    nonisolated static let maxReadOnlyBytes = 10 * 1024 * 1024

    /// A file as the editor opens it.
    struct Opened: Sendable {
        let kind: WorkspaceFileKind
        let text: String
        let isReadOnly: Bool
    }

    /// Whether the file opens as text (by name or extension, else by content).
    nonisolated static func isEditable(_ url: URL) -> Bool {
        (WorkspaceFileKind.detectByName(url) ?? WorkspaceFileKind.detect(url))?.isText == true
    }

    /// The file as the editor shows it, or nil when it stays with Quick Look and its app.
    nonisolated static func open(_ url: URL) -> Opened? {
        guard let kind = WorkspaceFileKind.detect(url) else { return nil }
        guard kind.isText else { return Opened(kind: kind, text: "", isReadOnly: true) }
        guard let size = fileSize(url), size <= maxReadOnlyBytes,
              let text = readText(url, limit: maxReadOnlyBytes) else { return nil }
        return Opened(kind: kind, text: text, isReadOnly: size > maxBytes)
    }

    /// The file's text if it is at most `limit` bytes and valid UTF-8.
    nonisolated static func readText(_ url: URL, limit: Int) -> String? {
        guard let size = fileSize(url), size <= limit,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    /// Splits YAML frontmatter ("---" ... "---" at the top) from the Markdown body, so the
    /// preview can show it as a metadata row; MarkdownUI would render it as text.
    nonisolated static func splitFrontmatter(_ text: String) -> (fields: [(key: String, value: String)], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([], text) }
        let fields = lines[1..<end].compactMap { line -> (key: String, value: String)? in
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard !key.isEmpty, !value.isEmpty else { return nil }
            return (key, value)
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }
}
