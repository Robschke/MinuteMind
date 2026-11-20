// Purpose: MascotAvatarValidator, decides whether an avatar file can be drawn by the shared
//          moods and says in words what is wrong when it cannot: the size of the body, its
//          inks, the face the moods paint, head and feet, the neutral mouth, the colours and
//          the id.
// Dependencies: Sources/App/Supporting/MascotAvatarFile.swift (the file being checked),
//               Sources/App/Supporting/AssistantMascotPose.swift (the moods, mouthArea),
//               Sources/App/Supporting/CreatureRenderer.swift (CreaturePose)
// Used by: Sources/App/Supporting/MascotAvatarStore.swift (every file it loads or saves),
//          Sources/App/Services/MCP/MCPAvatarTools.swift (drafts, the rules text),
//          Tests/MascotAvatarValidatorTests.swift
// Notes: - Where the face is comes from the pose code, never from a second list here: every
//          mood is drawn over a body with no pixels at all, so whatever shows up is what the
//          mood itself paints. Eyes, cheeks and the pixels of the mouths have to land on a
//          filled pixel of the body (not empty, not the outline), or the face would float beside
//          the creature or vanish in its outline.
//        - Arms, the thumb, headphones and the laptop are left free. They are drawn beside and
//          over the body by design (a waving arm stands in empty space on every built-in), so a
//          rule about them would reject the avatars the app ships with. The one thing checked
//          is the arm at rest, which those moods take away: the outline has to close behind it.
//        - An edited built-in is drawn with its own traits, so its shades and its half closed
//          eyes are checked too.
//        - Every issue names the pixel as x and y (both counted from 0, top left), what is
//          there, what is drawn there and in which moods, so a drawing can be fixed from the
//          message alone.

import Foundation

enum MascotAvatarValidator {
    /// The inks a body may be drawn with; "." is an empty pixel.
    static let bodyInks: [MascotInk] = [.outline, .body, .shine, .cheek, .eye, .feature]
    static let emptyPixel: Character = "."
    static let maxNameLength = 24
    static let maxIDLength = 40

    struct Failure: LocalizedError, Equatable {
        let issues: [String]
        var errorDescription: String? {
            "The avatar is not valid yet (\(issues.count) issue\(issues.count == 1 ? "" : "s")):\n"
                + issues.map { "- \($0)" }.joined(separator: "\n")
                + "\nCoordinates are x (0 to 11, left to right) and y (0 to 12, top to bottom). Call get_avatar_rules for the face zones."
        }
    }

    /// Reads and checks a JSON object; throws `Failure` with every issue found.
    static func validated(_ object: [String: Any]) throws -> MascotAvatarFile {
        let (file, readIssues) = MascotAvatarFile.read(object)
        let all = readIssues + issues(in: file, skippingFields: readIssues)
        guard all.isEmpty else { throw Failure(issues: all) }
        return file
    }

    /// Everything wrong with a file, empty when it can be saved.
    static func issues(in file: MascotAvatarFile) -> [String] {
        issues(in: file, skippingFields: [])
    }

    /// Fields the reader already complained about are not reported a second time.
    private static func issues(in file: MascotAvatarFile, skippingFields readIssues: [String]) -> [String] {
        func wasRead(_ key: String) -> Bool { !readIssues.contains { $0.hasPrefix("\"\(key)\"") } }
        var issues: [String] = []

        if wasRead("id") { issues += idIssues(file.id) }
        if wasRead("name"), file.builtIn == nil {
            let name = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                issues.append("\"name\" is empty.")
            } else if name.count > maxNameLength || name.contains(where: \.isNewline) {
                issues.append("\"name\" must be one line of at most \(maxNameLength) characters.")
            }
        }
        if file.kind != MascotAvatar.Kind.pixel.rawValue {
            issues.append("\"kind\" is \"\(file.kind)\": only \"pixel\" is supported.")
        }
        if file.formatVersion != MascotAvatarFile.currentFormatVersion {
            issues.append("\"formatVersion\" is \(file.formatVersion): this version of MinuteMind reads \(MascotAvatarFile.currentFormatVersion).")
        }
        if let body = file.bodyColor, MascotAvatarFile.color(body) == nil {
            issues.append("\"bodyColor\" is \"\(body)\": use #RRGGBB (for example #F5A65B), or null for the theme's accent colour.")
        }
        if wasRead("featureColor"), MascotAvatarFile.color(file.featureColor) == nil {
            issues.append("\"featureColor\" is \"\(file.featureColor)\": use #RRGGBB (for example #C8702A).")
        }

