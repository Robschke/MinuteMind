// Purpose: CompanionPlacement, the geometry of the desktop companion: where it starts, how it stays
//          on screen, how its position is remembered per display, which side its popups and speech
//          bubble go to, and where summoned Claude windows are fanned out next to it.
// Dependencies: Sources/App/Supporting/CompanionAppearance.swift (pixel size; otherwise pure, unit
//               tested in Tests/CompanionPlacementTests.swift)
// Used by: Sources/App/Supporting/CompanionController.swift (the creature's panel),
//          Sources/App/Supporting/MeetingPillController.swift (popups beside the creature),
//          Sources/App/ViewModels/AppViewModel+Companion.swift (summoned windows)
// Notes: All rectangles are AppKit screen coordinates (origin bottom left, y up).
//        - Starts on the right edge of the first display, in the lower third (design review: the
//          bottom right corner is where Send buttons, scroll bars and resize corners sit).
//        - A drop within 12 pt of a screen edge snaps to it.
//        - Shaking the mouse brings it beside the pointer (`originNear`), never on top of it.
//        - Docked (user request 2026-10-13) it sits in the main window's bottom right corner
//          (`dockedOrigin`); dropped within 48 pt of that spot it docks again.
//        - The position is stored relative to the display's visible frame (0...1 per axis), so it
//          survives resolution and Dock changes; a display that is gone falls back to the main one.
//        - Popups and the bubble go to the side with more room, so near the right edge they open
//          to the left. Popups centre on the creature vertically and never leave the screen.
//        - Every size scales with the creature's pixel size (CompanionAppearance: 2, 3 or 4 pt).

import CoreGraphics

@MainActor
enum CompanionPlacement {
    static var pixel: CGFloat { CompanionAppearance.shared.pixel }
    /// The creature's canvas: 12 x 16 pixels (two rows of hop headroom, one of shadow).
    static var creatureSize: CGSize { CGSize(width: 12 * pixel, height: 16 * pixel) }
    /// Room around the canvas for the speech bubble (left or right) and above it.
    static var sideMargin: CGFloat { 6 * pixel }
    static var topMargin: CGFloat { 4 * pixel }
    static var panelSize: CGSize {
        CGSize(width: creatureSize.width + 2 * sideMargin, height: creatureSize.height + topMargin)
    }
    /// Space between the creature and a popup or a summoned window.
    static let gap: CGFloat = 6

    /// The creature's canvas inside a panel at `origin`.
    static func creatureRect(panelOrigin origin: CGPoint) -> CGRect {
        CGRect(origin: CGPoint(x: origin.x + sideMargin, y: origin.y), size: creatureSize)
    }

    /// Where the panel goes on first launch: the right edge, a quarter of the way up.
    static func defaultOrigin(in visible: CGRect) -> CGPoint {
        CGPoint(x: visible.maxX - sideMargin - creatureSize.width - 12, y: visible.minY + visible.height * 0.25)
    }

    /// A creature dropped within `snapDistance` of an edge moves onto it.
    static let snapDistance: CGFloat = 12

    static func snapped(_ origin: CGPoint, in visible: CGRect) -> CGPoint {
        var origin = clamped(origin, in: visible)
        let creature = creatureRect(panelOrigin: origin)
        if creature.minX - visible.minX < snapDistance { origin.x = visible.minX - sideMargin }
        if visible.maxX - creature.maxX < snapDistance { origin.x = visible.maxX - sideMargin - creatureSize.width }
        if creature.minY - visible.minY < snapDistance { origin.y = visible.minY }
        if visible.maxY - (origin.y + panelSize.height) < snapDistance { origin.y = visible.maxY - panelSize.height }
        return origin
    }

    /// Keeps the creature itself on screen (its bubble margins may hang over the edge).
    static func clamped(_ origin: CGPoint, in visible: CGRect) -> CGPoint {
        let minX = visible.minX - sideMargin
        let maxX = visible.maxX - sideMargin - creatureSize.width
        let maxY = visible.maxY - panelSize.height
        return CGPoint(x: min(max(origin.x, minX), maxX), y: min(max(origin.y, visible.minY), maxY))
    }

