// Purpose: AvatarMoodSheet, one picture of an avatar in every mood (idle, blinking, working,
//          waiting, celebrating, error, sleeping, recording, running, thumb up), and that
//          picture as a PNG. A drawing can be judged from it before it is saved.
// Dependencies: Sources/App/Views/CreatureView.swift (draws each creature),
//               Sources/App/Supporting/CreatureRenderer.swift (CreaturePose),
//               Sources/App/Supporting/CompanionAppearance.swift (the default body colour)
// Used by: Sources/App/Services/MCP/MCPAvatarTools.swift (preview_avatar),
//          Tests/MCPAvatarToolsTests.swift
// Notes: - The sheet is built from CreatureView, the view the app itself draws creatures with,
//          so the preview cannot differ from the app and works for every kind of avatar.
//        - The body is shown in the avatar's natural colour (the theme's accent without one),
//          never in the user's own companion colour: that is how a project wears it.
//        - Fixed light and dark halves, whatever the app's appearance is: the creature stands
//          on any desktop, so its outline has to read on both.
//        - Bubbles are left out; they are the same for every avatar.

import AppKit
import SwiftUI

struct AvatarMoodSheet: View {
    let avatar: MascotAvatar

    struct Cell: Identifiable {
        let label: String
        let pose: CreaturePose
        var id: String { label }
    }

    static let labels = [
        "idle", "blinking", "working", "waiting", "celebrating",
        "error", "sleeping", "recording", "running", "thumb up",
    ]

    /// The moods in the order of `labels`, each at a moment that shows it well.
    static func cells(for avatar: MascotAvatar) -> [Cell] {
        func pose(_ mood: MascotMood, time: TimeInterval = 0.55, _ change: (inout CreaturePose) -> Void = { _ in }) -> CreaturePose {
            var pose = CreaturePose(mood: mood, time: time, look: nil, moodAge: 4, avatar: avatar)
            change(&pose)
            return pose
        }
        // The first blink: a blink lasts longer than the step, so one is always found.
        let blink = stride(from: 0.0, to: 8, by: 0.05).first(where: AssistantMascotPose.isBlinking) ?? 0
        let poses = [
            pose(.idle), pose(.idle, time: blink), pose(.working), pose(.waiting), pose(.celebrating),
            pose(.error), pose(.sleeping), pose(.idle) { $0.headphones = true },
            pose(.idle, time: 0) { $0.running = 1 }, pose(.thumbsUp),
        ]
        return zip(labels, poses).map { Cell(label: $0, pose: $1) }
    }

    private static let unit: CGFloat = 5
    private static let columns = 5

    var body: some View {
        let cells = Self.cells(for: avatar)
        let color = CompanionAppearance.projectBodyColor(avatar, hex: nil)
        VStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                Grid(horizontalSpacing: 14, verticalSpacing: 10) {
                    ForEach(0..<(cells.count / Self.columns), id: \.self) { row in
                        GridRow {
                            ForEach(cells[(row * Self.columns)..<((row + 1) * Self.columns)]) { cell in
                                VStack(spacing: 2) {
                                    CreatureView(pose: cell.pose, unit: Self.unit, bodyColor: color)
                                    Text(cell.label)
                                        .font(.system(size: 11))
                                        .foregroundStyle(dark ? Color(white: 0.8) : Color(white: 0.3))
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .background(dark ? Color(white: 0.13) : Color(white: 0.95))
                .environment(\.colorScheme, dark ? .dark : .light)
            }
        }
    }

    /// The sheet as PNG data, nil when it could not be drawn.
    @MainActor
    static func png(of avatar: MascotAvatar) -> Data? {
        let renderer = ImageRenderer(content: AvatarMoodSheet(avatar: avatar))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
