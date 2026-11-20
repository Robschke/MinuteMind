// Purpose: MascotAvatarFile, an avatar as it is written to disk and sent over MCP: one JSON
//          object with id, name, kind, the 13 rows of the body, the two colours, the neutral
//          mouth and a format version; an avatar of kind "svg" carries its drawings (SVGAvatarArt)
//          instead of rows, feature colour and mouth. Reads such an object, writes one, and turns
//          it into the MascotAvatar the app draws.
// Dependencies: Sources/App/Supporting/MascotAvatar.swift (the avatar, the built-in ones and
//               their traits), Sources/App/Supporting/SVGAvatarArt.swift (svg drawings)
// Used by: Sources/App/Supporting/MascotAvatarValidator.swift (checks a file),
//          Sources/App/Supporting/MascotAvatarStore.swift (the avatars folder),
//          Sources/App/Services/MCP/MCPAvatarTools.swift (drafts from Claude, get_avatar)
// Notes: - Reading is forgiving about what is missing (kind and formatVersion have defaults) and
//          never fails: a wrong type becomes an issue in words, so a draft comes back with
//          everything that is wrong with it at once.
//        - `bodyColor` may be null: the body then takes the theme's accent, as the Blob does.
//        - A file with a built-in's id is an edit of that built-in. It replaces body, colours and
//          mouth; the built-in keeps its name and its traits (arms, shades, the content idle),
//          which no file can carry.

import Foundation

struct MascotAvatarFile: Equatable, Sendable {
    static let currentFormatVersion = 1

    var id: String
    var name: String
    var kind: String = MascotAvatar.Kind.pixel.rawValue
    /// Top to bottom, 13 strings of 12 characters.
    var rows: [String]
    /// `#RRGGBB`; nil: the theme's accent.
    var bodyColor: String?
    /// `#RRGGBB`, the colour of the "f" pixels.
    var featureColor: String
    /// Pairs of x and y.
    var neutralMouth: [[Int]]
    /// The drawings of an avatar of kind "svg"; rows, featureColor and neutralMouth are unused then.
    var svg: SVGAvatarArt?
    var formatVersion: Int = MascotAvatarFile.currentFormatVersion

    var isSVG: Bool { kind == MascotAvatar.Kind.svg.rawValue }

    /// An avatar's current data, as a file would hold it.
    init(_ avatar: MascotAvatar) {
        id = avatar.id
        name = avatar.name
        kind = avatar.kind.rawValue
        rows = avatar.rows
        bodyColor = avatar.naturalBody.map(Self.hex)
        featureColor = Self.hex(avatar.featureColor)
        neutralMouth = avatar.neutralMouth.map { [$0.0, $0.1] }
        svg = avatar.art
    }

    init(id: String, name: String, rows: [String], bodyColor: String?, featureColor: String, neutralMouth: [[Int]]) {
        self.id = id
        self.name = name
        self.rows = rows
        self.bodyColor = bodyColor
        self.featureColor = featureColor
        self.neutralMouth = neutralMouth
    }

    // MARK: - JSON