        var shapeIsRight = false
        if wasRead("rows") {
            let shape = shapeIssues(file.rows)
            issues += shape
            shapeIsRight = shape.isEmpty
        }
        let face = FaceZones(traitsOf: file)
        if shapeIsRight {
            issues += bodyIssues(MascotGrid(rows: file.rows), face: face)
        }
        if wasRead("neutralMouth") {
            for pair in file.neutralMouth where pair.count == 2 {
                if !face.mouthArea.contains(where: { $0.x == pair[0] && $0.y == pair[1] }) {
                    issues.append("\"neutralMouth\" has a pixel at (x \(pair[0]), y \(pair[1])), outside the mouth area. The mouth area is: \(describe(face.mouthArea)).")
                }
            }
        }
        return issues
    }

    // MARK: - Id

    private static func idIssues(_ id: String) -> [String] {
        if MascotAvatarCatalog.builtIns.contains(where: { $0.id == id }) { return [] }
        if let builtIn = MascotAvatarCatalog.builtIns.first(where: { $0.id.lowercased() == id.lowercased() }) {
            return ["\"id\" is \"\(id)\": to edit the built-in \(builtIn.name) write its id exactly, \"\(builtIn.id)\"."]
        }
        let allowed = id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        let wellFormed = !id.isEmpty && id.count <= maxIDLength && allowed
            && !id.hasPrefix("-") && !id.hasSuffix("-") && !id.contains("--")
        return wellFormed ? [] : [
            "\"id\" is \"\(id)\": use a slug of lowercase letters, digits and single hyphens, at most \(maxIDLength) characters (for example \"red-fox\"), or the id of an existing avatar to edit it."
        ]
    }

    // MARK: - Body

    private static func shapeIssues(_ rows: [String]) -> [String] {
        var issues: [String] = []
        if rows.count != MascotGrid.height {
            issues.append("\"rows\" has \(rows.count) rows: it needs exactly \(MascotGrid.height), top to bottom.")
        }
        let allowed = Set(bodyInks.map(\.rawValue) + [emptyPixel])
        let letters = ([emptyPixel] + bodyInks.map(\.rawValue)).map { String($0) }.joined(separator: " ")
        for (y, row) in rows.enumerated() {
            if row.count != MascotGrid.width {
                issues.append("Row y \(y) (\"\(row)\") has \(row.count) characters: every row needs exactly \(MascotGrid.width).")
            }
            for (x, character) in row.enumerated() where !allowed.contains(character) {
                issues.append("Row y \(y) has \"\(character)\" at x \(x): only \(letters) are allowed.")
            }
        }
        return issues
    }

    private static func isFilled(_ ink: MascotInk?) -> Bool {
        guard let ink else { return false }
        return ink != .outline
    }

    private static func bodyIssues(_ body: MascotGrid, face: FaceZones) -> [String] {
        var issues: [String] = []
        let columns = 0..<MascotGrid.width
        if !columns.contains(where: { body[$0, face.headTopRow] != nil }) {
            issues.append("Row y \(face.headTopRow) is empty: the head has to reach it, the headphones sit right above (ears and tufts may go up into row y \(face.headTopRow - 1)).")
        }
        if !columns.contains(where: { body[$0, face.feetRow] != nil }) {
            issues.append("Row y \(face.feetRow) is empty: the feet stand in the last row.")
        }
        for spot in face.spots where !isFilled(body[spot.x, spot.y]) {
            let found = body[spot.x, spot.y] == nil ? "empty (\".\")" : "outline (\"o\")"
            let moods = spot.moods.joined(separator: ", ")
            issues.append("Pixel (x \(spot.x), y \(spot.y)) is \(found), but the \(spot.part.rawValue) are drawn there (\(moods)). Make it a filled body pixel (b, h, c, e or f); the outline has to run outside the face.")
        }
        // The arms at rest are taken away when the creature waves, types or cheers.
        for arm in face.armsAtRest where body[arm.x, arm.y] != nil {
            let inner = arm.x + (arm.x < MascotGrid.width / 2 ? 1 : -1)
            if body[inner, arm.y] != .outline {
                issues.append("Pixel (x \(arm.x), y \(arm.y)) is the arm at rest: waving, typing and cheering take it away. The pixel beside it (x \(inner), y \(arm.y)) must then be outline (\"o\"), or the body gets a hole there. Draw the arm as one \"o\" outside the body's outline, or leave (x \(arm.x), y \(arm.y)) empty.")
            }
        }
        return issues
    }

    static func describe(_ points: [(x: Int, y: Int)]) -> String {
        Dictionary(grouping: points, by: \.y).sorted { $0.key < $1.key }.map { y, row in
            "y \(y): x \(row.map { String($0.x) }.joined(separator: ", "))"
        }.joined(separator: "; ")
    }
}

// MARK: - Where the moods paint the face

/// The pixels of an avatar the shared moods paint its face on, read from the pose code.
struct FaceZones {
    enum Part: String {
        case eyes
        case cheeks
        /// Reads "the mouths are drawn there".
        case mouth = "mouths"
    }

    struct Spot {
        let x: Int
        let y: Int
        let part: Part
        /// The moods that paint it, in the order they were sampled.
        let moods: [String]
    }

