// Purpose: Tests for the avatars folder: saving, editing a built-in, deleting, restoring, the
//          picker order, what an id resolves to, and files the store has to skip. Every test
//          works in its own temporary folder.
// Dependencies: Sources/App/Supporting/MascotAvatarStore.swift, Sources/App/Supporting/
//               MascotAvatarFile.swift, Sources/App/Supporting/MascotAvatarCatalog.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("MascotAvatarStore Tests")
@MainActor
struct MascotAvatarStoreTests {
    private let folder: URL
    private let builtInIDs = MascotAvatarCatalog.builtIns.map(\.id)

    init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MascotAvatarStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func store() -> MascotAvatarStore { MascotAvatarStore(folder: folder) }

    private func file(_ id: String, name: String) -> MascotAvatarFile {
        var file = MascotAvatarValidatorTests.fox(id: id)
        file.name = name
        return file
    }

    @Test("Without a folder the store holds the built-ins and writes nothing")
    func empty() {
        let store = store()
        #expect(store.snapshot.avatars == MascotAvatarCatalog.builtIns)
        #expect(!store.snapshot.hasCustomAvatars && !store.snapshot.canRestoreBuiltIns)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(MascotAvatarStore.shared.folder.path.contains("MinuteMindTests-Avatars"), "tests never use the user's folder")
    }

    @Test("Custom avatars follow the built-ins by name and survive a relaunch")
    func saving() throws {
        let store = store()
        #expect(try store.save(file("zebra", name: "Zebra")) == .created)
        #expect(try store.save(file("ant", name: "ant")) == .created)
        #expect(store.snapshot.avatars.map(\.id) == builtInIDs + ["ant", "zebra"])
        #expect(store.snapshot.hasCustomAvatars && !store.snapshot.canRestoreBuiltIns)

        var changed = file("zebra", name: "Zebra")
        changed.bodyColor = "#101010"
        #expect(try store.save(changed) == .updated)
        #expect(store.snapshot.avatar(id: "zebra")?.naturalBody == 0x101010)

        let relaunched = self.store()
        #expect(relaunched.snapshot.avatars == store.snapshot.avatars)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("zebra.json").path))
    }

    @Test("An invalid file is refused with its issues and nothing is written")
    func refusing() {
        let store = store()
        var bad = file("fox", name: "Fox")
        bad.rows[12] = "............"
        #expect(throws: MascotAvatarValidator.Failure.self) { try store.save(bad) }
        #expect(store.snapshot.avatars == MascotAvatarCatalog.builtIns)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("fox.json").path))
    }

    @Test("Saving under a built-in's id edits it in place and keeps its traits")
    func editingBuiltIn() throws {
        let store = store()
        var edit = MascotAvatarFile(MascotAvatar.coolCat)
        edit.bodyColor = "#3366FF"
        edit.name = "Something else"
        #expect(try store.save(edit) == .editedBuiltIn)
        let snapshot = store.snapshot
        #expect(snapshot.avatars.map(\.id) == builtInIDs)
        let avatar = try #require(snapshot.avatar(id: "coolCat"))
        #expect(avatar.naturalBody == 0x3366FF && avatar.wearsShades && avatar.name == "Cool Cat")
        #expect(snapshot.editedBuiltInIDs == ["coolCat"] && snapshot.canRestoreBuiltIns && !snapshot.hasCustomAvatars)

        #expect(try store.restoreBuiltIns() == ["coolCat"])
        #expect(store.snapshot.avatars == MascotAvatarCatalog.builtIns && !store.snapshot.canRestoreBuiltIns)
    }

    @Test("Deleted avatars leave the pickers and resolve to the original Blob")
    func deleting() throws {
        let store = store()
        try store.save(file("fox", name: "Fox"))
        var blueBlob = MascotAvatarFile(MascotAvatar.blob)
        blueBlob.bodyColor = "#0000FF"
        try store.save(blueBlob)
        #expect(store.snapshot.resolve("blob").naturalBody == 0x0000FF)
        #expect(store.snapshot.resolve("dragon") == .blob, "the fallback is the original, not the edit")

        try store.delete(id: "fox")
        try store.delete(id: "duck")
        try store.delete(id: "blob")
        #expect(store.snapshot.avatars.map(\.id) == builtInIDs.filter { $0 != "duck" && $0 != "blob" })
        #expect(store.snapshot.avatar(id: "duck") == nil && store.snapshot.resolve("duck") == .blob)
        #expect(store.snapshot.resolve("fox") == .blob && store.snapshot.resolve("blob") == .blob)
        #expect(store.snapshot.hiddenBuiltInIDs == ["blob", "duck"] && store.snapshot.editedBuiltInIDs.isEmpty)
        #expect(throws: MascotAvatarStore.StoreError.self) { try store.delete(id: "duck") }
        #expect(self.store().snapshot.avatars == store.snapshot.avatars, "deletions survive a relaunch")

        for id in builtInIDs where store.snapshot.avatar(id: id) != nil { try store.delete(id: id) }
        #expect(store.snapshot.avatars.isEmpty && store.snapshot.resolve("cat") == .blob)

        #expect(try store.restoreBuiltIns() == builtInIDs)
        #expect(store.snapshot.avatars == MascotAvatarCatalog.builtIns)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(MascotAvatarStore.hiddenFileName).path))
    }

    @Test("Restoring the built-ins keeps the custom avatars")
    func restoringKeepsCustom() throws {
        let store = store()
        try store.save(file("fox", name: "Fox"))
        try store.delete(id: "lime")
        try store.restoreBuiltIns()
        #expect(store.snapshot.avatars.map(\.id) == builtInIDs + ["fox"])
    }

    @Test("Saving under a deleted built-in's id brings it back with the new drawing")
    func savingOverDeleted() throws {
        let store = store()
        try store.delete(id: "pug")
        var edit = MascotAvatarFile(MascotAvatar.pug)
        edit.featureColor = "#222222"
        #expect(try store.save(edit) == .editedBuiltIn)
        #expect(store.snapshot.avatars.map(\.id) == builtInIDs)
        #expect(store.snapshot.hiddenBuiltInIDs.isEmpty && store.snapshot.editedBuiltInIDs == ["pug"])
    }

    @Test("Broken files are skipped, the rest still loads")
    func brokenFiles() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("broken.json"))
        try Data("{\"id\": \"half\"}".utf8).write(to: folder.appendingPathComponent("half.json"))
        let good = try JSONSerialization.data(withJSONObject: file("fox", name: "Fox").jsonObject)
        try good.write(to: folder.appendingPathComponent("fox.json"))
        try good.write(to: folder.appendingPathComponent("renamed.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent(MascotAvatarStore.hiddenFileName))
        try Data("hello".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let store = store()
        #expect(store.snapshot.avatars.map(\.id) == builtInIDs + ["fox"])
    }

    @Test("A change is announced to observers and by notification")
    func announcing() async throws {
        let store = store()
        let observed = Flag()
        withObservationTracking { _ = store.snapshot.avatars } onChange: { observed.set() }
        let posted = Flag()
        let token = NotificationCenter.default.addObserver(forName: .mascotAvatarsChanged, object: store, queue: nil) { _ in posted.set() }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.save(file("fox", name: "Fox"))
        #expect(observed.isSet && posted.isSet)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
