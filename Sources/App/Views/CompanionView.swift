// Purpose: CompanionView, the drawing of the desktop companion in two layers: the pixel creature
//          (its own small panel that takes the mouse) and an overlay that lets every click through
//          with the speech bubble on the side with room and the badges (recording, unrecorded
//          meeting).
// Dependencies: Sources/App/Supporting/AssistantMascotPose.swift (frames, inks, bubbles),
//               Sources/App/Supporting/CompanionPlacement.swift (sizes and margins),
//               Sources/App/Supporting/CompanionController.swift (CompanionModel),
//               Sources/App/Components/DesignSystem.swift (theme colours)
// Used by: Sources/App/Supporting/CompanionController.swift (hosted in the companion's panels)
// Notes: 3 pt pixels: whole points keep the pixel art crisp. The body takes the theme's accent, the
//        outline is the accent with 55% black, eyes a fixed near-black. The bubble's colours keep
//        their meaning (orange "!" waiting, yellow on warm accents so it does not melt into the
//        body; green check; red error; neutral for thinking, questions and dictation).
//        Size and colour come from CompanionAppearance (Settings, Appearance); every offset is in
//        pixels so the layout scales with the creature.
//        Badges (design review): the recording badge is the pill's capture red, 3 pixels, pulsing for
//        the first minute and then steady (a recording lasts hours); an unrecorded meeting is a
//        hollow grey ring like the old pill's, a badge rather than a bubble so no mood hides it.
//        Both sit low on the side away from the bubble.
//        Two layers because the overlay's margins must never catch clicks meant for the app below;
//        the creature layer carries VoiceOver (a button with the companion's actions).

import AppKit
import SwiftUI

/// The creature itself, sized to its canvas.
struct CompanionCreatureView: View {
    let model: CompanionModel

    var body: some View {
        MascotCanvas(frame: model.frame, avatar: model.frontAvatar, bodyColor: model.frontColor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.frontName.map { "\($0) companion" } ?? "MinuteMind companion")
            .accessibilityValue(model.spokenState)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Show Options") { model.actions.showOptions() }
            .accessibilityAction(named: "Open Claude") { model.actions.openClaude() }
            .accessibilityAction(named: "Bring Claude Windows Here") { model.actions.summon() }
    }
}

/// Bubble and badges around the creature, in a panel that ignores the mouse.
struct CompanionOverlayView: View {
    let model: CompanionModel

