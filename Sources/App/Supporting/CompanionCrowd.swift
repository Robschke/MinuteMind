// Purpose: CompanionCrowd, how the projects' small creatures (sidekicks) stand behind the creature
//          in front: a two-row huddle on one side of it, squeezed together when a screen edge is
//          near, which of them a point falls on, and who glances at whom.
// Dependencies: none (pure, unit tested in Tests/CompanionCrowdTests.swift)
// Used by: Sources/App/Supporting/CompanionController.swift (layout, hit testing, glances),
//          Sources/App/Views/CompanionView.swift (CompanionSidekickRow draws the slots)
// Notes: All rectangles are AppKit screen coordinates (origin bottom left, y up). Decisions:
//        - A huddle, not a row: the front row stands on the big creature's ground line with a
//          2 pixel gap between neighbours, the nearest one tucked 2 pixels behind its shoulder;
//          the back row stands centred over the gaps, raised so its eyes clear the front row's
//          heads. Slots fill nearest first,
//          alternating front and back (front 0, back 1, front 2, back 3, front 4).
//        - The crowd stands on the side toward the nearer screen edge (docked: inside the
//          window, on the left), so it can be pushed out of the way; the controller picks
//          the side and hands in the room up to that edge.
//        - Short of room it squeezes: the steps shrink to half a body and the tuck grows to
//          half a body, so every creature keeps about half of itself in view. Only when even
//          the tightest huddle does not fit does the big creature step inward (`stepIn`), as
//          far as needed; it steps back out when the crowd shrinks.
//        - Glances never override a status pose: the controller only asks for one while a
//          sidekick idles. Neighbours look at each other in pairs, and the nearest one looks
//          up at the big creature now and then; everything is a function of time, so all
//          creatures agree without state.

import CoreGraphics
import Foundation

enum CompanionCrowd {
    /// The canvas grid every creature is drawn on (MascotGrid plus headroom): 12 x 16 pixels.
    static let canvasWidth: CGFloat = 12
    static let canvasHeight: CGFloat = 16

    struct Layout: Equatable {
        /// Each sidekick's canvas on screen, nearest first.
        var slots: [CGRect]
        /// How far the big creature moves away from the edge so the crowd fits (points, >= 0).
        var stepIn: CGFloat

        var frame: CGRect { slots.reduce(CGRect.null) { $0.union($1) } }
    }

    /// Slot `index` in sidekick pixels: `u` from the big creature's outer side outward to the
    /// slot's near side, `rise` above the ground line. `squeeze` 0 is the relaxed huddle, 1 the
    /// tightest.
    static func slot(_ index: Int, squeeze: CGFloat) -> (u: CGFloat, rise: CGFloat) {
        let q = min(1, max(0, squeeze))
        let tuck = 2 + 4 * q
        let step = canvasWidth + 2 - 8 * q
        let front = -tuck + step * CGFloat(index / 2)
        if index.isMultiple(of: 2) { return (front, 0) }
        return (front + step / 2, 5 + 2 * q)
    }

    /// How far the crowd reaches outward from the big creature's side, in points.
    static func extent(count: Int, squeeze: CGFloat, pixel: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return (slot(count - 1, squeeze: squeeze).u + canvasWidth) * pixel
    }

    /// The crowd of `count` sidekicks beside `creature`, on its right side (`outwardRight`) or
    /// its left, with `room` points from that side to the edge it must stay within.
    /// `allowsStepIn` false (docked, or while dragged) lets the crowd hang over instead.
    static func layout(
        count: Int, creature: CGRect, pixel: CGFloat, outwardRight: Bool, room: CGFloat, allowsStepIn: Bool
    ) -> Layout {
        guard count > 0 else { return Layout(slots: [], stepIn: 0) }
        let room = max(0, room)
        let relaxed = extent(count: count, squeeze: 0, pixel: pixel)
        let tight = extent(count: count, squeeze: 1, pixel: pixel)
        let squeeze: CGFloat
        if relaxed <= room {
            squeeze = 0
        } else if tight >= room {
            squeeze = 1
        } else {
            squeeze = (relaxed - room) / (relaxed - tight)
        }
        let stepIn = allowsStepIn ? max(0, tight - room).rounded(.up) : 0
        let width = canvasWidth * pixel
        let height = canvasHeight * pixel
        let side = outwardRight ? creature.maxX - stepIn : creature.minX + stepIn
        let slots = (0..<count).map { index -> CGRect in
            let (u, rise) = slot(index, squeeze: squeeze)
            let near = (u * pixel).rounded()
            let x = outwardRight ? side + near : side - near - width
            return CGRect(x: x, y: creature.minY + rise * pixel, width: width, height: height)
        }
        return Layout(slots: slots, stepIn: stepIn)
    }

    /// Back to front: the back row first, then the front row, each from the outside in, so the
    /// nearest of each row is drawn over its outer neighbour.
    static func drawOrder(count: Int) -> [Int] {
        let indices = Array(0..<max(0, count))
        let back = indices.filter { !$0.isMultiple(of: 2) }.reversed()
        let front = indices.filter { $0.isMultiple(of: 2) }.reversed()
        return Array(back) + Array(front)
    }

    /// The sidekick (index into `slots`) drawn on top at `point`, nil for none.
    static func index(at point: CGPoint, slots: [CGRect]) -> Int? {
        drawOrder(count: slots.count).reversed().first { slots[$0].contains(point) }
    }

    // MARK: Glances

    /// One beat of the crowd's chatter: every `beat` seconds something may happen, for
    /// `glanceLength` seconds starting `glanceStart` into the beat.
    static let beat: TimeInterval = 4.5
    static let glanceStart: TimeInterval = 1
    static let glanceLength: TimeInterval = 1.8

    /// Where sidekick `index` of `count` looks at `time` (each -1, 0 or 1; y -1 is up), nil
    /// when it is not part of a glance (it keeps its own idle glances then).
    static func glance(index: Int, count: Int, outwardRight: Bool, time: TimeInterval) -> (x: Int, y: Int)? {
        guard count > 0, (0..<count).contains(index) else { return nil }
        let beatIndex = Int((time / beat).rounded(.down))
        let phase = time - Double(beatIndex) * beat
        guard phase >= glanceStart, phase < glanceStart + glanceLength else { return nil }
        let roll = hash(beatIndex)
        // About a third of the beats stay quiet.
        guard roll % 100 >= 35 else { return nil }
        let outward = outwardRight ? 1 : -1
        // Event 0: the nearest looks up at the big creature; event k: pair (k - 1, k).
        let event = (roll / 100) % count
        if event == 0 {
            return index == 0 ? (-outward, -1) : nil
        }
        let inner = event - 1
        let outer = event
        // Back row (odd slots) stands higher: the front one looks up, the back one down.
        if index == inner { return (outward, inner.isMultiple(of: 2) ? -1 : 1) }
        if index == outer { return (-outward, outer.isMultiple(of: 2) ? -1 : 1) }
        return nil
    }

    /// A small integer hash (splitmix64 finaliser), stable across launches.
    private static func hash(_ value: Int) -> Int {
        var z = UInt64(bitPattern: Int64(value)) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int(z % 1_000_000)
    }
}