    /// Reads a JSON object. `issues` names every field that is missing or has the wrong type;
    /// the file then holds an empty value there.
    static func read(_ object: [String: Any]) -> (file: MascotAvatarFile, issues: [String]) {
        var issues: [String] = []
        func string(_ key: String, required: Bool = true) -> String? {
            guard let value = object[key], !(value is NSNull) else {
                if required { issues.append("\"\(key)\" is missing.") }
                return nil
            }
            guard let text = value as? String else {
                issues.append("\"\(key)\" must be a string.")
                return nil
            }
            return text
        }

        var file = MascotAvatarFile(id: "", name: "", rows: [], bodyColor: nil, featureColor: "", neutralMouth: [])
        file.id = string("id") ?? ""
        file.name = string("name") ?? ""
        file.kind = string("kind", required: false) ?? MascotAvatar.Kind.pixel.rawValue
        file.bodyColor = string("bodyColor", required: false)
        if let version = object["formatVersion"], !(version is NSNull) {
            if let number = (version as? NSNumber).flatMap(Self.wholeNumber) {
                file.formatVersion = number
            } else {
                issues.append("\"formatVersion\" must be a whole number.")
            }
        }
        if file.isSVG {
            // A drawing in any style: no pixel rows, colours or mouth.
            let (art, artIssues) = SVGAvatarArt.read(object["svg"])
            file.svg = art
            issues += artIssues
            return (file, issues)
        }
        file.featureColor = string("featureColor") ?? ""

        if let rows = object["rows"] as? [String] {
            file.rows = rows
        } else {
            issues.append(object["rows"] == nil ? "\"rows\" is missing." : "\"rows\" must be a list of 13 strings.")
        }

        // JSONSerialization hands out booleans as numbers too; only whole numbers are pairs.
        if let pairs = object["neutralMouth"] as? [[Any]] {
            let whole = pairs.map { pair in pair.compactMap { ($0 as? NSNumber).flatMap(Self.wholeNumber) } }
            if zip(pairs, whole).allSatisfy({ $0.count == 2 && $1.count == 2 }) {
                file.neutralMouth = whole
            } else {
                issues.append("\"neutralMouth\" must be a list of [x, y] pairs of whole numbers, for example [[5, 9], [6, 9]].")
            }
        } else {
            issues.append(object["neutralMouth"] == nil
                ? "\"neutralMouth\" is missing (use [] when the body already draws the mouth)."
                : "\"neutralMouth\" must be a list of [x, y] pairs, for example [[5, 9], [6, 9]].")
        }
        return (file, issues)
    }

    /// The JSON object written to disk and returned over MCP.
    var jsonObject: [String: Any] {
        if isSVG {
            return [
                "id": id, "name": name, "kind": kind, "bodyColor": bodyColor ?? NSNull(),
                "svg": svg?.jsonObject ?? [:], "formatVersion": formatVersion,
            ]
        }
        return [
            "id": id, "name": name, "kind": kind, "rows": rows,
            "bodyColor": bodyColor ?? NSNull(), "featureColor": featureColor,
            "neutralMouth": neutralMouth, "formatVersion": formatVersion,
        ]
    }

    private static func wholeNumber(_ number: NSNumber) -> Int? {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value == value.rounded() && abs(value) < 1_000_000 ? Int(value) : nil
    }

    // MARK: - Colours

    /// `#RRGGBB` as 0xRRGGBB, nil when the text is anything else.
    static func color(_ text: String) -> UInt32? {
        let digits = text.dropFirst()
        guard text.hasPrefix("#"), digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }

    static func hex(_ color: UInt32) -> String {
        String(format: "#%06X", color & 0xFFFFFF)
    }

    // MARK: - The avatar

    /// The built-in this file edits, nil for an avatar of its own.
    var builtIn: MascotAvatar? {
        MascotAvatarCatalog.builtIns.first { $0.id == id }
    }

    /// The avatar the app draws. Call it on a file the validator accepted: colours it cannot
    /// read fall back to black and the accent.
    var avatar: MascotAvatar {
        let base = builtIn
        if isSVG, let svg {
            return MascotAvatar(id: id, name: base?.name ?? name, art: svg, naturalBody: bodyColor.flatMap(Self.color))
        }
        return MascotAvatar(
            id: id,
            name: base?.name ?? name,
            rows: rows,
            naturalBody: bodyColor.flatMap(Self.color),
            featureColor: Self.color(featureColor) ?? 0x000000,
            neutralMouth: neutralMouth.filter { $0.count == 2 }.map { ($0[0], $0[1]) },
            hasArms: base.map { !$0.nubs.isEmpty } ?? true,
            wearsShades: base?.wearsShades ?? false,
            isContent: base?.isContent ?? false)
    }
}
