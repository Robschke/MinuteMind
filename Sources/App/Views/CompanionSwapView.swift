// Purpose: CompanionSwapView, the short scene in which the desktop companion's creatures change
//          places when another one comes to the front: the new one runs and hops into the big
//          spot while it grows, the old one runs back into the row while it shrinks, the rest
//          of the row slides to its new slots.
// Dependencies: Sources/App/Supporting/AssistantMascotPose.swift (running frames),
//               Sources/App/Views/CompanionView.swift (MascotCanvas)
// Used by: Sources/App/Supporting/CompanionController.swift (its swap panel)
// Notes: User request: a click on a small creature should not just turn one into the other,
//        they should change positions. Decisions:
//        - All creatures are drawn here for the length of the swap, in one click-through panel
//          over the group, while the real creature and row are invisible: they live in separate
//          windows, which cannot be animated into each other.
//        - It reads as a jump (design review): sideways an ease-out, up and down a parabola, the
//          one coming forward hopping highest so the two in the middle never slide through
//          each other. The one leaving starts first and the one coming forward `delay` later,
//          so it makes room and the newcomer lands last.
//        - Pixel art never scales smoothly: each creature keeps its old pixel size until the top
//          of its hop and takes the new one there; positions snap to whole points, so no
//          hairlines open between the pixels.
//        - Movers run (AssistantMascotPose's running pose, facing where they go) and stand still
//          for the last stretch, so the hand-off to the real creatures does not pop; whoever
//          does not move holds still.
//        - Reduce Motion skips the scene (the controller swaps at once).

import SwiftUI

/// One creature's way during a swap, in screen points (origin bottom left).
struct CompanionSwapMover: Identifiable {
    let id: String
    let avatar: MascotAvatar
    /// nil: the home companion's colour from Settings.
    let color: Color?
    /// Bottom left corner of its canvas, and its pixel size, before and after.
    let from: CGPoint
    let to: CGPoint
    let fromPixel: CGFloat
    let toPixel: CGFloat
    /// Height of its hop at the middle of the way.
    let arc: CGFloat
    /// Seconds after the start before it sets off.
    var delay: TimeInterval = 0
}

struct CompanionSwap {
    let start: Date
    let duration: TimeInterval
    let movers: [CompanionSwapMover]
    /// The swap panel's frame on screen.
    let frame: CGRect
}

struct CompanionSwapView: View {
    let swap: CompanionSwap

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(swap.start)
            let longestDelay = swap.movers.map(\.delay).max() ?? 0
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(swap.movers) { mover in
                    let way = max(0.05, swap.duration - longestDelay)
                    let l = min(1, max(0, (elapsed - mover.delay) / way))
                    // Ease-out sideways, a parabola for the hop.
                    let t = 1 - (1 - l) * (1 - l)
                    let pixel = l < 0.5 ? mover.fromPixel : mover.toPixel
                    // The feet's centre travels, so the size change at the top grows around it.
                    let fromCentre = mover.from.x + 6 * mover.fromPixel
                    let toCentre = mover.to.x + 6 * mover.toPixel
                    let x = (fromCentre + (toCentre - fromCentre) * t - 6 * pixel).rounded()
                    let y = (mover.from.y + (mover.to.y - mover.from.y) * t + mover.arc * 4 * l * (1 - l)).rounded()
                    let moving = abs(mover.to.x - mover.from.x) > 0.5 && l > 0 && l < 0.88
                    let height = 16 * pixel
                    MascotCanvas(
                        frame: AssistantMascotPose.frame(.init(
                            mood: .idle, time: context.date.timeIntervalSinceReferenceDate, look: nil,
                            avatar: mover.avatar, animated: true,
                            running: moving ? (mover.to.x >= mover.from.x ? 1 : -1) : nil)),
                        avatar: mover.avatar, pixelSize: pixel, bodyColor: mover.color)
                        // Screen y runs up, the panel's view down.
                        .offset(x: x - swap.frame.minX, y: swap.frame.maxY - y - height)
                }
            }
            .frame(width: swap.frame.width, height: swap.frame.height, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }
}
