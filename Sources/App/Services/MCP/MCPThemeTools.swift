// Purpose: MCPThemeTools, the MCP tools that let Claude design the app's look for the user:
//          get_theme_rules (the file format), list_themes, get_theme, list_fonts, preview_theme
//          (checks a draft and returns a picture of it), save_theme and delete_theme.
// Dependencies: Sources/App/Supporting/ThemeStore.swift (themes, saving, selecting),
//               Sources/App/Config/ThemeFile.swift (format, validator, warnings),
//               Sources/App/Help/ThemeFileGuide.swift (rules text),
//               Sources/App/Views/ThemePreviewSheet.swift (the preview picture),
//               Sources/App/Components/ThemeFonts.swift (installed fonts),
//               Sources/App/Services/ToolExecutor.swift (ToolError)
// Used by: Sources/App/Services/MCP/MinuteMindMCPServer.swift, Tests/MCPThemeToolsTests.swift
// RBAC: none inside the app; every MCP client holding the bearer token may read, save, select and
//       delete themes. Only theme files can be deleted (to the Trash); built-ins, saved profiles
//       and the Custom draft are read-only here.
// Notes: - Same OpenAI function shape and Output (text plus optional PNG) as MCPAvatarTools.
//        - A theme is saved whole: get_theme, change, preview_theme, save_theme under the same id.
//        - save_theme selects the theme unless `activate` is false, because the user asked for
//          the look to see it.
//        - A built-in, a profile or Custom comes back from get_theme with every value written out
//          and a suggested new id, so saving it makes a new theme file instead of touching them.

import AppKit
import Foundation

@MainActor
struct MCPThemeTools {
    struct Output {
        var text: String
        var png: Data?
    }

    var themes: ThemeStore = .shared
    /// Where preview pictures are written.
    var previewFolder: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinuteMindThemePreviews", isDirectory: true)
    /// Installed font families; injectable for tests.
    var installedFamilies: () -> [String] = { ThemeFonts.installedFamilies }

    static let names: Set<String> = [
        "get_theme_rules", "list_themes", "get_theme", "list_fonts", "preview_theme", "save_theme", "delete_theme",
    ]

    private static let themeProperty: [String: Any] = [
        "type": "object",
        "description": "The theme in the format get_theme_rules describes: id, name, optional description, base, colors, font, corners, density, terminal.",
        "properties": [
            "formatVersion": ["type": "integer"],
            "id": ["type": "string"],
            "name": ["type": "string"],
            "description": ["type": "string"],
            "base": ["type": "string"],
            "colors": ["type": "object"],
            "font": ["type": "object"],
            "corners": ["type": "string", "enum": ThemeStyle.Corners.allCases.map(\.rawValue)],
            "density": ["type": "string", "enum": ThemeStyle.Density.allCases.map(\.rawValue)],
            "terminal": ["type": "object"],
        ] as [String: Any],
        "required": ["id", "name"],
    ]

    static var definitions: [[String: Any]] {
        [
            function(
                "get_theme_rules",
                "How a MinuteMind theme is written: every key (colours for light and dark, UI font and size scale, corners, density, terminal font), allowed values, an example and design advice. Call it first when the user asks to change how the app looks; then get_theme or draft, preview_theme, look at the picture, save_theme.",
                properties: [:], required: []),
            function(
                "list_themes",
                "Every theme the user can pick: built-ins, saved profiles, theme files and the Custom draft, with id, kind, whether it is active, and for theme files the file path. Also lists theme files that do not pass and why.",
                properties: [:], required: []),
            function(
                "get_theme",
                "One theme in the save_theme format, to start from. A theme file comes back as it is (save under the same id to change it). A built-in, profile or Custom comes back with every value written out and a suggested new id, so saving creates a new theme file.",
                properties: ["id": ["type": "string", "description": "Theme id from list_themes, e.g. \"midnight\" or \"file:terminal\"."]],
                required: ["id"]),
            function(
                "list_fonts",
                "Font families installed on this Mac, with whether each is monospaced, for the font and terminal families of a theme.",
                properties: ["query": ["type": "string", "description": "Optional part of the family name to filter by, e.g. \"mono\"."]],
                required: []),
            function(
                "preview_theme",
                "Check a theme draft and get a picture of a sample MinuteMind screen in it (sidebar, a card with text, buttons, status colours, speaker colours, a terminal), light mode left, dark mode right. Nothing is saved or changed. An invalid draft comes back with every issue; warnings name fonts that are not installed and text that is hard to read.",
                properties: ["theme": themeProperty], required: ["theme"]),
            function(
                "save_theme",
                "Save a theme as a file in the Themes folder and, unless activate is false, switch the app to it at once. Under an existing theme file's id it replaces that theme, which is how themes are edited. It shows in Settings > Appearance next to the other themes.",
                properties: [
                    "theme": themeProperty,
                    "activate": ["type": "boolean", "description": "Select the theme after saving. Default true."],
                ],
                required: ["theme"]),
            function(
                "delete_theme",
                "Move a theme file to the Trash, only when the user asks for it. If it is in use, the app switches to the built-in theme it was based on. Built-ins, saved profiles and Custom cannot be deleted here.",
                properties: ["id": ["type": "string", "description": "Theme file id, e.g. \"terminal\" or \"file:terminal\"."]],
                required: ["id"]),
        ]
    }

