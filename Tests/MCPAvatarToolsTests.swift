// Purpose: Tests for the avatar MCP tools and what they rest on: the rules text, the preview
//          picture, saving, reading, listing with usage, deleting and restoring, and the words
//          about who wears an avatar. Every test works in its own temporary folder.
// Dependencies: Sources/App/Services/MCP/MCPAvatarTools.swift, Sources/App/Supporting/
//               MascotAvatarStore.swift, Sources/App/Supporting/MascotAvatarUsage.swift,
//               Sources/App/Views/AvatarMoodSheet.swift
// Notes: MM_AVATAR_PREVIEW_DIR=<folder> keeps the preview pictures there, to look at them.

import AppKit
import Foundation
import Testing

@testable import MinuteMindApp

@Suite("MCP avatar tools")
@MainActor
struct MCPAvatarToolsTests {
    private let folder: URL
    private let store: MascotAvatarStore
    private let projects: [Project]

    init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAvatarToolsTests-\(UUID().uuidString)", isDirectory: true)
        store = MascotAvatarStore(folder: folder.appendingPathComponent("Avatars"))
        var atlas = Project(name: "Atlas")
        atlas.companionAvatar = "duck"
        var beta = Project(name: "Beta")
        beta.companionAvatar = "fox"
        projects = [atlas, beta, Project(name: "Plain")]
    }

    private var previewFolder: URL {
        ProcessInfo.processInfo.environment["MM_AVATAR_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
            ?? folder.appendingPathComponent("Previews")
    }

    private var tools: MCPAvatarTools {
        MCPAvatarTools(projects: projects, homeAvatarID: "duck", store: store, previewFolder: previewFolder)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private var fox: [String: Any] { MascotAvatarValidatorTests.fox(id: "fox").jsonObject }

    @Test("The seven tools are defined and exposed by the server")
    func definitions() {
        let defined = MCPAvatarTools.definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(Set(defined) == MCPAvatarTools.names && defined.count == 7)
        #expect(MCPAvatarTools.names.isSubset(of: Set(MinuteMindMCPServer.exposedToolNames())))
    }

    @Test("The rules carry the format, the face grid from the pose code and valid examples of both kinds")
    func rules() throws {
        let rules = try tools.execute(toolName: "get_avatar_rules", arguments: [:]).text
        for word in ["preview_avatar", "save_avatar", "neutralMouth", "featureColor", "\"o\", \"b\", \"h\", \"c\", \"e\", \"f\"", "y 9: x 3, 4, 5, 6, 7, 8"] {
            #expect(rules.contains(word), "\(word)")
        }
        #expect(rules.contains("y  7    . . E E E E E E E E . ."))
        #expect(rules.contains("y  8    A . C E E E E E E C . A"))
        #expect(rules.contains("y 10    . . . . M M M M . . . ."))
        #expect(!rules.contains("\u{2014}") && !rules.contains("\u{2013}"))

        // The examples are complete drafts: each one passes the validator as printed.
        let blocks = rules.components(separatedBy: "```json\n").dropFirst().compactMap { $0.components(separatedBy: "\n```").first }
        #expect(blocks.count == 3)
        for block in blocks {
            let draft = try object(block)
            #expect((try? MascotAvatarValidator.validated(draft)) != nil)
        }
    }

    @Test("A preview returns a PNG, also as a file, and saves nothing")
    func preview() throws {
        let output = try tools.execute(toolName: "preview_avatar", arguments: ["avatar": fox])
        let result = try object(output.text)
        #expect(result["valid"] as? Bool == true)
        #expect((result["moods"] as? [String])?.count == 10)
        #expect((result["status"] as? String)?.contains("adds a new avatar") == true)
        let png = try #require(output.png)
        let path = try #require(result["png_path"] as? String)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == png)
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsWide > 600 && image.pixelsHigh > 300)
        // Not one flat colour: creatures were drawn on it.
        let colours = Set((0..<image.pixelsWide).compactMap { image.colorAt(x: $0, y: image.pixelsHigh / 5)?.description })
        #expect(colours.count > 3)
        #expect(store.snapshot.avatar(id: "fox") == nil)

        for avatar in MascotAvatarCatalog.builtIns where ProcessInfo.processInfo.environment["MM_AVATAR_PREVIEW_DIR"] != nil {
            _ = try tools.execute(toolName: "preview_avatar", arguments: ["avatar": MascotAvatarFile(avatar).jsonObject])
        }
    }

    @Test("An invalid draft comes back with its issues, from preview and from save")
    func invalidDraft() {
        var bad = fox
        bad["rows"] = (bad["rows"] as? [String]).map { rows in rows.enumerated().map { $0.offset == 7 ? "..obbbbbbbo." : $0.element } }
        for tool in ["preview_avatar", "save_avatar"] {
            do {
                _ = try tools.execute(toolName: tool, arguments: ["avatar": bad])
                Issue.record("\(tool) accepted an invalid draft")
            } catch {
                let text = error.localizedDescription
                #expect(text.contains("Pixel (x 2, y 7) is outline") && text.contains("get_avatar_rules"), "\(tool): \(text)")
            }
        }
        #expect(throws: ToolError.self) { try tools.execute(toolName: "save_avatar", arguments: [:]) }
        #expect(store.snapshot.avatars == MascotAvatarCatalog.builtIns)
    }

    @Test("Saving adds, then replaces; a draft sent as text works too")
    func saving() throws {
        var result = try object(tools.execute(toolName: "save_avatar", arguments: ["avatar": fox]).text)
        #expect(result["result"] as? String == "created" && result["id"] as? String == "fox")
        #expect(store.snapshot.avatars.last?.id == "fox")

        var changed = fox
        changed["bodyColor"] = "#445566"
        let text = String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self)
        result = try object(tools.execute(toolName: "save_avatar", arguments: ["avatar": text]).text)
        #expect(result["result"] as? String == "updated")
        #expect((result["note"] as? String)?.contains("Beta now shows the new drawing") == true)
        #expect(store.snapshot.avatar(id: "fox")?.naturalBody == 0x445566)

        var duck = MascotAvatarFile(MascotAvatar.duck).jsonObject
        duck["bodyColor"] = "#FFFFFF"
        result = try object(tools.execute(toolName: "save_avatar", arguments: ["avatar": duck]).text)
        #expect(result["result"] as? String == "edited built-in")
        #expect((result["note"] as? String)?.contains("Atlas and your companion now show the new drawing") == true)
    }

    @Test("get_avatar returns data a save accepts unchanged")
    func getting() throws {
        let result = try object(tools.execute(toolName: "get_avatar", arguments: ["id": "coolCat"]).text)
        #expect(result["status"] as? String == "built-in")
        #expect((result["trait"] as? String)?.contains("sunglasses") == true)
        let avatar = try #require(result["avatar"] as? [String: Any])
        #expect(try MascotAvatarValidator.validated(avatar) == MascotAvatarFile(MascotAvatar.coolCat))

        try store.delete(id: "lime")
        let hidden = try object(tools.execute(toolName: "get_avatar", arguments: ["id": "lime"]).text)
        #expect(hidden["status"] as? String == "hidden" && hidden["avatar"] != nil)

        do {
            _ = try tools.execute(toolName: "get_avatar", arguments: ["id": "dragon"])
            Issue.record("an unknown id was accepted")
        } catch {
            #expect(error.localizedDescription.contains("Known ids: blob, duck"))
        }
    }

    @Test("The list names status and wearers; delete and restore report what changed")
    func listingDeletingRestoring() throws {
        _ = try tools.execute(toolName: "save_avatar", arguments: ["avatar": fox])
        var cat = MascotAvatarFile(MascotAvatar.cat).jsonObject
        cat["featureColor"] = "#000000"
        _ = try tools.execute(toolName: "save_avatar", arguments: ["avatar": cat])

        func list() throws -> [String: [String: Any]] {
            let entries = try #require(try object(tools.execute(toolName: "list_avatars", arguments: [:]).text)["avatars"] as? [[String: Any]])
            return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in (entry["id"] as? String).map { ($0, entry) } })
        }
        var avatars = try list()
        #expect(avatars.count == 10)
        #expect(avatars["duck"]?["status"] as? String == "built-in" && avatars["duck"]?["home_companion"] as? Bool == true)
        #expect(avatars["duck"]?["used_by_projects"] as? [String] == ["Atlas"])
        #expect(avatars["cat"]?["status"] as? String == "edited built-in")
        #expect(avatars["fox"]?["status"] as? String == "custom" && avatars["fox"]?["used_by_projects"] as? [String] == ["Beta"])

        var result = try object(tools.execute(toolName: "delete_avatar", arguments: ["id": "duck"]).text)
        #expect(result["now_showing_the_blob"] as? [String] == ["Atlas", "the home companion"])
        #expect((result["note"] as? String)?.contains("restore_builtin_avatars") == true)
        result = try object(tools.execute(toolName: "delete_avatar", arguments: ["id": "fox"]).text)
        #expect((result["note"] as? String)?.contains("gone for good") == true)
        #expect(throws: ToolError.self) { try tools.execute(toolName: "delete_avatar", arguments: ["id": "duck"]) }

        avatars = try list()
        #expect(avatars.count == 9 && avatars["duck"]?["status"] as? String == "hidden" && avatars["fox"] == nil)

        result = try object(tools.execute(toolName: "restore_builtin_avatars", arguments: [:]).text)
        #expect(result["restored"] as? [String] == ["duck", "cat"])
        #expect(store.snapshot.avatars == MascotAvatarCatalog.builtIns)
        result = try object(tools.execute(toolName: "restore_builtin_avatars", arguments: [:]).text)
        #expect(result["restored"] as? [String] == [])
    }

    @Test("Usage goes by the stored id and reads as a sentence")
    func usage() {
        var usage = MascotAvatarUsage(of: "duck", projects: projects, homeAvatarID: "duck")
        #expect(usage.projectNames == ["Atlas"] && usage.isHomeCompanion && usage.isUsed)
        #expect(usage.wearers == "Atlas and your companion")
        #expect(usage.deleteMessage(isBuiltIn: true) == "Atlas and your companion use this avatar and will show the Blob instead. You can bring it back with Restore built-in avatars in Settings > Appearance.")

        usage = MascotAvatarUsage(of: "fox", projects: projects, homeAvatarID: "duck")
        #expect(usage.deleteMessage(isBuiltIn: false) == "Beta uses this avatar and will show the Blob instead. This cannot be undone.")

        usage = MascotAvatarUsage(of: "duck", projects: [], homeAvatarID: "duck")
        #expect(usage.deleteMessage(isBuiltIn: true).hasPrefix("Your companion uses this avatar"))

        usage = MascotAvatarUsage(of: "blob", projects: projects, homeAvatarID: "duck")
        #expect(!usage.isUsed && usage.wearers == nil, "a project without a creature is no wearer of the Blob")
        #expect(usage.deleteMessage(isBuiltIn: false) == "This cannot be undone.")
    }
}
