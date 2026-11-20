// Purpose: MCPAvatarTools, the MCP tools that let Claude design companion avatars for the user:
//          get_avatar_rules (format, inks, face zones, examples), preview_avatar (checks a draft
//          and returns a picture of it in every mood), save_avatar, get_avatar, list_avatars,
//          delete_avatar and restore_builtin_avatars.
// Dependencies: Sources/App/Supporting/MascotAvatarStore.swift (the avatars folder),
//               Sources/App/Supporting/MascotAvatarValidator.swift (checks, FaceZones),
//               Sources/App/Supporting/MascotAvatarFile.swift (the format),
//               Sources/App/Supporting/MascotAvatarUsage.swift (who wears an avatar),
//               Sources/App/Views/AvatarMoodSheet.swift (the preview picture),
//               Sources/App/Services/ToolExecutor.swift (ToolError)
// Used by: Sources/App/Services/MCP/MinuteMindMCPServer.swift, Tests/MCPAvatarToolsTests.swift
// RBAC: none inside the app; every MCP client holding the bearer token may read, save and delete
//       avatars. Deleting only removes an avatar from the pickers: projects and the companion
//       keep their choice and show the Blob, and built-ins can be restored.
// Notes: - Same OpenAI function shape as MCPMeetingTools. The rules are Markdown (prose Claude
//          reads), everything else JSON.
//        - A result can carry a picture: preview_avatar returns the PNG as MCP image content
//          and also writes it to a file whose path is in the text, so a client that shows no
//          images can open it.
//        - The rules text is built from the validator's own data (inks, face zones, mouth area)
//          and from built-in avatars as examples, so it cannot drift from what is accepted.
//        - Saving under an existing id replaces that avatar; that is how avatars are edited,
//          built-in ones too.

import Foundation

@MainActor
struct MCPAvatarTools {
    struct Output {
        var text: String
        var png: Data?
    }

    let projects: [Project]
    /// The id the home companion is set to.
    let homeAvatarID: String
    var store: MascotAvatarStore = .shared
    /// Where preview pictures are written.
    var previewFolder: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinuteMindAvatarPreviews", isDirectory: true)

    init(appViewModel: AppViewModel) {
        projects = appViewModel.projects
        homeAvatarID = CompanionAppearance.shared.avatarID
    }

    init(projects: [Project], homeAvatarID: String, store: MascotAvatarStore, previewFolder: URL) {
        self.projects = projects
        self.homeAvatarID = homeAvatarID
        self.store = store
        self.previewFolder = previewFolder
    }

    static let names: Set<String> = [
        "get_avatar_rules", "preview_avatar", "save_avatar", "get_avatar", "list_avatars",
        "delete_avatar", "restore_builtin_avatars",
    ]

    private static let avatarProperty: [String: Any] = [
        "type": "object",
        "description": "The avatar in the format get_avatar_rules describes: id, name, rows (13 strings of 12 characters), bodyColor, featureColor, neutralMouth.",
        "properties": [
            "id": ["type": "string"],
            "name": ["type": "string"],
            "kind": ["type": "string", "enum": ["pixel"]],
            "rows": ["type": "array", "items": ["type": "string"]] as [String: Any],
            "bodyColor": ["type": ["string", "null"]] as [String: Any],
            "featureColor": ["type": "string"],
            "neutralMouth": ["type": "array", "items": ["type": "array", "items": ["type": "integer"]] as [String: Any]] as [String: Any],
            "formatVersion": ["type": "integer"],
        ] as [String: Any],
        "required": ["id", "name", "rows", "featureColor", "neutralMouth"],
    ]