    func execute(toolName: String, arguments: [String: Any]) throws -> Output {
        switch toolName {
        case "get_theme_rules": return Output(text: ThemeFileGuide.markdown)
        case "list_themes": return Output(text: try json(list()))
        case "get_theme": return Output(text: try get(arguments))
        case "list_fonts": return Output(text: try fonts(arguments))
        case "preview_theme": return try preview(arguments)
        case "save_theme": return Output(text: try save(arguments))
        case "delete_theme": return Output(text: try delete(arguments))
        default: throw ToolError.invalidArguments("Unknown tool \(toolName)")
        }
    }

    // MARK: - Reading

    private func list() -> [String: Any] {
        func entry(_ theme: AppTheme, kind: String, extra: [String: Any] = [:]) -> [String: Any] {
            var object: [String: Any] = [
                "id": theme.id, "name": theme.name, "kind": kind, "description": theme.mood,
                "active": theme.id == themes.themeID,
            ]
            object.merge(extra) { $1 }
            return object
        }
        var list = AppTheme.builtIn.map { entry($0, kind: "built-in") }
        list += themes.profiles.map { entry($0.resolve(), kind: "profile") }
        list += themes.fileThemes.map {
            entry($0.resolve(), kind: "file", extra: ["file": themes.fileStore.url(for: $0.id).path])
        }
        list.append(entry(themes.custom.resolve(), kind: "custom"))
        var result: [String: Any] = ["themes": list, "folder": themes.fileStore.folder.path]
        if !themes.fileThemeProblems.isEmpty {
            result["files_with_problems"] = themes.fileThemeProblems
        }
        return result
    }

    private func get(_ arguments: [String: Any]) throws -> String {
        let id = try requiredString("id", arguments)
        if let file = fileTheme(id) {
            var object = file.jsonObject
            object["_file"] = themes.fileStore.url(for: file.id).path
            object["_note"] = "Theme file. Save under the same id to change it."
            return try json(object)
        }
        let theme: AppTheme
        if let builtIn = AppTheme.builtIn(id: id) {
            theme = builtIn
        } else if let profile = themes.profiles.first(where: { $0.themeID == id }) {
            theme = profile.resolve()
        } else if id == AppTheme.customID {
            theme = themes.custom.resolve()
        } else {
            throw ToolError.invalidArguments("There is no theme \"\(id)\". list_themes shows the ids.")
        }
        let newID = suggestedID(for: theme.name)
        var object = ThemeFile.snapshot(of: theme, id: newID, name: theme.name).jsonObject
        object["_note"] = "Every value of \(theme.name) written out. Change what the user asked for, give it a new name, and save_theme creates the theme file \"\(newID)\"; \(theme.name) itself stays as it is."
        return try json(object)
    }

    private func fonts(_ arguments: [String: Any]) throws -> String {
        let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let families = installedFamilies().filter { query.isEmpty || $0.lowercased().contains(query) }
        let entries = families.map { family -> [String: Any] in
            let fixed = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch ?? false
            return ["family": family, "monospaced": fixed]
        }
        return try json(["fonts": entries, "count": entries.count])
    }