    var body: some View {
        let margin = CompanionPlacement.sideMargin
        let top = CompanionPlacement.topMargin
        let pixel = MascotCanvas.pixel
        let frame = model.frame
        // Positions in pixels, so they follow the creature's size. Badges sit low on the side
        // away from the bubble.
        let badgeX = model.opensLeft ? margin + 9 * pixel : margin - 1.5 * pixel

        ZStack(alignment: .topLeading) {
            Color.clear
            if model.isRecording {
                RecordingBadge(pixel: pixel).offset(x: badgeX, y: top + 10 * pixel)
            } else if model.meetingRunning {
                MeetingRingBadge(pixel: pixel).offset(x: badgeX, y: top + 10 * pixel)
            }
            if model.showsBubble, let bubble = frame.bubble {
                MascotBubbleView(bubble: bubble, mirrored: !model.opensLeft)
                    .offset(
                        x: model.opensLeft ? margin - 5 * pixel : margin + CompanionPlacement.creatureSize.width - 2 * pixel,
                        y: top - 2 * pixel - CGFloat(frame.bubbleLift) * pixel)
            }
        }
        .frame(width: CompanionPlacement.panelSize.width, height: CompanionPlacement.panelSize.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// Draws one frame: shadow and creature.
struct MascotCanvas: View {
    let frame: MascotFrame
    /// Another creature's colours than the chosen one (the Settings picker).
    var avatar: MascotAvatar?
    /// A fixed pixel size instead of the Settings one (the tiny mark on starred projects,
    /// the companion's sidekicks).
    var pixelSize: CGFloat?
    /// A body colour instead of the avatar's (a project's sidekick in the project colour).
    var bodyColor: Color?
    @Environment(\.colorScheme) private var colorScheme

    /// Side of one pixel in points (Settings, Appearance: 2, 3 or 4).
    static var pixel: CGFloat { CompanionAppearance.shared.pixel }
    /// Empty rows above the creature, room for a two pixel hop.
    private static let headroom = 2

    var body: some View {
        let avatar = avatar ?? CompanionAppearance.shared.avatar
        let accent = bodyColor ?? CompanionAppearance.shared.bodyColor(for: avatar)
        let feature = Color(nsColor: ThemeColor.srgb(avatar.featureColor))
        let gear = DesignSystem.Colors.textPrimary.opacity(0.8)
        let shadow = colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.14)
        let pixel = pixelSize ?? Self.pixel
        let frame = frame

        Canvas { context, size in
            // The shadow shrinks while the creature is in the air.
            let shadowWidth = CGFloat(8 - frame.lift * 2) * pixel
            let groundY = CGFloat(Self.headroom + MascotGrid.height) * pixel
            context.fill(
                Path(ellipseIn: CGRect(x: (size.width - shadowWidth) / 2, y: groundY - pixel * 0.4,
                                       width: shadowWidth, height: pixel * 1.2)),
                with: .color(shadow)
            )
            let gridPixels = (0..<MascotGrid.height).flatMap { y in
                (0..<MascotGrid.width).compactMap { x in frame.grid[x, y].map { MascotPixel(x: x, y: y, ink: $0) } }
            }
            for cell in gridPixels + frame.overhead {
                let rect = Path(CGRect(x: CGFloat(cell.x) * pixel,
                                       y: CGFloat(cell.y + Self.headroom - frame.lift) * pixel,
                                       width: pixel, height: pixel))
                switch cell.ink {
                case .outline:
                    context.fill(rect, with: .color(accent))
                    context.fill(rect, with: .color(.black.opacity(0.55)))
                case .eye:
                    context.fill(rect, with: .color(.black.opacity(0.85)))
                case .body:
                    context.fill(rect, with: .color(accent))
                case .shine:
                    context.fill(rect, with: .color(accent))
                    context.fill(rect, with: .color(.white.opacity(0.55)))
                case .cheek:
                    context.fill(rect, with: .color(Color(red: 1, green: 0.55, blue: 0.62)))
                case .gear:
                    context.fill(rect, with: .color(gear))
                case .laptop:
                    context.fill(rect, with: .color(Color(white: 0.62)))
                case .laptopLogo:
                    context.fill(rect, with: .color(.white))
                case .feature:
                    context.fill(rect, with: .color(feature))
                }
            }
        }
        .frame(width: CGFloat(MascotGrid.width) * pixel, height: CGFloat(Self.headroom + MascotGrid.height + 1) * pixel)
    }
}

/// A 7 x 7 pixel speech bubble; its tail points down towards the creature's head (bottom right,
/// or bottom left when mirrored). Glyphs are never mirrored, only the tail.
struct MascotBubbleView: View {
    let bubble: MascotBubble
    var mirrored = false

    private static let shape = [
        ".xxxxx.",
        "xxxxxxx",
        "xxxxxxx",
        "xxxxxxx",
        "xxxxxxx",
        ".xxxxx.",
        ".....x.",
    ]

    var body: some View {
        let pixel = MascotCanvas.pixel
        let (fill, ink) = colors
        let glyph = glyphPixels
        let mirrored = mirrored

        Canvas { context, _ in
            func cell(_ x: Int, _ y: Int) -> Path {
                Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel))
            }
            if let fill {
                for (y, row) in Self.shape.enumerated() {
                    for (x, character) in row.enumerated() where character == "x" {
                        context.fill(cell(mirrored && y == 6 ? 6 - x : x, y), with: .color(fill))
                    }
                }
            }
            for (x, y) in glyph { context.fill(cell(x, y), with: .color(ink)) }
            // A highlight on the heart's left lobe.
            if bubble == .heart { context.fill(cell(1, 2), with: .color(.white.opacity(0.45))) }
        }
        .frame(width: 7 * pixel, height: 7 * pixel)
        .allowsHitTesting(false)
    }

    /// Fill (nil: a glyph without a bubble, for sleep) and glyph colour.
    private var colors: (Color?, Color) {
        let neutral = DesignSystem.Colors.textPrimary.opacity(0.85)
        let darkInk = Color.black.opacity(0.75)
        switch bubble {
        case .attention: return (Self.accentIsWarm ? Color(red: 1, green: 0.84, blue: 0.2) : DesignSystem.Colors.warning, darkInk)
        case .done: return (DesignSystem.Colors.success, darkInk)
        case .error: return (DesignSystem.Colors.error, .white)
        case .thinking, .question, .sound: return (neutral, DesignSystem.Colors.surface)
        case .sleep: return (nil, DesignSystem.Colors.textSecondary)
        case .heart: return (nil, Self.heartPink)
        }
    }

    /// Pink, not red: red above the creature means an error.
    private static let heartPink = Color(red: 0.95, green: 0.45, blue: 0.56)

    /// Red to orange bodies, where an orange bubble would melt into the creature.
    private static var accentIsWarm: Bool {
        guard let color = NSColor(CompanionAppearance.shared.bodyColor).usingColorSpace(.sRGB),
              color.saturationComponent > 0.3
        else { return false }
        return color.hueComponent < 0.12 || color.hueComponent > 0.95
    }

