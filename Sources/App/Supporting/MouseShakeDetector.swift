// Purpose: MouseShakeDetector, recognises a quick side-to-side shake of the mouse (the gesture
//          macOS answers by enlarging the pointer), so the desktop companion can come to it.
// Dependencies: CoreGraphics only (pure, unit tested in Tests/MouseShakeDetectorTests.swift)
// Used by: Sources/App/Supporting/CompanionController.swift (fed from mouse-moved monitors)
// Notes: User request 2026-10-13: shake the mouse like for Apple's big pointer and the avatar
//        moves there. Decisions:
//        - Horizontal strokes only, the way people shake a pointer. A stroke counts when it covers
//          50 to 600 pt in at most 0.25 s before the direction flips; three counted flips within
//          0.9 s make a shake, about when macOS enlarges the pointer (design review: four flips
//          fired after it, and untimed strokes let timeline scrubbing and map panning through).
//          Long sweeps, slow panning, small jitter and drags (no mouse-moved events while a
//          button is held) stay below that.
//        - 1.5 s cooldown after a shake, so one long shake moves the creature once.
//        - Moves under 1 pt are ignored for the direction, so sensor noise cannot fake a flip.
//        - Strength 1 (gentle) to 5 (hard), set with the sensitivity slider in Settings,
//          Appearance. Harder needs more flips and wider strokes; the window grows with the
//          flips so a hard shake stays doable. 3 is the tuning above. Stroke duration and the
//          600 pt cap stay fixed at every level, so scrubbing and sweeps never count.

import CoreGraphics
import Foundation

struct MouseShakeDetector {
    static let strengths = 1...5
    static let defaultStrength = 3

    let strength: Int
    var minStroke: CGFloat
    var maxStroke: CGFloat = 600
    var maxStrokeDuration: TimeInterval = 0.25
    var reversalsNeeded: Int
    var window: TimeInterval
    var cooldown: TimeInterval = 1.5

    private var lastX: CGFloat?
    /// -1 left, 1 right, 0 before the first real move.
    private var direction = 0
    private var strokeStart: CGFloat = 0
    private var strokeStartTime: TimeInterval = 0
    private var reversals: [TimeInterval] = []
    private var lastShake: TimeInterval = -.infinity

    /// `strength` from 1 (gentle: two short flips) to 5 (hard: five wide flips); out of range
    /// values are clamped.
    init(strength: Int = MouseShakeDetector.defaultStrength) {
        let level = min(max(strength, Self.strengths.lowerBound), Self.strengths.upperBound)
        self.strength = level
        let index = level - Self.strengths.lowerBound
        reversalsNeeded = [2, 2, 3, 4, 5][index]
        minStroke = [30, 40, 50, 70, 90][index]
        window = [0.9, 0.9, 0.9, 1.2, 1.5][index]
    }

    /// Forgets the movement so far (the pointer was not watched for a while).
    mutating func reset() {
        lastX = nil
        direction = 0
        reversals.removeAll()
    }

    /// Feeds one pointer position; true when it completes a shake.
    mutating func add(x: CGFloat, at time: TimeInterval) -> Bool {
        defer { lastX = x }
        guard let lastX else {
            strokeStart = x
            strokeStartTime = time
            return false
        }
        let dx = x - lastX
        guard abs(dx) >= 1 else { return false }
        let newDirection = dx > 0 ? 1 : -1
        if direction == 0 {
            direction = newDirection
            strokeStart = lastX
            strokeStartTime = time
            return false
        }
        if newDirection != direction {
            let length = abs(lastX - strokeStart)
            if length >= minStroke, length <= maxStroke, time - strokeStartTime <= maxStrokeDuration {
                reversals.append(time)
            }
            direction = newDirection
            strokeStart = lastX
            strokeStartTime = time
        }
        reversals.removeAll { time - $0 > window }
        guard reversals.count >= reversalsNeeded, time - lastShake > cooldown else { return false }
        lastShake = time
        reversals.removeAll()
        return true
    }
}