    /// Row by row, left to right.
    let spots: [Spot]
    let mouthArea: [(x: Int, y: Int)]
    /// The row the head has to reach: the one under the headphones' band.
    let headTopRow: Int
    /// The row the feet stand in.
    let feetRow = MascotGrid.height - 1
    /// The side nubs, which waving, typing and cheering remove (none for the armless Lime).
    let armsAtRest: [(x: Int, y: Int)]

    /// The zones of an avatar with the traits this file will be drawn with.
    init(traitsOf file: MascotAvatarFile) {
        let base = file.builtIn
        self.init(
            hasArms: base.map { !$0.nubs.isEmpty } ?? true,
            wearsShades: base?.wearsShades ?? false, isContent: base?.isContent ?? false)
    }

    init(hasArms: Bool = true, wearsShades: Bool = false, isContent: Bool = false) {
        let empty = String(repeating: String(MascotAvatarValidator.emptyPixel), count: MascotGrid.width)
        let probe = MascotAvatar(
            id: "probe", name: "Probe", rows: Array(repeating: empty, count: MascotGrid.height),
            naturalBody: nil, featureColor: 0x000000, neutralMouth: [],
            hasArms: hasArms, wearsShades: wearsShades, isContent: isContent)
        let mouthArea = AssistantMascotPose.mouthArea
        func inMouth(_ x: Int, _ y: Int) -> Bool { mouthArea.contains { $0.x == x && $0.y == y } }

        var parts: [Int: Part] = [:]
        var moods: [Int: [String]] = [:]
        var bandTop = MascotGrid.height
        for (label, pose) in Self.poses(of: probe) {
            let grid = AssistantMascotPose.frame(pose).grid
            for y in 0..<MascotGrid.height {
                for x in 0..<MascotGrid.width {
                    guard let ink = grid[x, y] else { continue }
                    if ink == .gear { bandTop = min(bandTop, y) }
                    let part: Part
                    switch ink {
                    case .eye, .glint where !inMouth(x, y): part = .eyes
                    case .cheek where !inMouth(x, y): part = .cheeks
                    case .outline where inMouth(x, y), .cheek where inMouth(x, y): part = .mouth
                    default: continue
                    }
                    let key = y * MascotGrid.width + x
                    // Eyes win over cheeks where a look puts an eye on a cheek.
                    if parts[key] == nil || part == .eyes { parts[key] = part }
                    if moods[key]?.contains(label) != true { moods[key, default: []].append(label) }
                }
            }
        }
        spots = parts.keys.sorted().map { key in
            Spot(x: key % MascotGrid.width, y: key / MascotGrid.width, part: parts[key] ?? .eyes, moods: moods[key] ?? [])
        }
        self.mouthArea = mouthArea
        armsAtRest = probe.nubs.map { (x: $0.0, y: $0.1) }
        headTopRow = bandTop + 1
    }

    /// What a mood is called in an issue.
    static func label(_ mood: MascotMood) -> String {
        switch mood {
        case .idle: "idle"
        case .sleeping: "sleeping"
        case .working: "working"
        case .waiting: "waiting"
        case .celebrating: "celebrating"
        case .error: "error"
        case .asking: "asking"
        case .dictating: "dictating"
        case .thumbsUp: "thumb up"
        }
    }

    /// Every mood in every state that changes its face: 24 s in eighths of a second (blinks,
    /// glances, talking, waving, the calmer poses that follow), every direction the eyes can
    /// look, hovering, a hop, headphones, the still pose and running both ways.
    private static func poses(of avatar: MascotAvatar) -> [(String, CreaturePose)] {
        var poses: [(String, CreaturePose)] = []
        let looks = [-1, 0, 1].flatMap { x in [-1, 0, 1].map { y in (x: x, y: y) } }
        for mood in MascotMood.allCases {
            let name = label(mood)
            func add(_ label: String = name, _ change: (inout CreaturePose) -> Void = { _ in }) {
                var pose = CreaturePose(mood: mood, time: 0.3, look: nil, avatar: avatar)
                change(&pose)
                poses.append((label, pose))
            }
            for step in 0..<192 {
                let time = Double(step) * 0.125
                add { $0.time = time; $0.moodAge = time }
            }
            for look in looks {
                add { $0.look = look }
                add(mood == .idle ? "idle, hovered" : name) { $0.look = look; $0.hovering = true }
            }
            for hopAge in [0.05, 0.2, 0.3, 0.55, 0.7] {
                add { $0.hopAge = hopAge }
                add { $0.hopAge = hopAge; $0.headphones = true }
            }
            add { $0.headphones = true }
            add { $0.animated = false }
            add { $0.keepsWaving = true; $0.moodAge = 20 }
            for direction in [-1, 1] {
                for time in [0.0, 0.1] {
                    add("running") { $0.running = direction; $0.time = time }
                    add("running") { $0.running = direction; $0.time = time; $0.headphones = true }
                }
            }
        }
        return poses
    }
}