    // MARK: - Drafts

    /// The checked draft; clients send the theme as an object, some as a JSON string.
    private func draft(_ arguments: [String: Any]) throws -> ThemeFile {
        var object = arguments["theme"] as? [String: Any]
        if object == nil, let text = arguments["theme"] as? String {
            object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        guard var object else {
            throw ToolError.invalidArguments("theme must be an object with at least id and name (see get_theme_rules).")
        }
        object.removeValue(forKey: "_note")
        object.removeValue(forKey: "_file")
        do {
            return try ThemeFileValidator.validated(object)
        } catch let failure as ThemeFileValidator.Failure {
            throw ToolError.custom(failure.localizedDescription)
        }
    }

    private func warnings(for file: ThemeFile) -> [String] {
        ThemeFileValidator.warnings(for: file, installedFamilies: Set(installedFamilies()))
    }

    private func preview(_ arguments: [String: Any]) throws -> Output {
        let file = try draft(arguments)
        guard let png = ThemePreviewSheet.png(of: file.resolve()) else {
            throw ToolError.custom("The theme is valid, but the preview picture could not be drawn.")
        }
        var result: [String: Any] = [
            "valid": true, "id": file.id,
            "layout": "Light mode on the left, dark mode on the right: sidebar, a card with title, body and caption text, buttons, status chips, the eight speaker colours and a terminal.",
            "status": fileTheme(file.id) != nil
                ? "Saving replaces the theme file \"\(file.id)\"." : "Saving adds a new theme file.",
            "next": "Look at the picture. Fix what does not match what the user asked for and preview again, or call save_theme with the same theme.",
        ]
        let warnings = warnings(for: file)
        if !warnings.isEmpty { result["warnings"] = warnings }
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

    private func save(_ arguments: [String: Any]) throws -> String {
        let file = try draft(arguments)
        let existed = fileTheme(file.id) != nil
        let url = try themes.saveFileTheme(file)
        let activate = arguments["activate"] as? Bool ?? true
        if activate { themes.themeID = file.themeID }
        var result: [String: Any] = [
            "saved": true, "id": file.themeID, "name": file.name, "file": url.path,
            "result": existed ? "updated" : "created", "active": themes.themeID == file.themeID,
            "note": activate
                ? "MinuteMind uses it now. The user can switch back in Settings > Appearance."
                : "It is in Settings > Appearance; select it there or with update_setting theme \"\(file.themeID)\".",
        ]
        let warnings = warnings(for: file)
        if !warnings.isEmpty { result["warnings"] = warnings }
        return try json(result)
    }

    private func delete(_ arguments: [String: Any]) throws -> String {
        let id = try requiredString("id", arguments)
        guard let file = fileTheme(id) else {
            throw ToolError.invalidArguments("\"\(id)\" is not a theme file. Only theme files can be deleted; list_themes shows them (kind \"file\").")
        }
        let wasActive = themes.themeID == file.themeID
        try themes.deleteFileTheme(id: file.id)
        var result: [String: Any] = ["deleted": true, "id": file.themeID, "name": file.name, "note": "The file is in the Trash."]
        if wasActive { result["now_active"] = themes.themeID }
        return try json(result)
    }

    // MARK: - Helpers

    /// A theme file by "file:<id>" or the bare id.
    private func fileTheme(_ id: String) -> ThemeFile? {
        let bare = id.hasPrefix(ThemeFile.idPrefix) ? String(id.dropFirst(ThemeFile.idPrefix.count)) : id
        return themes.fileThemes.first { $0.id == bare }
    }

    /// A free theme file id from a name ("Midnight" → "midnight-2" when "midnight" is taken).
    private func suggestedID(for name: String) -> String {
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = String((slug.isEmpty ? "theme" : slug).prefix(32))
        let taken = Set(themes.fileThemes.map(\.id))
        if !taken.contains(base) { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    private func requiredString(_ key: String, _ arguments: [String: Any]) throws -> String {
        guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            throw ToolError.invalidArguments("\(key) is required.")
        }
        return value
    }

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