    private var glyphPixels: [(Int, Int)] {
        switch bubble {
        case .attention:
            return [(3, 1), (3, 2), (3, 3), (3, 5)]
        case .thinking(let dots):
            return [(1, 3), (3, 3), (5, 3)].prefix(max(0, min(3, dots))).map { $0 }
        case .done:
            return [(1, 3), (2, 4), (3, 3), (4, 2), (5, 1)]
        case .error:
            return [(2, 2), (4, 2), (3, 3), (2, 4), (4, 4)]
        case .question:
            // The 3 x 5 pixel font "?": hook, stem, gap, dot.
            return [(2, 1), (3, 1), (4, 1), (4, 2), (3, 3), (3, 5)]
        case .sound(let step):
            // Three bars standing on row 4, one to four pixels tall.
            return [1, 3, 5].enumerated().flatMap { index, x in
                let height = 1 + Int(AssistantMascotPose.noise(step * 3 + index) * 4)
                return (0..<height).map { (x, 4 - $0) }
            }
        case .sleep(let step):
            // A 4 x 4 "z" (3 x 3 reads as an "I") rising away from the creature's head.
            let step = max(0, min(3, step))
            let z = [(0, 0), (1, 0), (2, 0), (3, 0), (2, 1), (1, 2), (0, 3), (1, 3), (2, 3), (3, 3)]
            return z.map { (mirrored ? $0.0 + 3 - step : $0.0 + step, $0.1 + 3 - step) }
        case .heart:
            // A 5 x 5 heart, two lobes on top, pointing down.
            return [(1, 1), (2, 1), (4, 1), (5, 1)]
                + (1...5).flatMap { [($0, 2), ($0, 3)] }
                + [(2, 4), (3, 4), (4, 4), (3, 5)]
        }
    }
}

/// The pill's capture red: a recording runs. Pulses for the first minute, then holds still.
private struct RecordingBadge: View {
    let pixel: CGFloat
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let red = Color(red: 0.84, green: 0.19, blue: 0.16)

    var body: some View {
        ZStack {
            Circle()
                .fill(Self.red.opacity(0.35))
                .frame(width: 3 * pixel, height: 3 * pixel)
                .scaleEffect(pulse && !reduceMotion ? 1.9 : 1)
                .opacity(pulse && !reduceMotion ? 0 : 0.8)
                .animation(pulse && !reduceMotion ? .easeOut(duration: 1.6).repeatForever(autoreverses: false) : nil, value: pulse)
                .opacity(pulse ? 1 : 0)
            Circle()
                .fill(Self.red)
                .frame(width: 3 * pixel, height: 3 * pixel)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
        }
        .frame(width: 5 * pixel, height: 5 * pixel)
        .task {
            pulse = true
            try? await Task.sleep(for: .seconds(60))
            pulse = false
        }
    }
}

/// A detected meeting runs and is not recorded: the old pill's hollow ring.
private struct MeetingRingBadge: View {
    let pixel: CGFloat

    var body: some View {
        Circle()
            .strokeBorder(Color(white: 0.45), lineWidth: max(1.5, pixel * 0.7))
            .background(Circle().fill(Color.white.opacity(0.85)))
            .frame(width: 3.4 * pixel, height: 3.4 * pixel)
            .frame(width: 5 * pixel, height: 5 * pixel)
    }
}

/// The projects' small creatures huddled behind the companion (CompanionCast); each shows its
/// sessions in its pose (CompanionController picks the mood), standing in the slot
/// CompanionCrowd gave it, back row first so the front row overlaps it. Clicks are taken by the
/// controller's mouse view on top.
struct CompanionSidekickRow: View {
    let model: CompanionModel

    var body: some View {
        let pixel = CompanionPlacement.sidekickPixel
        let slots = model.crowdSlots
        let height = slots.reduce(CGRect.null) { $0.union($1) }.maxY
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(CompanionCrowd.drawOrder(count: min(slots.count, model.sidekicks.count)), id: \.self) { index in
                let sidekick = model.sidekicks[index]
                let slot = slots[index]
                MascotCanvas(frame: sidekick.frame, avatar: sidekick.avatar, pixelSize: pixel, bodyColor: sidekick.color)
                    .opacity(model.hoveredSidekick == nil || model.hoveredSidekick == sidekick.id ? 1 : 0.85)
                    // Slots are in AppKit coordinates (y up), the view's run down.
                    .offset(x: slot.minX, y: height - slot.maxY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.sidekicks.map { "\($0.name), \($0.spokenStatus)" }.joined(separator: "; "))
    }
}

/// The hovered sidekick's name and what it does, a small pixel card above its head.
struct CompanionNameplate: View {
    let sidekick: CompanionSidekick

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(sidekick.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Text("\(sidekick.spokenStatus.prefix(1).uppercased() + sidekick.spokenStatus.dropFirst()) \u{00B7} click to bring forward")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .modifier(PixelPanelBackground())
        .padding(4)
        .fixedSize()
    }
}

/// The mark of a starred project in the sidebar row and the project wheel: the project's own
/// creature, tiny and still (1 pt pixels) in the colour it has beside the companion
/// (CompanionCast), or without one a yellow star.
struct StarredProjectMark: View {
    /// nil: the project has no creature of its own.
    var avatar: MascotAvatar?
    var bodyColor: Color?

    var body: some View {
        Group {
            if let avatar {
                MascotCanvas(
                    frame: AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: nil, avatar: avatar, animated: false)),
                    avatar: avatar,
                    pixelSize: 1,
                    bodyColor: bodyColor)
            } else {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .frame(width: CGFloat(MascotGrid.width), height: CGFloat(MascotGrid.width))
            }
        }
        .help("Starred")
        .accessibilityLabel("Starred")
    }
}
