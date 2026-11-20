// Purpose: SVGCreatureCanvas, the svg renderer's drawing: the shadow, the avatar's drawing (from
//          SVGAvatarImageCache) moved by the frame (hop, breathing, shake, lean, facing) and the
//          app's props at the avatar's anchors.
// Dependencies: Sources/App/Supporting/SVGCreatureRenderer.swift (SVGCreatureFrame),
//               Sources/App/Supporting/SVGAvatarImageCache.swift, Sources/App/Supporting/SVGAvatarArt.swift
//               (anchors), Sources/App/Supporting/CompanionAppearance.swift (body colour),
//               Sources/App/Components/DesignSystem.swift (prop colour)
// Used by: Sources/App/Views/CreatureView.swift (the only place a frame is drawn)
// Notes: - Same canvas as the pixel creatures: 12 x 16 units, two units of headroom for hops, the
//          body's 12 x 13 units, one unit of ground with the shadow; `unit` points per unit.
//        - The props are plain rounded shapes in the body colour and the theme's text colour, so
//          they sit with any style; an avatar that wants them in its own style draws the mood
//          itself (SVGAvatarArt.moods).

import SwiftUI

struct SVGCreatureCanvas: View {
    let frame: SVGCreatureFrame
    let avatar: MascotAvatar
    let unit: CGFloat
    var bodyColor: Color?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.self) private var environment

    private static let headroom: CGFloat = 2

    private static func byte(_ channel: Float) -> UInt32 {
        UInt32((Double(channel) * 255).rounded().clamped(0, 255))
    }

    var body: some View {
        let accent = bodyColor ?? CompanionAppearance.shared.bodyColor(for: avatar)
        let resolved = accent.resolve(in: environment)
        let hex = (Self.byte(resolved.red) << 16) | (Self.byte(resolved.green) << 8) | Self.byte(resolved.blue)
        let gear = DesignSystem.Colors.textPrimary.opacity(0.8)
        let shadow = colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.14)
        let image = avatar.art.flatMap {
            SVGAvatarImageCache.shared.image(
                art: $0, drawing: frame.drawing, color: hex,
                pixelWidth: Int((CreatureCanvas.unitsWide * unit * displayScale).rounded()))
        }
        let anchors = avatar.art?.anchors

        Canvas { context, size in
            let groundY = (Self.headroom + 13) * unit
            let shadowWidth = (8 - CGFloat(frame.lift) * 2) * unit
            context.fill(
                Path(ellipseIn: CGRect(x: (size.width - shadowWidth) / 2, y: groundY - unit * 0.4,
                                       width: shadowWidth, height: unit * 1.2)),
                with: .color(shadow))

            // Feet stay on the ground: squash, lean and facing turn around them.
            var layer = context
            let feet = CGPoint(x: size.width / 2, y: groundY)
            layer.translateBy(x: feet.x + CGFloat(frame.shake) * unit, y: feet.y - CGFloat(frame.lift) * unit)
            if frame.mirrored { layer.scaleBy(x: -1, y: 1) }
            if frame.lean != 0 { layer.rotate(by: .degrees(frame.lean)) }
            if frame.squashed { layer.scaleBy(x: 1.03, y: 0.95) }
            layer.translateBy(x: -feet.x, y: -feet.y)

            let bodyRect = CGRect(x: 0, y: Self.headroom * unit, width: 12 * unit, height: 13 * unit)
            if let image {
                layer.draw(Image(decorative: image, scale: 1), in: bodyRect)
            }
            guard let anchors else { return }
            func point(_ p: SVGAvatarArt.Point, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPoint {
                CGPoint(x: CGFloat(p.x) / 10 * unit + dx * unit, y: (CGFloat(p.y) / 10 + Self.headroom) * unit + dy * unit)
            }
            func dot(_ center: CGPoint, _ radius: CGFloat, _ color: Color) {
                layer.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(color))
            }
            func hand(_ center: CGPoint) {
                dot(center, 0.75 * unit, accent)
                layer.stroke(Path(ellipseIn: CGRect(x: center.x - 0.75 * unit, y: center.y - 0.75 * unit, width: 1.5 * unit, height: 1.5 * unit)),
                             with: .color(.black.opacity(0.45)), lineWidth: max(1, 0.18 * unit))
            }
            let right = anchors.hands.count > 1 ? anchors.hands[1] : anchors.top
            let left = anchors.hands.first ?? anchors.top

            for prop in frame.props {
                switch prop {
                case .closedEyes, .happyEyes, .crossedEyes:
                    // The open eye is covered in the body colour and a line drawn over it.
                    let radius = CGFloat(anchors.eyeSize) / 10 * unit
                    let ink = StrokeStyle(lineWidth: max(1, 0.28 * unit), lineCap: .round)
                    for eye in anchors.eyes {
                        let c = point(eye)
                        dot(c, radius * 1.15, accent)
                        var line = Path()
                        switch prop {
                        case .happyEyes:
                            line.move(to: CGPoint(x: c.x - radius, y: c.y + radius * 0.3))
                            line.addQuadCurve(to: CGPoint(x: c.x + radius, y: c.y + radius * 0.3), control: CGPoint(x: c.x, y: c.y - radius * 1.1))
                        case .crossedEyes:
                            let r = radius * 0.75
                            line.move(to: CGPoint(x: c.x - r, y: c.y - r)); line.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
                            line.move(to: CGPoint(x: c.x + r, y: c.y - r)); line.addLine(to: CGPoint(x: c.x - r, y: c.y + r))
                        default:
                            line.move(to: CGPoint(x: c.x - radius, y: c.y))
                            line.addQuadCurve(to: CGPoint(x: c.x + radius, y: c.y), control: CGPoint(x: c.x, y: c.y + radius * 0.8))
                        }
                        layer.stroke(line, with: .color(.black.opacity(0.85)), style: ink)
                    }
                case .laptop(let tapLeft):
                    let l = point(left), r = point(right)
                    let midX = (l.x + r.x) / 2
                    let top = max(l.y, r.y) - 1.2 * unit
                    let screen = CGRect(x: midX - 3.2 * unit, y: top, width: 6.4 * unit, height: 3.6 * unit)
                    layer.fill(Path(roundedRect: screen, cornerRadius: 0.4 * unit), with: .color(Color(white: 0.62)))
                    dot(CGPoint(x: screen.midX, y: screen.midY), 0.35 * unit, .white)
                    hand(CGPoint(x: screen.minX + 0.6 * unit, y: screen.maxY - (tapLeft ? 0.6 : 0.2) * unit))
                    hand(CGPoint(x: screen.maxX - 0.6 * unit, y: screen.maxY - (tapLeft ? 0.2 : 0.6) * unit))
                case .wave(let high):
                    let base = point(right)
                    let tip = point(right, dx: 1.0, dy: high ? -3.0 : -2.0)
                    var arm = Path()
                    arm.move(to: base)
                    arm.addLine(to: tip)
                    layer.stroke(arm, with: .color(accent), style: StrokeStyle(lineWidth: 0.9 * unit, lineCap: .round))
                    hand(tip)
                case .armsUp(let high):
                    for (anchor, side) in [(left, -1.0), (right, 1.0)] {
                        let base = point(anchor)
                        let tip = point(anchor, dx: side * 0.8, dy: high ? -3.2 : -2.4)
                        var arm = Path()
                        arm.move(to: base)
                        arm.addLine(to: tip)
                        layer.stroke(arm, with: .color(accent), style: StrokeStyle(lineWidth: 0.9 * unit, lineCap: .round))
                        hand(tip)
                    }
                case .thumbUp:
                    let fist = point(right, dx: 0.6, dy: -1.8)
                    let thumb = CGRect(x: fist.x - 0.45 * unit, y: fist.y - 2.6 * unit, width: 0.9 * unit, height: 2.2 * unit)
                    layer.fill(Path(roundedRect: thumb, cornerRadius: 0.45 * unit), with: .color(accent))
                    layer.stroke(Path(roundedRect: thumb, cornerRadius: 0.45 * unit), with: .color(.black.opacity(0.45)), lineWidth: max(1, 0.18 * unit))
                    dot(fist, 1.05 * unit, accent)
                    layer.stroke(Path(ellipseIn: CGRect(x: fist.x - 1.05 * unit, y: fist.y - 1.05 * unit, width: 2.1 * unit, height: 2.1 * unit)),
                                 with: .color(.black.opacity(0.45)), lineWidth: max(1, 0.18 * unit))
                case .headphones:
                    let top = point(anchors.top)
                    let halfWidth = 4.6 * unit
                    var band = Path()
                    band.addArc(center: CGPoint(x: top.x, y: top.y + 2.6 * unit), radius: halfWidth,
                                startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                    layer.stroke(band, with: .color(gear), style: StrokeStyle(lineWidth: 0.6 * unit, lineCap: .round))
                    for side in [-1.0, 1.0] {
                        let cup = CGRect(x: top.x + side * halfWidth - 0.7 * unit, y: top.y + 2.4 * unit, width: 1.4 * unit, height: 2.4 * unit)
                        layer.fill(Path(roundedRect: cup, cornerRadius: 0.5 * unit), with: .color(gear))
                    }
                }
            }
        }
        .frame(width: CreatureCanvas.unitsWide * unit, height: (Self.headroom + 13 + 1) * unit)
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}
