// Purpose: Tests for project avatar colours in projects.json: old files with a project colour still
//          load, the migration keeps every creature's look, and new files stay readable by older
//          builds.
// Dependencies: Sources/App/Models/Project.swift (Codable), Sources/App/Models/ProjectAvatarColorMigration.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("Project avatar colour")
struct ProjectAvatarColorTests {
    private func decode(_ json: String) throws -> [Project] {
        try JSONDecoder().decode([Project].self, from: Data(json.utf8))
    }

    private func project(_ name: String, _ avatar: MascotAvatar?, legacy: String?, sortOrder: Int) -> Project {
        var project = Project(name: name)
        project.companionAvatar = avatar?.rawValue
        project.legacyColorHex = legacy
        project.sortOrder = sortOrder
        return project
    }

    @Test("An old file's project colour is read as a legacy colour, not as an avatar colour")
    func decodesOldFile() throws {
        let json = ##"[{"id":"\##(UUID().uuidString)","name":"Acme","colorHex":"#007AFF","createdAt":0,"updatedAt":0}]"##
        let projects = try decode(json)
        #expect(projects.first?.legacyColorHex == "#007AFF")
        #expect(projects.first?.avatarColorHex == nil)
    }

    @Test("A project without any colour key still loads")
    func decodesWithoutColour() throws {
        let json = ##"[{"id":"\##(UUID().uuidString)","name":"Acme","createdAt":0,"updatedAt":0}]"##
        let projects = try decode(json)
        #expect(projects.count == 1)
        #expect(projects.first?.legacyColorHex == nil && projects.first?.avatarColorHex == nil)
    }

    @Test("Saved projects round-trip, Default included, and keep colorHex for older builds")
    func roundTrip() throws {
        var own = Project(name: "Own", avatarColorHex: "#123456")
        own.companionAvatar = MascotAvatar.duck.rawValue
        let plain = Project(name: "Plain")
        let data = try JSONEncoder().encode([own, plain])

        let decoded = try JSONDecoder().decode([Project].self, from: data)
        #expect(decoded == [own, plain])
        #expect(decoded.allSatisfy { $0.legacyColorHex == nil })

        // An older build requires colorHex on every project.
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(raw[0]["colorHex"] as? String == "#123456")
        #expect(raw[1]["colorHex"] as? String == Project.olderBuildsColorHex)
        // Default is written as null, so the file counts as migrated next time.
        #expect(raw[1].keys.contains("avatarColorHex"))
    }

    @Test("A file an older build wrote again (colorHex only) is migrated again")
    func olderBuildRewrite() throws {
        let json = ##"[{"id":"\##(UUID().uuidString)","name":"Acme","colorHex":"#123456","createdAt":0,"updatedAt":0}]"##
        #expect(try decode(json).first?.legacyColorHex == "#123456")
    }

    @Test("The old colour becomes the avatar colour only where the creature showed it")
    func migration() throws {
        let none = project("No creature", nil, legacy: "#000001", sortOrder: 0)
        let blob = project("Blob", .blob, legacy: "#000002", sortOrder: 1)
        let home = project("Home's avatar", .cat, legacy: "#000003", sortOrder: 2)
        let duck1 = project("First duck", .duck, legacy: "#000004", sortOrder: 3)
        let duck2 = project("Second duck", .duck, legacy: "#000005", sortOrder: 4)
        let lime = project("Lime", .lime, legacy: "#000006", sortOrder: 5)

        // Given out of sidebar order: duplicates are decided in the sidebar's order.
        let migrated = try #require(ProjectAvatarColorMigration.migrated(
            [lime, duck2, duck1, home, blob, none], homeAvatar: .cat))
        let colours = Dictionary(uniqueKeysWithValues: migrated.map { ($0.name, $0.avatarColorHex) })
        #expect(colours["No creature"] == "#000001")
        #expect(colours["Blob"] == "#000002")
        #expect(colours["Home's avatar"] == "#000003")
        #expect(colours["First duck"] == .some(nil))
        #expect(colours["Second duck"] == "#000005")
        #expect(colours["Lime"] == .some(nil))
        #expect(migrated.allSatisfy { $0.legacyColorHex == nil })
        // The order of the list is kept.
        #expect(migrated.map(\.name) == ["Lime", "Second duck", "First duck", "Home's avatar", "Blob", "No creature"])
    }

    @Test("Nothing to migrate leaves the projects alone")
    func nothingToMigrate() {
        let projects = [Project(name: "A", avatarColorHex: "#111111"), Project(name: "B")]
        #expect(ProjectAvatarColorMigration.migrated(projects, homeAvatar: .blob) == nil)
    }

    @Test("A project that already has an avatar colour keeps it")
    func keepsAvatarColour() throws {
        var set = Project(name: "Set", avatarColorHex: "#ABCDEF")
        set.companionAvatar = MascotAvatar.lime.rawValue
        let old = project("Old", .duck, legacy: "#000001", sortOrder: 0)
        let migrated = try #require(ProjectAvatarColorMigration.migrated([set, old], homeAvatar: .blob))
        #expect(migrated.first { $0.name == "Set" }?.avatarColorHex == "#ABCDEF")
    }
}
