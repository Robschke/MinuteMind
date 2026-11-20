// Purpose: ThemeFileStore, the themes folder on disk: reads every theme file in it (keeping the
//          problems of files that do not pass), writes and deletes theme files, and tells cheaply
//          whether anything in the folder changed.
// Dependencies: Sources/App/Config/ThemeFile.swift (format and validator)
// Used by: Sources/App/Supporting/ThemeStore.swift (loads and polls it),
//          Sources/App/Services/MCP/MCPThemeTools.swift (save, delete), Tests/ThemeFileTests.swift
// Notes: - The folder is `<Application Support>/MinuteMind/Themes/`, one `<id>.json` per theme. In a
//          test process it is a fresh temporary folder, never the user's.
//        - A file that stops passing (Claude in the middle of an edit, a typo by hand) keeps its
//          last good version on screen and its problems are reported, so the app never flips to
//          another theme while a file is being written. A file that was never good is skipped.
//        - Changes are noticed by a signature of names, sizes and modification dates, which the
//          theme store compares every second or two; a handful of small files makes that cheap
//          and it catches in-place edits a folder watcher would miss.
//        - Deleting moves the file to the Trash (removing it only where there is no Trash), so a
//          theme deleted by mistake can be put back.

import Foundation

@MainActor
final class ThemeFileStore {
    struct Loaded: Equatable {
        /// Themes that can be chosen, by name.
        var themes: [ThemeFile] = []
        /// Issues per file name, for files that do not pass.
        var problems: [String: [String]] = [:]
    }

    let folder: URL
    private let fileManager = FileManager.default

    init(folder: URL = ThemeFileStore.defaultFolder) {
        self.folder = folder
    }

    nonisolated static var defaultFolder: URL {
        let fileManager = FileManager.default
        if AppViewModel.isTestProcess {
            return fileManager.temporaryDirectory
                .appendingPathComponent("MinuteMindTests-Themes-\(UUID().uuidString)", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinuteMind", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
    }

    func url(for id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    private var jsonFiles: [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Changes whenever a theme file is added, removed or edited.
    func signature() -> String {
        jsonFiles.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            return "\(url.lastPathComponent):\(values?.fileSize ?? 0):\(date)"
        }.joined(separator: "|")
    }

    /// Reads the folder. Files that do not pass keep their version from `previous` if they had one.
    func load(previous: [ThemeFile] = []) -> Loaded {
        var loaded = Loaded()
        for url in jsonFiles {
            let fileName = url.lastPathComponent
            let id = url.deletingPathExtension().lastPathComponent
            guard ThemeFileValidator.isValidID(id) else {
                loaded.problems[fileName] = ["The file name must be the theme id: lowercase letters, digits or dashes, then \".json\"."]
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ThemeFileValidator.Failure(issues: ["The file must hold one JSON object."])
                }
                loaded.themes.append(try ThemeFileValidator.validated(object, fileID: id))
            } catch {
                let issues = (error as? ThemeFileValidator.Failure)?.issues ?? ["Not readable as JSON: \(error.localizedDescription)"]
                loaded.problems[fileName] = issues
                if let kept = previous.first(where: { $0.id == id }) { loaded.themes.append(kept) }
            }
        }
        loaded.themes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return loaded
    }

    /// Writes a checked theme as `<id>.json`, replacing a file of the same id.
    @discardableResult
    func save(_ file: ThemeFile) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: file.jsonObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = url(for: file.id)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Moves the file to the Trash, so a deleted theme can be put back from there.
    func delete(id: String) throws {
        let url = url(for: id)
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try fileManager.removeItem(at: url)
        }
    }
}