    /// Docked: the panel origin that puts the creature in the main window's bottom right corner,
    /// 14 pt from the right edge and 12 pt up, where the old assistant button sat.
    static func dockedOrigin(in windowFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.maxX - 14 - creatureSize.width - sideMargin, y: windowFrame.minY + 12)
    }

    /// A creature dropped this close to its docked spot docks again.
    static func isNearDock(_ origin: CGPoint, windowFrame: CGRect) -> Bool {
        let dock = dockedOrigin(in: windowFrame)
        return hypot(origin.x - dock.x, origin.y - dock.y) < 48
    }

    /// Where the creature lands when the mouse is shaken: just below and right of the pointer
    /// tip so it never covers the pointer; left of it near the right edge, above it near the
    /// bottom; always on the pointer's screen.
    static func originNear(pointer: CGPoint, in visible: CGRect) -> CGPoint {
        let size = creatureSize
        var minX = pointer.x + 14
        if minX + size.width > visible.maxX { minX = pointer.x - 14 - size.width }
        var minY = pointer.y - 8 - size.height
        if minY < visible.minY { minY = pointer.y + 10 }
        return clamped(CGPoint(x: minX - sideMargin, y: minY), in: visible)
    }

    /// The panel origin as fractions of the room it can move in.
    static func relative(_ origin: CGPoint, in visible: CGRect) -> CGPoint {
        let clamped = clamped(origin, in: visible)
        let roomX = visible.width - creatureSize.width
        let roomY = visible.height - panelSize.height
        return CGPoint(
            x: roomX > 0 ? (clamped.x + sideMargin - visible.minX) / roomX : 0,
            y: roomY > 0 ? (clamped.y - visible.minY) / roomY : 0
        )
    }

    static func absolute(_ relative: CGPoint, in visible: CGRect) -> CGPoint {
        let x = visible.minX + relative.x * (visible.width - creatureSize.width) - sideMargin
        let y = visible.minY + relative.y * (visible.height - panelSize.height)
        return clamped(CGPoint(x: x, y: y), in: visible)
    }

    /// Popups and the bubble open to the left when the creature sits in the right half.
    static func opensLeft(creature: CGRect, in visible: CGRect) -> Bool {
        creature.midX > visible.midX
    }

    /// The popup panel's origin beside the creature. `insets` is the transparent margin the popup
    /// content has inside its panel (for its shadow); the visible content sits `gap` away from the
    /// creature and centres on it vertically.
    static func popupOrigin(
        creature: CGRect, popupSize: CGSize,
        insets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat),
        in visible: CGRect
    ) -> CGPoint {
        let left = opensLeft(creature: creature, in: visible)
        let x = left
            ? creature.minX - gap - (popupSize.width - insets.trailing)
            : creature.maxX + gap - insets.leading
        let contentHeight = popupSize.height - insets.top - insets.bottom
        var y = creature.midY - contentHeight / 2 - insets.bottom
        // The visible content stays inside the screen; the shadow margin may hang over.
        y = min(max(y, visible.minY - insets.bottom), visible.maxY - popupSize.height + insets.top)
        let clampedX = min(max(x, visible.minX - insets.leading), visible.maxX - popupSize.width + insets.trailing)
        return CGPoint(x: clampedX, y: y)
    }

    // MARK: Sidekicks

    /// The projects' small creatures (CompanionCast): whole points, so they stay crisp on every
    /// display; about two thirds of the companion at 3 pt, half at 4 pt, 1 pt beside a 2 pt one.
    /// How they stand together is CompanionCrowd's.
    static var sidekickPixel: CGFloat { pixel <= 2 ? 1 : 2 }
    /// One sidekick's canvas (same 12 x 16 pixel grid as the companion's).
    static var sidekickSize: CGSize { CGSize(width: 12 * sidekickPixel, height: 16 * sidekickPixel) }

    /// Frames for windows summoned to the creature: each keeps its size (shrunk to fit the
    /// screen), the first sits beside the creature on the roomy side, the rest step 28 pt away.
    static func fannedFrames(for sizes: [CGSize], creature: CGRect, in visible: CGRect) -> [CGRect] {
        let left = opensLeft(creature: creature, in: visible)
        let step: CGFloat = 28
        return sizes.enumerated().map { index, size in
            let width = min(size.width, visible.width * 0.9)
            let height = min(size.height, visible.height * 0.9)
            let offset = CGFloat(index) * step
            var x = left ? creature.minX - gap - width - offset : creature.maxX + gap + offset
            var y = creature.midY - height / 2 - offset
            x = min(max(x, visible.minX), visible.maxX - width)
            y = min(max(y, visible.minY), visible.maxY - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
}
