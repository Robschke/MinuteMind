// Purpose: WorkspaceFileOperations, the FileManager side of the workspace file tree: move and
//          copy into folders, rename, new file and folder, duplicate, name clashes, and the rules
//          for the parts of a project repo that MinuteMind manages.
// Dependencies: Foundation (FileManager); mirrors the repo layout of
//               Sources/App/Services/ProjectRepositoryService.swift (meetings/, recordings/,
//               knowledge/, CLAUDE.md, .minutemind/) without calling it, and of
//               Sources/App/Models/SharedProject.swift (SharedProjectLayout: private/).
// Used by: Sources/App/Views/WorkspaceFileTreeView.swift, Sources/App/Views/WorkspaceFileOutlineView.swift,
//          Tests/WorkspaceFileOperationsTests.swift, Tests/SharedProjectUITests.swift
// Notes: Pure static functions so they can run off the main actor (copies) and be tested in a
//        temp folder. Paths are compared by standardized components, never by URL equality
//        (folder URLs may or may not carry a trailing slash).
//        Managed parts (decided 2026-10-13 after reading ProjectRepositoryService): meeting and
//        recording folders are found through .minutemind/meetings.json and recordings.json by
//        folder name, so a moved or renamed folder would be written again on the next mirror (a
//        duplicate), its knowledge citations would point nowhere, and a meeting moved to another
//        project deletes its folder with everything inside. Hence meetings/ and recordings/ and
//        everything in them cannot be moved or renamed, nothing can be moved or created in
//        them, and a drag out of them copies. knowledge/ and CLAUDE.md keep their name and
//        place (the curator and the managed CLAUDE.md block expect them there); the files in
//        knowledge/ are the user's to organise. Trash keeps working everywhere as before.
//        In a Shared Project (`isShared`), private/ mirrors that layout for what stays on this
//        Mac: private/ itself and private/meetings/ and private/recordings/ with everything in
//        them are locked and take nothing in, private/knowledge/ is locked like knowledge/ (its
//        files are the user's). The same rules apply to a folder named private/ in a Private
//        project only once it is shared, so a user's own private/ folder stays theirs until then.
//        Publishing a private item is offered for the folders directly in private/meetings/ and
//        private/recordings/ (`publishablePath`); the publish flow moves them, not the user.
//        Name clashes in a move or copy are resolved by the caller's choice: keep both (the
//        incoming item becomes "name 2.ext", like Finder's Keep Both) or replace (the existing
//        item goes to the Trash, never deleted). An item never replaces itself or a folder that
//        contains one of the moved items; those fall back to keep both. New items are
//        "untitled.md" and "untitled folder" (Finder's naming), duplicates "name copy.ext".
//        Names may start with a dot (.env, .claude): the tree lists dotfiles. Of the dot items
//        only .git and .minutemind at the top level are locked (git's database and the mirror
//        index); .gitignore and the user's own dot folders are the user's.
//        User moves are not committed: the repo only commits what the app itself writes
//        (mirrors, knowledge curation); the user's own changes are theirs (or Claude's) to commit.

import Foundation

enum WorkspaceFileOperations {
    enum Failure: LocalizedError, Equatable {
        case emptyName
        case invalidName(String)
        case nameTaken(String)
        case intoItself(String)
        case managed(String)

        var errorDescription: String? {
            switch self {
            case .emptyName: return "A name cannot be empty."
            case .invalidName(let name): return "\"\(name)\" cannot be used as a name. Names cannot contain / or :."
            case .nameTaken(let name): return "The name \"\(name)\" is already taken. Choose a different name."
            case .intoItself(let name): return "\"\(name)\" cannot be moved into itself."
            case .managed(let message): return message
            }
        }
    }

    enum ClashResolution: Sendable { case keepBoth, replace }

    /// One item that went from `from` to `to` (a move, rename or copy).
    struct Move: Equatable, Sendable {
        let from: URL
        let to: URL
    }

    /// What a move or copy did; `failure` is set when it stopped part way.
    struct Outcome: Sendable {
        var moves: [Move] = []
        var failure: String?
    }

    static let newFileName = "untitled.md"
    static let newFolderName = "untitled folder"

    // MARK: - Paths

    static func components(_ url: URL) -> [String] { url.standardizedFileURL.pathComponents }

