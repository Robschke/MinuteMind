// Purpose: The one way to turn an avatar and a mood into something to draw. CreaturePose says what
//          a creature does at one moment, CreatureRenderer picks the renderer by the avatar's
//          kind and returns a CreatureFrame, which CreatureView draws.
// Dependencies: Sources/App/Supporting/MascotAvatar.swift (the avatar and its kind),
//               Sources/App/Supporting/AssistantMascotPose.swift (the pixel renderer: moods,
//               bubbles, MascotFrame)
// Used by: Sources/App/Views/CreatureView.swift (draws a frame), Sources/App/Supporting/
//          CompanionController.swift (samples the companion's and the sidekicks' frames), and
//          every view that shows a creature through CreatureView
// Notes: - Nothing outside the pixel renderer (AssistantMascotPose, the canvas in CreatureView)
//          reads a MascotFrame or a MascotGrid: callers hold a CreatureFrame and ask it for what
//          they lay out around the creature (the bubble and how far it bounces).
//        - A pose is renderer independent: mood, time, where the eyes point, what the creature
//          wears. Every kind of avatar has to show all of it.
//        - Every creature is drawn on a canvas of 12 x 16 units whatever its kind (CreatureCanvas),
//          and sizes are given in points per unit, so layouts never depend on how it is drawn.
//          For a pixel avatar a unit is one pixel.

import CoreGraphics
import Foundation

/// What a creature does at one moment.
struct CreaturePose {
    var mood: MascotMood
    /// Seconds on any steady clock; only differences and time slots matter.
    var time: TimeInterval
    /// Where the eyes point (each -1, 0 or 1; y -1 is up), nil when nobody moves the mouse.
    var look: (x: Int, y: Int)?
    var hovering = false
    /// Seconds since a hop started (a click, a finished Claude turn), nil without one.
    var hopAge: TimeInterval?
    /// Seconds since the mood began: talking, waiting and celebrating depend on it.
    var moodAge: TimeInterval = 0
    /// A recording runs: headphones over any mood.
    var headphones = false
    var avatar: MascotAvatar = .blob
    var animated = true
    /// Running to the pointer after a mouse shake: -1 left, 1 right, nil when not running.
    var running: Int?
    /// Waiting waves until answered instead of calming down after
    /// `AssistantMascotPose.waitingExcitement` (the small companions, whose pose is their only sign).
    var keepsWaving = false
}

/// One moment of a creature, ready to draw; which case it is follows from the avatar's kind.
enum CreatureFrame: Equatable, Sendable {
    case pixel(MascotFrame)

    /// The Blob's bare body, shown until the first pose is sampled.
    static let resting = CreatureFrame.pixel(MascotFrame(grid: .body))

    /// The speech bubble that goes with the frame.
    var bubble: MascotBubble? {
        switch self {
        case .pixel(let frame): frame.bubble
        }
    }

    /// Units the bubble bounces up.
    var bubbleLift: Int {
        switch self {
        case .pixel(let frame): frame.bubbleLift
        }
    }
}

enum CreatureRenderer {
    static func frame(_ pose: CreaturePose) -> CreatureFrame {
        switch pose.avatar.kind {
        case .pixel: .pixel(AssistantMascotPose.frame(pose))
        }
    }
}

/// The canvas every creature is drawn on: 12 units wide, 16 high (room for a hop above the
/// creature, its shadow below).
enum CreatureCanvas {
    static let unitsWide: CGFloat = 12
    static let unitsHigh: CGFloat = 16

    static func size(unit: CGFloat) -> CGSize {
        CGSize(width: unitsWide * unit, height: unitsHigh * unit)
    }
}
