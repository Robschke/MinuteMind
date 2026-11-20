// Purpose: MascotAvatarStore, the avatars folder on disk and the list of avatars that follows
//          from it: the built-in ones, the user's edits of them, the built-ins the user deleted
//          and the avatars designed on top. Loads the folder, saves, deletes and restores.
// Dependencies: Sources/App/Supporting/MascotAvatarFile.swift (the file format),
//               Sources/App/Supporting/MascotAvatarValidator.swift (every file is checked),
//               Sources/App/Supporting/MascotAvatar.swift (the built-in avatars)
// Used by: Sources/App/Supporting/MascotAvatarCatalog.swift (reads `shared`),
//          Sources/App/Services/MCP/MCPAvatarTools.swift (save, delete, restore),
//          Sources/App/Components/AvatarPickerSupport.swift (delete, restore),
//          Sources/App/Supporting/CompanionAppearance.swift (follows `.mascotAvatarsChanged`),
//          Tests/MascotAvatarStoreTests.swift
// Notes: - The folder is `<Application Support>/MinuteMind/Avatars/`: one `<id>.json` per custom
//          avatar or edited built-in, and `_hidden.json`, the list of deleted built-in ids. An id
//          can never start with an underscore, so that name is free. Restoring the built-ins
//          removes the edits and empties the list; custom avatars stay.
//        - Deleting a built-in also removes its edit: it comes back as the original.
//        - The picker order is the built-ins in their order (an edited one in its place), then
//          the custom avatars by name.
//        - Resolving an id never fails. An id nobody knows, a deleted avatar and an empty list
//          all end at the original Blob, even when the Blob itself is edited or deleted.
//        - A file that cannot be read or does not pass the validator is skipped and logged.
//        - The list is read from views, models and background code alike, so it sits behind a
//          lock, and reading it registers with Observation: a SwiftUI view that shows an avatar
//          redraws when the list changes, without knowing the store. Changes are made on the
//          main actor.
//        - In a test process `shared` uses a fresh temporary folder, never the user's.

import Foundation
import Observation

extension Notification.Name {
    /// Posted on the main thread after an avatar was saved, deleted or restored.
    static let mascotAvatarsChanged = Notification.Name("MascotAvatarsChanged")
}

final class MascotAvatarStore: Observable, @unchecked Sendable {
    /// The avatars at one moment.
    struct Snapshot: Sendable {
        /// Every avatar that can be chosen, in the pickers' order.
        var avatars: [MascotAvatar] = MascotAvatarCatalog.builtIns
        var customIDs: Set<String> = []
        var editedBuiltInIDs: Set<String> = []
        var hiddenBuiltInIDs: Set<String> = []

        var hasCustomAvatars: Bool { !customIDs.isEmpty }
        /// A built-in is deleted or edited, so there is something to restore.
        var canRestoreBuiltIns: Bool { !editedBuiltInIDs.isEmpty || !hiddenBuiltInIDs.isEmpty }

        func avatar(id: String) -> MascotAvatar? {
            avatars.first { $0.id == id }
        }

        func resolve(_ id: String) -> MascotAvatar {
            avatar(id: id) ?? MascotAvatarCatalog.fallback
        }
    }

    enum SaveOutcome: String, Sendable {
        case created
        case updated
        case editedBuiltIn = "edited built-in"
    }

    enum StoreError: LocalizedError {
        case unknownAvatar(String)
        var errorDescription: String? {
            switch self {
            case .unknownAvatar(let id): "There is no avatar with the id \"\(id)\"."
            }
        }
    }

    static let shared = MascotAvatarStore(folder: defaultFolder)