    /// Whether `url` is `folder` itself or anything inside it.
    static func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        let item = components(url), container = components(folder)
        return item.count >= container.count && Array(item.prefix(container.count)) == container
    }

    static func isSame(_ a: URL, _ b: URL) -> Bool { components(a) == components(b) }

    /// The path components below the repo root; nil when `url` is outside the repo.
    static func relativeComponents(_ url: URL, in repo: URL) -> [String]? {
        guard isSameOrInside(url, repo) else { return nil }
        return Array(components(url).dropFirst(components(repo).count))
    }

    /// "meetings/2026-10-01-sync/summary.md" for a file in the repo, the full path otherwise.
    static func relativePath(_ url: URL, in repo: URL) -> String {
        relativeComponents(url, in: repo)?.joined(separator: "/") ?? url.standardizedFileURL.path
    }

    /// Where `url` is after the moves (it moved itself, or a folder containing it did); nil when
    /// no move touched it.
    static func relocated(_ url: URL, by moves: [Move]) -> URL? {
        for move in moves where isSameOrInside(url, move.from) {
            let rest = components(url).dropFirst(components(move.from).count)
            return rest.reduce(move.to) { $0.appendingPathComponent($1) }
        }
        return nil
    }

    /// The items without those inside another of them (moving a folder takes its contents along)
    /// and without repeats.
    static func outermost(_ urls: [URL]) -> [URL] {
        var kept: [URL] = []
        for url in urls.sorted(by: { components($0).count < components($1).count })
        where !kept.contains(where: { isSameOrInside(url, $0) }) {
            kept.append(url)
        }
        return kept
    }

    // MARK: - Managed parts of the repo

    /// Top-level folders the app writes meeting mirrors into (ProjectRepositoryService.areaFolder).
    private static let mirrorAreas = ["meetings": "meetings", "recordings": "quick recordings"]

    /// Top-level dot folders that belong to git and MinuteMind.
    private static let managedDotFolders: Set<String> = [".git", ".minutemind"]

    /// Why the item cannot be moved or renamed; nil when it can. `isShared`: the repo is a
    /// Shared Project's, so private/ is managed too.
    static func lockReason(for url: URL, in repo: URL, isShared: Bool = false) -> String? {
        guard let relative = relativeComponents(url, in: repo) else { return nil }
        guard let first = relative.first else { return "The workspace folder itself keeps its name and place." }
        if isShared, first == SharedProjectLayout.privateFolder { return privateLockReason(Array(relative.dropFirst())) }
        if managedDotFolders.contains(first) { return "\(first) belongs to MinuteMind and git and keeps its name and place." }
        if let noun = mirrorAreas[first] {
            if relative.count == 1 {
                return "MinuteMind files your \(noun) in \(first)/, so the folder keeps its name and place."
            }
            return "MinuteMind keeps \(first)/ in step with your \(noun), so what is in it keeps its name and place. Rename the meeting in MinuteMind instead; dragging a file out of \(first)/ copies it."
        }
        guard relative.count == 1 else { return nil }
        if first == "knowledge" {
            return "MinuteMind keeps what it learns from your meetings in knowledge/, so the folder keeps its name and place. The files in it can be moved and renamed."
        }
        if first == "CLAUDE.md" {
            return "CLAUDE.md tells Claude about this workspace and MinuteMind keeps part of it current, so it keeps its name and place."
        }
        return nil
    }

    /// Why nothing can be moved, copied or created in the folder; nil when it can. `isShared`: the
    /// repo is a Shared Project's, so private/ is managed too.
    static func dropRefusal(into folder: URL, in repo: URL, isShared: Bool = false) -> String? {
        guard let relative = relativeComponents(folder, in: repo) else { return "That folder is outside the workspace." }
        guard let first = relative.first else { return nil }
        if isShared, first == SharedProjectLayout.privateFolder {
            guard let area = relative.dropFirst().first else {
                return "private/ only holds what MinuteMind keeps on this Mac for you (unpublished meetings, recordings and their knowledge). Keep your own files in another folder."
            }
            if mirrorAreas[area] != nil {
                return "private/\(area)/ only holds what MinuteMind writes there. Keep your own files in another folder."
            }
            return nil
        }
        if managedDotFolders.contains(first) { return "\(first) belongs to MinuteMind and git." }
        if mirrorAreas[first] != nil {
            return "\(first)/ only holds what MinuteMind writes there (a meeting that moves to another project takes its folder along). Keep your own files in another folder."
        }
        return nil
    }

    /// Refusal for moving or copying items out of private/ into a shared folder of a Shared
    /// Project: everything outside private/ is pushed to the other members by the next sync, so
    /// the only way out is Publish, which asks first. Nil when nothing would leave private/.
    static func privateLeakRefusal(_ items: [URL], into folder: URL, in repo: URL, isShared: Bool) -> String? {
        guard isShared else { return nil }
        func isPrivate(_ url: URL) -> Bool {
            relativeComponents(url, in: repo)?.first == SharedProjectLayout.privateFolder
        }
        guard !isPrivate(folder), items.contains(where: isPrivate) else { return nil }
        return "What is in private/ stays on this Mac. To share a meeting or recording with the team, right-click its folder and choose Publish."
    }

    /// Lock reasons inside private/ of a Shared Project; `inside` is the path below private/.
    private static func privateLockReason(_ inside: [String]) -> String? {
        guard let area = inside.first else {
            return "private/ keeps what stays on this Mac in this Shared Project (unpublished meetings, recordings and their knowledge), so the folder keeps its name and place."
        }
        if let noun = mirrorAreas[area] {
            if inside.count == 1 {
                return "MinuteMind files your unpublished \(noun) in private/\(area)/, so the folder keeps its name and place."
            }
            return "MinuteMind keeps private/\(area)/ in step with your unpublished \(noun), so what is in it keeps its name and place. To share one with the team, right-click its folder and choose Publish."
        }
        if area == "knowledge", inside.count == 1 {
            return "MinuteMind keeps what it learns from your unpublished meetings in private/knowledge/, so the folder keeps its name and place. The files in it can be moved and renamed."
        }
        return nil
    }

    /// The repo-relative path ("private/meetings/2026-11-12-weekly") of a meeting or recording
    /// folder directly in private/meetings/ or private/recordings/, which a Shared Project can
    /// publish; nil for anything else.
    static func publishablePath(_ url: URL, in repo: URL, fileManager: FileManager = .default) -> String? {
        guard let relative = relativeComponents(url, in: repo), relative.count == 3,
              relative[0] == SharedProjectLayout.privateFolder, mirrorAreas[relative[1]] != nil,
              isDirectory(url, fileManager: fileManager) else { return nil }
        return relative.joined(separator: "/")
    }

    // MARK: - Names

    /// The trimmed name, or why it cannot be used.
    static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.emptyName }
        guard name != ".", name != "..", !name.contains("/"), !name.contains(":"), name.utf8.count <= 255
        else { throw Failure.invalidName(name) }
        return name
    }

    /// `name` in `directory`, or the first free "<base> 2.<ext>", "<base> 3.<ext>", ... Folders
    /// are numbered at the end ("v1.2 2"), files before their extension.
    static func availableURL(for name: String, in directory: URL, isDirectory: Bool,
                             marker: String? = nil, fileManager: FileManager = .default) -> URL {
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        func candidate(_ counter: Int?) -> URL {
            var stem = base
            if let marker { stem += " \(marker)" }
            if let counter { stem += " \(counter)" }
            return directory.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)", isDirectory: isDirectory)
        }
        let first = candidate(nil)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        var counter = 2
        while fileManager.fileExists(atPath: candidate(counter).path) { counter += 1 }
        return candidate(counter)
    }

    static func isDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var flag: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    // MARK: - Move and copy

    /// The existing items in `folder` that the incoming ones would collide with. An item staying
    /// where it is (a move into its own folder) or meeting itself (a copy into its own folder)
    /// does not count; those are skipped or numbered.
    static func clashes(_ sources: [URL], into folder: URL, copy: Bool, fileManager: FileManager = .default) -> [URL] {
        outermost(sources).compactMap { item in
            let target = folder.appendingPathComponent(item.lastPathComponent)
            if isSame(target, item) { return nil }
            return fileManager.fileExists(atPath: target.path) ? target : nil
        }
    }

    /// Moves (or copies) the items into `folder`. On a move, items already in it stay put. Throws
    /// before touching anything when a folder would go into itself. Clashing names follow
    /// `resolution` (see the file header); replaced items go through `discard` (the Trash).
    static func transfer(_ sources: [URL], into folder: URL, copy: Bool, resolution: ClashResolution,
                         fileManager: FileManager = .default,
                         discard: (URL) throws -> Void = WorkspaceFileOperations.trash) throws -> Outcome {
        let items = outermost(sources)
        if let inside = items.first(where: { isSameOrInside(folder, $0) }) {
            throw Failure.intoItself(inside.lastPathComponent)
        }
        let clashing = clashes(items, into: folder, copy: copy, fileManager: fileManager)
        var outcome = Outcome()
        for item in items {
            var target = folder.appendingPathComponent(item.lastPathComponent)
            if isSame(target, item), !copy { continue }
            do {
                if fileManager.fileExists(atPath: target.path) {
                    let replaceable = resolution == .replace
                        && clashing.contains(where: { isSame($0, target) })
                        && !items.contains(where: { isSameOrInside($0, target) })
                    if replaceable {
                        try discard(target)
                    } else {
                        target = availableURL(for: item.lastPathComponent, in: folder,
                                              isDirectory: isDirectory(item, fileManager: fileManager), fileManager: fileManager)
                    }
                }
                if copy {
                    try fileManager.copyItem(at: item, to: target)
                } else {
                    try fileManager.moveItem(at: item, to: target)
                }
                outcome.moves.append(Move(from: item, to: target))
            } catch {
                outcome.failure = "\"\(item.lastPathComponent)\" could not be \(copy ? "copied" : "moved"): \(error.localizedDescription)"
                break
            }
        }
        return outcome
    }

    /// Copies files from outside the repo (a Finder drop) into `folder`, numbering taken names.
    static func importItems(_ sources: [URL], into folder: URL, fileManager: FileManager = .default) -> Outcome {
        var outcome = Outcome()
        for item in sources {
            let target = availableURL(for: item.lastPathComponent, in: folder,
                                      isDirectory: isDirectory(item, fileManager: fileManager), fileManager: fileManager)
            do {
                try fileManager.copyItem(at: item, to: target)
                outcome.moves.append(Move(from: item, to: target))
            } catch {
                outcome.failure = "\"\(item.lastPathComponent)\" could not be copied: \(error.localizedDescription)"
            }
        }
        return outcome
    }

    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - Rename, create, duplicate

    /// Renames in place and returns the new URL. A change of case only works on case-insensitive
    /// volumes too (through a temporary name).
    static func rename(_ url: URL, to rawName: String, fileManager: FileManager = .default) throws -> URL {
        let name = try validatedName(rawName)
        if name == url.lastPathComponent { return url }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        if fileManager.fileExists(atPath: target.path) {
            guard isSameFile(url, target) else { throw Failure.nameTaken(name) }
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            try fileManager.moveItem(at: url, to: temporary)
            try fileManager.moveItem(at: temporary, to: target)
            return target
        }
        try fileManager.moveItem(at: url, to: target)
        return target
    }

    /// "untitled folder" (then "untitled folder 2", ...) in `directory`.
    static func createFolder(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        let url = availableURL(for: newFolderName, in: directory, isDirectory: true, fileManager: fileManager)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// An empty "untitled.md" (then "untitled 2.md", ...) in `directory`.
    static func createFile(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        let url = availableURL(for: newFileName, in: directory, isDirectory: false, fileManager: fileManager)
        guard fileManager.createFile(atPath: url.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }

    /// A copy next to the item: "name copy.ext", then "name copy 2.ext", ...
    static func duplicate(_ url: URL, fileManager: FileManager = .default) throws -> URL {
        let target = availableURL(for: url.lastPathComponent, in: url.deletingLastPathComponent(),
                                  isDirectory: isDirectory(url, fileManager: fileManager), marker: "copy", fileManager: fileManager)
        try fileManager.copyItem(at: url, to: target)
        return target
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let first = try? a.resourceValues(forKeys: key).fileResourceIdentifier as? NSObject,
              let second = try? b.resourceValues(forKeys: key).fileResourceIdentifier as? NSObject else { return false }
        return first.isEqual(second)
    }
}
