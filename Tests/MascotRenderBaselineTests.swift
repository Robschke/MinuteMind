// Purpose: Pins the drawing of every built-in creature: each avatar's data (name, colours, body)
//          and every frame of every mood are written out as text and compared with a recorded
//          fingerprint, so a change to the avatars or the pose code that moves a single pixel
//          fails here.
// Dependencies: Sources/App/Supporting/AssistantMascotPose.swift (frames),
//               Sources/App/Supporting/MascotAvatarCatalog.swift (the creatures),
//               Sources/App/Views/CreatureView.swift (the opt-in pictures)
// Notes: A fingerprint is the FNV-1a hash of the avatar's text, one per avatar, so a failure names
//        the creature. A wanted change to the art updates the fingerprints: run with
//        MM_MASCOT_BASELINE_DIR=<folder> and take them from `fingerprints.txt` there.
//        With that folder set the test also writes `<avatar>.txt` (the text behind the
//        fingerprint, for a diff that shows which frame changed) and a few PNGs per avatar drawn
//        by the real view, which cover the colours. The PNGs depend on the theme and the
//        companion's settings of the machine, so they are compared between two runs by hand and
//        never checked here.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MinuteMindApp

@Suite("Mascot render baseline")
@MainActor
struct MascotRenderBaselineTests {
    private static let avatarIDs = ["blob", "duck", "dog", "puppy", "pug", "cat", "coolCat", "sweetCat", "lime"]

    private static let fingerprints: [String: String] = [
        "blob": "fda0dd07172e5290",
        "duck": "9ef19143f5efc4be",
        "dog": "22a308c1bb3c02e9",
        "puppy": "cb6dd4e27ef22b12",
        "pug": "1ccdc1f00a0748a6",
        "cat": "6a8095ddf77e4285",
        "coolCat": "83bd3a6c5d6d13dd",
        "sweetCat": "ab720d1a5502f32b",
        "lime": "7370f1f6dbf255f3",
    ]

    private static let moods: [(String, MascotMood)] = [
        ("idle", .idle), ("sleeping", .sleeping), ("working", .working), ("waiting", .waiting),
        ("celebrating", .celebrating), ("error", .error), ("asking", .asking),
        ("dictating", .dictating), ("thumbsUp", .thumbsUp),
    ]

    private static func avatar(_ id: String) -> MascotAvatar? { MascotAvatarCatalog.avatar(id: id) }

    private static func text(_ grid: MascotGrid) -> String {
        (0..<MascotGrid.height).map { y in
            String((0..<MascotGrid.width).map { x in grid[x, y]?.rawValue ?? "." })
        }.joined(separator: "\n")
    }

    private static func text(_ frame: MascotFrame) -> String {
        let overhead = frame.overhead.map { "\($0.x),\($0.y),\($0.ink.rawValue)" }.joined(separator: " ")
        let bubble = frame.bubble.map { String(describing: $0) } ?? "none"
        return text(frame.grid) + "\noverhead [\(overhead)] lift \(frame.lift) bubble \(bubble) bubbleLift \(frame.bubbleLift)"
    }