    private static var defaultFolder: URL {
        let fileManager = FileManager.default
        if AppViewModel.isTestProcess {
            return fileManager.temporaryDirectory
                .appendingPathComponent("MinuteMindTests-Avatars-\(UUID().uuidString)", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinuteMind", isDirectory: true)
            .appendingPathComponent("Avatars", isDirectory: true)
    }

    static let hiddenFileName = "_hidden.json"

    let folder: URL
    private let fileManager: FileManager
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var stored = Snapshot()

    init(folder: URL, fileManager: FileManager = .default) {
        self.folder = folder
        self.fileManager = fileManager
        stored = readFolder()
    }

    var snapshot: Snapshot {
        registrar.access(self, keyPath: \.snapshot)
        return lock.withLock { stored }
    }

    // MARK: - Changes

    /// Reads the folder again, for files that changed behind the store's back.
    @MainActor
    func reload() {
        publish(readFolder())
    }

    /// Checks the file and writes it. Under an existing id it replaces that avatar; under a
    /// deleted built-in's id it brings the built-in back with the new drawing.
    @MainActor
    @discardableResult
    func save(_ file: MascotAvatarFile) throws -> SaveOutcome {
        let issues = MascotAvatarValidator.issues(in: file)
        guard issues.isEmpty else { throw MascotAvatarValidator.Failure(issues: issues) }
        let before = snapshot
        var written = file
        if let builtIn = file.builtIn { written.name = builtIn.name }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: written.jsonObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url(for: file.id), options: .atomic)
        if before.hiddenBuiltInIDs.contains(file.id) {
            try writeHidden(before.hiddenBuiltInIDs.subtracting([file.id]))
        }
        publish(readFolder())
        if file.builtIn != nil { return .editedBuiltIn }
        return before.customIDs.contains(file.id) ? .updated : .created
    }

    /// Removes an avatar from the pickers: a custom one for good, a built-in until restored.
    @MainActor
    func delete(id: String) throws {
        let before = snapshot
        guard before.avatar(id: id) != nil else { throw StoreError.unknownAvatar(id) }
        if fileManager.fileExists(atPath: url(for: id).path) {
            try fileManager.removeItem(at: url(for: id))
        }
        if MascotAvatarCatalog.builtIns.contains(where: { $0.id == id }) {
            try writeHidden(before.hiddenBuiltInIDs.union([id]))
        }
        publish(readFolder())
    }

    /// Brings every built-in back as it shipped. Returns the ids that changed.
    @MainActor
    @discardableResult
    func restoreBuiltIns() throws -> [String] {
        let before = snapshot
        for id in before.editedBuiltInIDs where fileManager.fileExists(atPath: url(for: id).path) {
            try fileManager.removeItem(at: url(for: id))
        }
        try writeHidden([])
        publish(readFolder())
        return MascotAvatarCatalog.builtIns.map(\.id)
            .filter { before.editedBuiltInIDs.contains($0) || before.hiddenBuiltInIDs.contains($0) }
    }

    @MainActor
    private func publish(_ snapshot: Snapshot) {
        registrar.withMutation(of: self, keyPath: \.snapshot) {
            lock.withLock { stored = snapshot }
        }
        NotificationCenter.default.post(name: .mascotAvatarsChanged, object: self)
    }

    // MARK: - The folder

    private func url(for id: String) -> URL {
        folder.appendingPathComponent("\(id).json")
    }

    private var hiddenURL: URL { folder.appendingPathComponent(Self.hiddenFileName) }

    private func writeHidden(_ ids: Set<String>) throws {
        guard !ids.isEmpty else {
            if fileManager.fileExists(atPath: hiddenURL.path) { try fileManager.removeItem(at: hiddenURL) }
            return
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ids.sorted(), options: [.prettyPrinted])
        try data.write(to: hiddenURL, options: .atomic)
    }

    private func readFolder() -> Snapshot {
        let builtIns = MascotAvatarCatalog.builtIns
        let builtInIDs = Set(builtIns.map(\.id))
        var hidden: Set<String> = []
        if let data = try? Data(contentsOf: hiddenURL) {
            if let ids = (try? JSONSerialization.jsonObject(with: data)) as? [String] {
                hidden = Set(ids).intersection(builtInIDs)
            } else {
                NSLog("MascotAvatarStore: skipped %@, it is not a list of ids", Self.hiddenFileName)
            }
        }

        var edits: [String: MascotAvatar] = [:]
        var customs: [MascotAvatar] = []
        let names = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        for name in names where name.hasSuffix(".json") && name != Self.hiddenFileName {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                NSLog("MascotAvatarStore: skipped avatar file %@, it is not a JSON object", name)
                continue
            }
            do {
                let file = try MascotAvatarValidator.validated(object)
                guard "\(file.id).json" == name else {
                    NSLog("MascotAvatarStore: skipped avatar file %@, its id \"%@\" does not match the file name", name, file.id)
                    continue
                }
                if builtInIDs.contains(file.id) {
                    if !hidden.contains(file.id) { edits[file.id] = file.avatar }
                } else {
                    customs.append(file.avatar)
                }
            } catch {
                NSLog("MascotAvatarStore: skipped avatar file %@: %@", name, error.localizedDescription)
            }
        }
        customs.sort {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return Snapshot(
            avatars: builtIns.filter { !hidden.contains($0.id) }.map { edits[$0.id] ?? $0 } + customs,
            customIDs: Set(customs.map(\.id)),
            editedBuiltInIDs: Set(edits.keys),
            hiddenBuiltInIDs: hidden)
    }
}