    static var definitions: [[String: Any]] {
        [
            function(
                "get_avatar_rules",
                "How to draw a companion avatar for MinuteMind: the JSON format, the ink letters, where the face goes, two built-in avatars as examples and design advice. Call it first when the user asks for a new avatar or a change to one; then draw, check with preview_avatar, look at the picture, and save with save_avatar.",
                properties: [:], required: []),
            function(
                "preview_avatar",
                "Check an avatar draft and get a picture of it in every mood (idle, blinking, working, waiting, celebrating, error, sleeping, recording, running, thumb up) on a light and a dark background. Nothing is saved. An invalid draft comes back with every issue and the pixel it is about. Look at the picture before saving: does it read as the creature the user asked for, in every mood?",
                properties: ["avatar": avatarProperty], required: ["avatar"]),
            function(
                "save_avatar",
                "Save an avatar; it appears in the avatar pickers at once (Settings > Appearance and a project's companion chooser). Under a new id it adds an avatar. Under an existing id it replaces that avatar, which is how avatars are edited: start from get_avatar, change it, preview, save. A built-in edited this way keeps its name and its special trait. Saving does not make any project or the companion wear it; the user picks it, or use update_setting with companion_creature for the home companion.",
                properties: ["avatar": avatarProperty], required: ["avatar"]),
            function(
                "get_avatar",
                "One avatar's current data in the save_avatar format, to start an edit from, with its status and who wears it. Works for deleted built-ins too (it returns the original).",
                properties: ["id": ["type": "string", "description": "Avatar id from list_avatars, e.g. \"cat\"."]],
                required: ["id"]),
            function(
                "list_avatars",
                "Every companion avatar with its id, name, status (built-in, edited built-in, custom, or hidden for a deleted built-in), the projects that wear it and whether the home companion does.",
                properties: [:], required: []),
            function(
                "delete_avatar",
                "Remove an avatar from the pickers, only when the user asks for it. Projects and the companion that wear it show the Blob instead (say which ones; list_avatars shows them beforehand). A custom avatar is gone for good; a built-in can be brought back with restore_builtin_avatars.",
                properties: ["id": ["type": "string", "description": "Avatar id from list_avatars."]],
                required: ["id"]),
            function(
                "restore_builtin_avatars",
                "Bring every built-in avatar back as it shipped: deleted ones return and edits of built-ins are discarded. Custom avatars stay. Only when the user asks for it.",
                properties: [:], required: []),
        ]
    }

    func execute(toolName: String, arguments: [String: Any]) throws -> Output {
        switch toolName {
        case "get_avatar_rules": return Output(text: Self.rules())
        case "preview_avatar": return try preview(arguments)
        case "save_avatar": return try save(arguments)
        case "get_avatar": return Output(text: try get(arguments))
        case "list_avatars": return Output(text: try json(["avatars": entries()]))
        case "delete_avatar": return Output(text: try delete(arguments))
        case "restore_builtin_avatars": return Output(text: try restore())
        default: throw ToolError.invalidArguments("Unknown tool \(toolName)")
        }
    }

    // MARK: - Drafts

