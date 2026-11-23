// Purpose: SVGCreatureRenderer, the renderer for avatars of kind "svg": turns a pose into an
//          SVGCreatureFrame, which drawing to show (the body or one of the avatar's own mood
//          frames), how it moves (hop, breathing, shake, lean) and which of the app's props to put
//          at its anchors (closed, happy or crossed eyes, laptop, waving hand, raised arms, thumb
//          up, headphones).
// Dependencies: Sources/App/Supporting/CreatureRenderer.swift (CreaturePose),
//               Sources/App/Supporting/AssistantMascotPose.swift (the pixel renderer: timing,
//               hops and bubbles are taken from it), Sources/App/Supporting/SVGAvatarArt.swift
// Used by: Sources/App/Supporting/CreatureRenderer.swift, Sources/App/Views/SVGCreatureCanvas.swift,
//          Tests/SVGCreatureRendererTests.swift
// Notes: - Bubbles, hops, waiting bounces and the blink rhythm come from the pixel renderer run on
//          the same pose, so creatures of both kinds behave alike side by side; only the look
//          differs.
//        - A mood the avatar draws itself shows its frames (at its own fps) instead of the
//          props; a mood it does not draw shows the body with the props, which is how an avatar
//          with only a body still does everything. "blink" replaces the closed-eye prop,
//          "recording" the headphones, "running" the lean.

import Foundation

/// One moment of an svg avatar, ready to draw.
struct SVGCreatureFrame: Equatable, Sendable {
    enum Drawing: Equatable, Hashable, Sendable {
        case body
        /// Frame `index` of the avatar's own drawings for a mood.
        case mood(String, Int)
    }

    /// Shapes the app draws over the drawing, at the avatar's anchors.
    enum Prop: Equatable, Sendable {
        case closedEyes
        /// "^ ^", as the pixel creatures look when happy.
        case happyEyes
        /// "x x", as the pixel creatures look on an error.
        case crossedEyes
        case laptop(tapLeft: Bool)
        case wave(high: Bool)
        case armsUp(high: Bool)
        case thumbUp
        case headphones
    }

    var drawing: Drawing = .body
    var props: [Prop] = []
    /// Canvas units off the ground (hops, bounces, running steps).
    var lift = 0
    /// Breathing out or landing: a little shorter, feet on the ground.
    var squashed = false
    /// Canvas units sideways (the error shake).
    var shake: Double = 0
    /// Degrees forward (the dash to the pointer without own running frames).
    var lean: Double = 0
    /// Facing left (running left).
    var mirrored = false
    var bubble: MascotBubble?
    var bubbleLift = 0
}

enum SVGCreatureRenderer {
    static func frame(_ pose: CreaturePose, art: SVGAvatarArt) -> SVGCreatureFrame {
        // Timing, hops and bubbles as the pixel creatures have them.
        var reference = pose
        reference.avatar = .blob
        let pixel = AssistantMascotPose.frame(reference)
        var frame = SVGCreatureFrame(lift: pixel.lift, bubble: pixel.bubble, bubbleLift: pixel.bubbleLift)
        let t = pose.time
        let animated = pose.animated

        func own(_ name: String) -> SVGCreatureFrame.Drawing? {
            guard let mood = art.moods[name], !mood.frames.isEmpty else { return nil }
            let index = animated ? Int((t * mood.fps).rounded(.down)) % mood.frames.count : 0
            return .mood(name, max(0, index))
        }

        if animated, let direction = pose.running {
            frame.mirrored = direction < 0
            if let drawing = own("running") { frame.drawing = drawing } else { frame.lean = 8 }
            addHeadphones(&frame, pose: pose, own: own)
            return frame
        }

        // Breathing as the pixel creatures do; a recording keeps still.
        if animated, !pose.headphones {
            switch pose.mood {
            case .idle, .celebrating: frame.squashed = cycle(t, 4.5) > 4
            case .sleeping: frame.squashed = cycle(t, 4.5) > 3.3
            default: break
            }
        }
        if animated, let age = pose.hopAge, age >= 0, age < AssistantMascotPose.hopDuration,
           age < 0.125 || age >= 0.625 {
            frame.squashed = true
        }

        let wave = animated && Int(t * 4).isMultiple(of: 2)
        switch pose.mood {
        case .idle:
            if let drawing = own("idle") { frame.drawing = drawing }
            if animated, AssistantMascotPose.isBlinking(t), !pose.hovering {
                if let drawing = own("blink") { frame.drawing = drawing } else { frame.props.append(.closedEyes) }
            }
            if pose.hovering { frame.props.append(.wave(high: wave)) }
        case .sleeping:
            if let drawing = own("sleeping") { frame.drawing = drawing } else { frame.props.append(.closedEyes) }
        case .working:
            if let drawing = own("working") {
                frame.drawing = drawing
            } else {
                frame.props.append(.laptop(tapLeft: animated && Int(t * 4).isMultiple(of: 2)))
            }
        case .waiting:
            if let drawing = own("waiting") {
                frame.drawing = drawing
            } else {
                let excited = pose.keepsWaving || pose.moodAge < AssistantMascotPose.waitingExcitement
                frame.props.append(.wave(high: excited ? wave : true))
            }
        case .asking:
            if let drawing = own("asking") { frame.drawing = drawing }
        case .dictating:
            if let drawing = own("dictating") { frame.drawing = drawing }
        case .celebrating:
            if let drawing = own("celebrating") {
                frame.drawing = drawing
            } else {
                frame.props += [.happyEyes, .armsUp(high: pose.moodAge >= AssistantMascotPose.celebrationFlapping || wave)]
            }
        case .thumbsUp:
            if let drawing = own("thumbsUp") { frame.drawing = drawing } else { frame.props += [.happyEyes, .thumbUp] }
        case .error:
            if let drawing = own("error") { frame.drawing = drawing } else { frame.props.append(.crossedEyes) }
            // A short shake while it says so, then it stands still.
            if animated, pose.moodAge < AssistantMascotPose.talkDuration {
                frame.shake = Int(t * 10).isMultiple(of: 2) ? 0.4 : -0.4
            }
        }
        addHeadphones(&frame, pose: pose, own: own)
        return frame
    }

    private static func addHeadphones(
        _ frame: inout SVGCreatureFrame, pose: CreaturePose, own: (String) -> SVGCreatureFrame.Drawing?
    ) {
        guard pose.headphones else { return }
        if let drawing = own("recording") { frame.drawing = drawing } else { frame.props.append(.headphones) }
    }

    private static func cycle(_ t: TimeInterval, _ period: TimeInterval) -> TimeInterval {
        let value = t.truncatingRemainder(dividingBy: period)
        return value < 0 ? value + period : value
    }
}