    /// Everything that decides how the avatar looks, then every frame.
    private static func text(of avatar: MascotAvatar) -> String {
        var lines: [String] = []
        lines.append("id \(avatar.id) name \(avatar.name)")
        lines.append("naturalBody \(avatar.naturalBody.map { String($0, radix: 16) } ?? "accent") featureColor \(String(avatar.featureColor, radix: 16))")
        lines.append("nubs \(avatar.nubs.map { "\($0.0),\($0.1)" }.joined(separator: " "))")
        lines.append("neutralMouth \(avatar.neutralMouth.map { "\($0.0),\($0.1)" }.joined(separator: " "))")
        lines.append("wearsShades \(avatar.wearsShades) isContent \(avatar.isContent)")
        lines.append("body\n" + text(avatar.body))
        lines.append("squashed\n" + text(avatar.squashed))

        func add(_ label: String, _ input: AssistantMascotPose.Input) {
            lines.append("# \(label)\n" + text(AssistantMascotPose.frame(input)))
        }
        for (name, mood) in moods {
            // Every eighth of a second for 24 s: breathing, blinks, glances, the heart, talking,
            // waving and the calmer poses that follow.
            for step in 0..<192 {
                let time = Double(step) * 0.125
                add("\(name) t \(time)", .init(mood: mood, time: time, look: nil, moodAge: time, avatar: avatar))
            }
            for time in [0.05, 0.3, 4.2, 4.4] {
                let at = "\(name) t \(time)"
                add("\(at) hovering", .init(mood: mood, time: time, look: nil, hovering: true, avatar: avatar))
                add("\(at) headphones", .init(mood: mood, time: time, look: nil, headphones: true, avatar: avatar))
                add("\(at) hovering headphones", .init(mood: mood, time: time, look: nil, hovering: true, headphones: true, avatar: avatar))
                for look in [(1, 0), (-1, 0), (0, -1), (1, 1), (-1, -1)] {
                    add("\(at) look \(look.0) \(look.1)", .init(mood: mood, time: time, look: look, avatar: avatar))
                }
                for hopAge in [0.05, 0.2, 0.4, 0.55, 0.7, 0.8] {
                    add("\(at) hop \(hopAge)", .init(mood: mood, time: time, look: nil, hopAge: hopAge, avatar: avatar))
                    add("\(at) hop \(hopAge) headphones", .init(mood: mood, time: time, look: nil, hopAge: hopAge, headphones: true, avatar: avatar))
                }
                for moodAge in [0.0, 0.3, 1.0, 5, 30] {
                    add("\(at) moodAge \(moodAge)", .init(mood: mood, time: time, look: nil, moodAge: moodAge, avatar: avatar))
                    add("\(at) moodAge \(moodAge) keepsWaving", .init(mood: mood, time: time, look: nil, moodAge: moodAge, avatar: avatar, keepsWaving: true))
                }
                for direction in [1, -1] {
                    add("\(at) running \(direction)", .init(mood: mood, time: time, look: nil, avatar: avatar, running: direction))
                    add("\(at) running \(direction) headphones", .init(mood: mood, time: time, look: nil, headphones: true, avatar: avatar, running: direction))
                }
                add("\(at) still", .init(mood: mood, time: time, look: nil, avatar: avatar, animated: false))
                add("\(at) still hovering", .init(mood: mood, time: time, look: nil, hovering: true, avatar: avatar, animated: false))
                add("\(at) still headphones", .init(mood: mood, time: time, look: nil, headphones: true, avatar: avatar, animated: false))
                add("\(at) still moodAge 30", .init(mood: mood, time: time, look: nil, moodAge: 30, avatar: avatar, animated: false))
                add("\(at) still running", .init(mood: mood, time: time, look: nil, avatar: avatar, animated: false, running: 1))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    private static var dumpFolder: URL? {
        ProcessInfo.processInfo.environment["MM_MASCOT_BASELINE_DIR"].map { URL(fileURLWithPath: $0) }
    }

    @Test("Every built-in avatar draws every mood exactly as recorded")
    func framesMatchTheBaseline() throws {
        var found: [String] = []
        for id in Self.avatarIDs {
            let avatar = try #require(Self.avatar(id), "\(id) is a built-in avatar")
            let text = Self.text(of: avatar)
            let fingerprint = Self.fingerprint(text)
            found.append("\"\(id)\": \"\(fingerprint)\",")
            #expect(Self.fingerprints[id] == fingerprint, "\(id) is drawn differently")
            if let folder = Self.dumpFolder {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try text.write(to: folder.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8)
            }
        }
        if let folder = Self.dumpFolder {
            try found.joined(separator: "\n").write(
                to: folder.appendingPathComponent("fingerprints.txt"), atomically: true, encoding: .utf8)
        }
    }

    @Test("Pictures of every built-in avatar", .enabled(if: ProcessInfo.processInfo.environment["MM_MASCOT_BASELINE_DIR"] != nil))
    func pictures() throws {
        let folder = try #require(Self.dumpFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let poses: [(String, MascotMood, Bool)] = [
            ("idle", .idle, false), ("working", .working, false), ("waiting", .waiting, false),
            ("error", .error, false), ("thumbsUp", .thumbsUp, false), ("recording", .idle, true),
        ]
        for id in Self.avatarIDs {
            let avatar = try #require(Self.avatar(id))
            for (name, mood, headphones) in poses {
                let frame = CreatureRenderer.frame(.init(
                    mood: mood, time: 0.05, look: nil, moodAge: 30, headphones: headphones, avatar: avatar, animated: false))
                // In the companion's own colour, in a project's default colour and in an own colour.
                let colors: [(String, Color?)] = [
                    ("home", nil),
                    ("project", CompanionAppearance.projectBodyColor(avatar, hex: nil)),
                    ("own", CompanionAppearance.projectBodyColor(avatar, hex: "#3366CC")),
                ]
                for (colorName, color) in colors {
                    let view = CreatureView(frame: frame, avatar: avatar, unit: 3, bodyColor: color)
                    try Self.write(view, to: folder.appendingPathComponent("\(id)-\(name)-\(colorName).png"))
                }
            }
        }
    }

    private static func write(_ view: some View, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