    /// The checked draft; clients send the avatar as an object, some as a JSON string.
    private func draft(_ arguments: [String: Any]) throws -> MascotAvatarFile {
        var object = arguments["avatar"] as? [String: Any]
        if object == nil, let text = arguments["avatar"] as? String {
            object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        guard let object else {
            throw ToolError.invalidArguments("avatar must be an object with id, name, rows, bodyColor, featureColor and neutralMouth (see get_avatar_rules).")
        }
        do {
            return try MascotAvatarValidator.validated(object)
        } catch let failure as MascotAvatarValidator.Failure {
            throw ToolError.custom(failure.localizedDescription)
        }
    }

    private func preview(_ arguments: [String: Any]) throws -> Output {
        let file = try draft(arguments)
        guard let png = AvatarMoodSheet.png(of: file.avatar) else {
            throw ToolError.custom("The avatar is valid, but the preview picture could not be drawn.")
        }
        var result: [String: Any] = [
            "valid": true, "id": file.id,
            "moods": AvatarMoodSheet.labels,
            "layout": "Two rows of five, in the order of moods; the same ten again below on a dark background.",
            "status": status(of: file.id).map { "Saving replaces the existing avatar \"\(file.id)\" (\($0))." }
                ?? "Saving adds a new avatar.",
            "next": "Look at the picture. Fix what does not read well and preview again, or call save_avatar with the same avatar.",
        ]
        do {
            try FileManager.default.createDirectory(at: previewFolder, withIntermediateDirectories: true)
            let url = previewFolder.appendingPathComponent("\(file.id).png")
            try png.write(to: url, options: .atomic)
            result["png_path"] = url.path
        } catch {
            result["png_path_error"] = error.localizedDescription
        }
        return Output(text: try json(result), png: png)
    }

    private func save(_ arguments: [String: Any]) throws -> Output {
        let file = try draft(arguments)
        let outcome: MascotAvatarStore.SaveOutcome
        do {
            outcome = try store.save(file)
        } catch let failure as MascotAvatarValidator.Failure {
            throw ToolError.custom(failure.localizedDescription)
        }
        let saved = store.snapshot.resolve(file.id)
        var result: [String: Any] = [
            "saved": true, "id": saved.id, "name": saved.name, "result": outcome.rawValue,
            "file": store.folder.appendingPathComponent("\(file.id).json").path,
        ]
        let usage = MascotAvatarUsage(of: file.id, projects: projects, homeAvatarID: homeAvatarID)
        switch outcome {
        case .created:
            result["note"] = "It is in the avatar pickers now: Settings > Appearance for the companion, Edit Project... for a project. Nobody wears it until the user picks it."
        case .updated, .editedBuiltIn:
            var note = usage.wearers.map { "\($0) now show\(usage.projectNames.count + (usage.isHomeCompanion ? 1 : 0) == 1 ? "s" : "") the new drawing." }
                ?? "Nobody wears it at the moment."
            if outcome == .editedBuiltIn {
                note += " It is an edit of a built-in: its name and special trait stay, and Restore built-in avatars in Settings > Appearance brings the original back."
            }
            result["note"] = note
        }
        return Output(text: try json(result))
    }

    // MARK: - Reading

    /// What an avatar is: nil when there is none with this id.
    private func status(of id: String) -> String? {
        let snapshot = store.snapshot
        if snapshot.hiddenBuiltInIDs.contains(id) { return "hidden" }
        if snapshot.editedBuiltInIDs.contains(id) { return "edited built-in" }
        if snapshot.customIDs.contains(id) { return "custom" }
        return snapshot.avatar(id: id) == nil ? nil : "built-in"
    }

    private func entry(_ avatar: MascotAvatar) -> [String: Any] {
        let usage = MascotAvatarUsage(of: avatar.id, projects: projects, homeAvatarID: homeAvatarID)
        return [
            "id": avatar.id, "name": avatar.name, "status": status(of: avatar.id) ?? "built-in",
            "used_by_projects": usage.projectNames, "home_companion": usage.isHomeCompanion,
        ]
    }

    /// The avatars in the pickers' order, then the deleted built-ins.
    private func entries() -> [[String: Any]] {
        let snapshot = store.snapshot
        let hidden = MascotAvatarCatalog.builtIns.filter { snapshot.hiddenBuiltInIDs.contains($0.id) }
        return (snapshot.avatars + hidden).map(entry)
    }

    private func knownIDs() -> String {
        entries().compactMap { $0["id"] as? String }.joined(separator: ", ")
    }

    private func requiredID(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments["id"] as? String, !id.isEmpty else { throw ToolError.invalidArguments("id is required.") }
        return id
    }

    private func get(_ arguments: [String: Any]) throws -> String {
        let id = try requiredID(arguments)
        let snapshot = store.snapshot
        let hiddenOriginal = snapshot.hiddenBuiltInIDs.contains(id) ? MascotAvatarCatalog.builtIns.first { $0.id == id } : nil
        guard let avatar = snapshot.avatar(id: id) ?? hiddenOriginal else {
            throw ToolError.custom("There is no avatar with the id \"\(id)\". Known ids: \(knownIDs()).")
        }
        var result = entry(avatar)
        result["avatar"] = MascotAvatarFile(avatar).jsonObject
        if avatar.wearsShades { result["trait"] = "Wears sunglasses over its eyes in every mood; they are drawn by the app and stay when it is edited." }
        if avatar.isContent { result["trait"] = "Idles with half closed eyes and a heart now and then; drawn by the app, stays when it is edited." }
        if avatar.nubs.isEmpty { result["trait"] = "Has no arms; that stays when it is edited." }
        return try json(result)
    }

    // MARK: - Deleting and restoring

    private func delete(_ arguments: [String: Any]) throws -> String {
        let id = try requiredID(arguments)
        guard let avatar = store.snapshot.avatar(id: id) else {
            let hidden = store.snapshot.hiddenBuiltInIDs.contains(id)
            throw ToolError.custom(hidden
                ? "\"\(id)\" is already deleted. restore_builtin_avatars brings it back."
                : "There is no avatar with the id \"\(id)\". Known ids: \(knownIDs()).")
        }
        let wasBuiltIn = MascotAvatarCatalog.builtIns.contains { $0.id == id }
        let usage = MascotAvatarUsage(of: id, projects: projects, homeAvatarID: homeAvatarID)
        try store.delete(id: id)
        return try json([
            "deleted": true, "id": id, "name": avatar.name,
            "now_showing_the_blob": usage.projectNames + (usage.isHomeCompanion ? ["the home companion"] : []),
            "note": wasBuiltIn
                ? "A built-in avatar: restore_builtin_avatars (or Restore built-in avatars in Settings > Appearance) brings it back."
                : "A custom avatar: it is gone for good.",
        ])
    }

    private func restore() throws -> String {
        let restored = try store.restoreBuiltIns()
        return try json([
            "restored": restored,
            "note": restored.isEmpty ? "Every built-in avatar was already there as it shipped." : "The built-in avatars are back as they shipped. Custom avatars were not touched.",
        ])
    }

    // MARK: - Rules

    /// The grid with the face zones marked: E eyes, C cheeks, M mouths, A arms at rest.
    static func zoneGrid(_ zones: FaceZones = FaceZones()) -> String {
        var lines = ["      x 0 1 2 3 4 5 6 7 8 9 10 11"]
        for y in 0..<MascotGrid.height {
            let cells = (0..<MascotGrid.width).map { x -> String in
                if zones.armsAtRest.contains(where: { $0.x == x && $0.y == y }) { return "A" }
                switch zones.spots.first(where: { $0.x == x && $0.y == y })?.part {
                case .eyes: return "E"
                case .cheeks: return "C"
                case .mouth: return "M"
                case nil: return "."
                }
            }
            lines.append("y \(y < 10 ? " " : "")\(y)    " + cells.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    static func rules() -> String {
        let zones = FaceZones()
        let inks = MascotAvatarValidator.bodyInks.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        func example(_ avatar: MascotAvatar) -> String {
            let file = MascotAvatarFile(avatar)
            let rows = file.rows.map { "    \"\($0)\"" }.joined(separator: ",\n")
            let mouth = file.neutralMouth.map { "[\($0[0]), \($0[1])]" }.joined(separator: ", ")
            return """
                ```json
                {
                  "id": "\(file.id)",
                  "name": "\(file.name)",
                  "kind": "pixel",
                  "rows": [
                \(rows)
                  ],
                  "bodyColor": \(file.bodyColor.map { "\"\($0)\"" } ?? "null"),
                  "featureColor": "\(file.featureColor)",
                  "neutralMouth": [\(mouth)],
                  "formatVersion": \(file.formatVersion)
                }
                ```
                """
        }
        return """
            # Drawing a companion avatar

            An avatar is a small pixel creature: a body of \(MascotGrid.width) x \(MascotGrid.height) pixels, a body colour, one feature colour and a neutral mouth. MinuteMind draws everything else over the body, the same for every avatar: eyes, blinking, mouths, cheeks, waving arms, the laptop, headphones, the thumb up, running feet, sleeping. So you only draw the creature at rest, without eyes.

            ## Workflow

            1. Draw the avatar as JSON (format below).
            2. Call `preview_avatar`. An invalid draft comes back with every issue and its pixel; fix and repeat.
            3. Look at the picture: all ten moods, on light and dark. Does it read as the creature the user asked for? Is the face clear? Improve and preview again until it does.
            4. Call `save_avatar`. The avatar is in the pickers at once; tell the user where to pick it (Settings > Appearance for the companion, Edit Project... for a project).

            To change an existing avatar (built-in ones too): `get_avatar`, change the data, preview, then `save_avatar` under the same id.

            ## Format

            - `id`: a slug of lowercase letters, digits and hyphens ("red-fox"). An existing id replaces that avatar.
            - `name`: what the pickers show, at most \(MascotAvatarValidator.maxNameLength) characters.
            - `kind`: "pixel".
            - `rows`: \(MascotGrid.height) strings of \(MascotGrid.width) characters, top to bottom. "." is empty; the inks are \(inks):
              - "o" outline: the body colour darkened. Run it all around the body.
              - "b" body: the body colour.
              - "h" shine: the body colour lightened, one to three pixels top left.
              - "c" pink: ear insides, a nose, a tongue.
              - "e" near-black: a nose. Not for eyes, the app draws those.
              - "f" the feature colour: ears, beak, feet, a tail, a patch, a leaf.
            - `bodyColor`: "#RRGGBB", or null to take the app theme's accent colour (the Blob does that).
            - `featureColor`: "#RRGGBB", the colour of the "f" pixels.
            - `neutralMouth`: the mouth at rest as [x, y] pairs, drawn in the outline colour, inside the mouth area. [] when the body already draws the mouth (a beak, a nose).
            - `formatVersion`: \(MascotAvatarFile.currentFormatVersion).

            Coordinates: x 0 to \(MascotGrid.width - 1) from the left, y 0 to \(MascotGrid.height - 1) from the top.

            ## Where the face goes

            Every avatar has its face in the same place, so every mood works. In this grid E marks every pixel some mood draws an eye on, C the cheeks, M the mouths, A the arms at rest:

            ```
            \(zoneGrid(zones))
            ```

            Rules the app checks:

            - Every E, C and M pixel must be a filled body pixel (b, h, c, e or f): not empty and not outline. The outline has to run outside the face. Keep that area calm: what you draw there is covered by eyes and mouths.
            - The head reaches row y \(zones.headTopRow) (headphones sit right above it). Ears, tufts and leaves may go up into row y \(zones.headTopRow - 1).
            - The feet stand in row y \(zones.feetRow).
            - The mouth area is \(MascotAvatarValidator.describe(zones.mouthArea)).
            - The arms at rest are single "o" pixels at the A positions, outside the body's outline. Waving, typing and cheering take them away and draw the arm elsewhere, so the outline must close behind them. Leaving them out is fine.

            Good to know:

            - The eyes are two pixels tall at x 4 and x 7 in rows y 6 and 7; a nose fits at y 8 between them, the mouth below.
            - The laptop covers rows y 9 to 11 in the middle, the headphones the head's top and sides, the raised thumb the top right corner (a right ear disappears behind it).
            - The feet are redrawn while running and tucked in during a hop; simple feet of one or two pixels each at x 3, 4 and x 7, 8 work best.
            - While breathing out, rows y 0 to 3 sink by one row, so the top of the head should survive losing row y 4.

            ## Design advice

            - Natural colours: a yellow duck, a tan dog, an orange cat. Mid tones work best, since the outline is the body colour darkened and the shine the same colour lightened; very dark or very light bodies lose one of them.
            - Put the character into the silhouette and the one feature colour: ears, a beak, a tail, a patch. Two or three strong features read better at this size than many small ones.
            - No detail that reads as an extra limb: whiskers and stripes beside the body look like legs or arms.
            - Keep the creature facing front, like the built-in ones; the shared face does not turn.
            - Custom avatars have no special traits (sunglasses, hearts, a creature without arms are built-in only), and no own poses.

            ## Examples

            The built-in Cat (pointed ears with pink insides, a forehead patch, a nose, a tail on the right):

            \(example(.cat))

            The built-in Duck (a cowlick, a flat bill that is its mouth, so `neutralMouth` is empty):

            \(example(.duck))
            """
    }

    // MARK: - Helpers

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func function(
        _ name: String, _ description: String, properties: [String: Any], required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": ["type": "object", "properties": properties, "required": required] as [String: Any],
            ] as [String: Any],
        ]
    }
}
