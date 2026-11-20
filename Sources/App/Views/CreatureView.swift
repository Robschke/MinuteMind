// Purpose: CreatureView, the one view that draws a creature: it takes a frame (or a pose to
//          sample one from), the avatar, a size and a body colour, and hands them to the renderer
//          of the frame's kind. The pixel renderer's canvas lives here too.
// Dependencies: Sources/App/Supporting/CreatureRenderer.swift (CreaturePose, CreatureFrame),
//               Sources/App/Supporting/AssistantMascotPose.swift (MascotFrame, inks),
//               Sources/App/Views/SVGCreatureCanvas.swift (the svg renderer's drawing),
//               Sources/App/Supporting/CompanionAppearance.swift (the home companion's avatar,
//               size and colour), Sources/App/Components/DesignSystem.swift (theme colours)
// Used by: Sources/App/Views/CompanionView.swift (the desktop companion, its sidekicks, the
//          starred mark), Sources/App/Views/CompanionSwapView.swift, Sources/App/Views/
//          CompanionChatCard.swift, Sources/App/Components/ProjectAvatarView.swift,
//          Sources/App/Components/AgentStatusCreatureView.swift, Sources/App/Views/
//          AppearanceSettingsView.swift, Sources/App/Views/OnboardingView.swift
// Notes: - Views never draw a frame themselves: the canvas is private, so a new kind of avatar
//          is one more case here and nowhere else.
//        - The size is given as `unit`, points per canvas unit (CreatureCanvas: 12 x 16 units).
//          Whole points keep pixel art crisp, since a pixel avatar's pixel is one unit.
//        - Colours of the pixel canvas: the body takes the body colour (the theme's accent for the
//          Blob), the outline is the body with 55% black, the shine the body with 55% white, eyes
//          a fixed near-black, the feature ink the avatar's own colour. A body colour passed in
//          tints the body only.

import SwiftUI

/// Draws one creature at one moment.
struct CreatureView: View {
    let frame: CreatureFrame
    /// Whose colours to draw in; nil: the home companion's avatar from Settings.
    var avatar: MascotAvatar?
    /// Points per canvas unit; nil: the companion's size from Settings.
    var unit: CGFloat?
    /// A body colour instead of the avatar's (a project's creature in its avatar colour).
    var bodyColor: Color?

    init(frame: CreatureFrame, avatar: MascotAvatar? = nil, unit: CGFloat? = nil, bodyColor: Color? = nil) {
        self.frame = frame
        self.avatar = avatar
        self.unit = unit
        self.bodyColor = bodyColor
    }

    /// The pose's avatar at the moment the pose describes.
    init(pose: CreaturePose, unit: CGFloat? = nil, bodyColor: Color? = nil) {
        self.init(frame: CreatureRenderer.frame(pose), avatar: pose.avatar, unit: unit, bodyColor: bodyColor)
    }

    /// Points per canvas unit of the desktop companion (Settings, Appearance: 2, 3 or 4).
    static var unit: CGFloat { CompanionAppearance.shared.pixel }

    var body: some View {
        switch frame {
        case .pixel(let frame):
            MascotCanvas(frame: frame, avatar: avatar, pixelSize: unit, bodyColor: bodyColor)
        case .svg(let frame):
            SVGCreatureCanvas(
                frame: frame, avatar: avatar ?? CompanionAppearance.shared.avatar,
                unit: unit ?? CreatureView.unit, bodyColor: bodyColor)
        }
    }
}

/// The pixel renderer's drawing: one frame, shadow and creature.
private struct MascotCanvas: View {
    let frame: MascotFrame
    var avatar: MascotAvatar?
    /// Side of one pixel in points.
    var pixelSize: CGFloat?
    var bodyColor: Color?
    @Environment(\.colorScheme) private var colorScheme

    /// Empty rows above the creature, room for a two pixel hop.
    private static let headroom = 2

    var body: some View {
        let avatar = avatar ?? CompanionAppearance.shared.avatar
        let accent = bodyColor ?? CompanionAppearance.shared.bodyColor(for: avatar)
        let feature = Color(nsColor: ThemeColor.srgb(avatar.featureColor))
        let gear = DesignSystem.Colors.textPrimary.opacity(0.8)
        let shadow = colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.14)
        let pixel = pixelSize ?? CreatureView.unit
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
