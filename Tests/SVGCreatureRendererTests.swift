// Purpose: Tests for SVGCreatureRenderer, the pure function from a pose to an SVGCreatureFrame:
//          own mood frames win over props, the props each mood gets without them, blink frames
//          instead of the closed-eye prop, headphones or own recording frames while a recording
//          runs, facing and lean while running, and the frame index from fps and `animated`.
// Dependencies: Sources/App/Supporting/SVGCreatureRenderer.swift, Sources/App/Supporting/CreatureRenderer.swift
//               (CreaturePose), Sources/App/Supporting/AssistantMascotPose.swift (blink rhythm),
//               Sources/App/Supporting/MascotAvatarValidator.swift, Tests/SVGAvatarArtTests.swift
//               (the sample fox)
// Notes: The mood age is set past the pixel renderer's excitement and flapping phases where a
//        prop's exact value is compared, so the expected prop does not depend on the time slot.

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("SVG creature renderer Tests")
struct SVGCreatureRendererTests {
    /// The sample fox: a body and anchors, no own moods.
    private func bareArt() throws -> SVGAvatarArt {
        try #require(try MascotAvatarValidator.validated(SVGAvatarArtTests.fox).svg)
    }

    private func art(with moods: [String: Int], fps: Double = 4) throws -> SVGAvatarArt {
        var art = try bareArt()
        for (name, count) in moods {
            art.moods[name] = .init(frames: Array(repeating: SVGAvatarArtTests.body, count: count), fps: fps)
        }
        return art
    }

    private func frame(_ pose: CreaturePose, _ art: SVGAvatarArt) -> SVGCreatureFrame {
        SVGCreatureRenderer.frame(pose, art: art)
    }

    /// A moment inside a blink, and one outside.
    private func blinkTimes() throws -> (blinking: TimeInterval, open: TimeInterval) {
        let steps = stride(from: 0.0, to: 30.0, by: 0.05)
        let blinking = try #require(steps.first { AssistantMascotPose.isBlinking($0) })
        let open = try #require(steps.first { !AssistantMascotPose.isBlinking($0) })
        return (blinking, open)
    }

    @Test("A mood with own frames shows them and no props", arguments: [
        (MascotMood.sleeping, "sleeping"), (.working, "working"), (.waiting, "waiting"),
        (.celebrating, "celebrating"), (.thumbsUp, "thumbsUp"), (.error, "error"),
    ])
    func ownFramesReplaceProps(mood: MascotMood, name: String) throws {
        let art = try art(with: [name: 2])
        let frame = frame(CreaturePose(mood: mood, time: 0, moodAge: 60), art)
        #expect(frame.drawing == .mood(name, 0))
        #expect(frame.props.isEmpty)
    }

    @Test func moodsWithoutOwnFramesShowTheBodyWithProps() throws {
        let art = try bareArt()
        func props(_ mood: MascotMood) -> [SVGCreatureFrame.Prop] {
            let frame = frame(CreaturePose(mood: mood, time: 0.3, moodAge: 60), art)
            #expect(frame.drawing == .body)
            return frame.props
        }
        #expect(props(.sleeping) == [.closedEyes])
        // The tapping hand changes every quarter second: 0.3 s is an odd one, 0.1 s an even one.
        #expect(props(.working) == [.laptop(tapLeft: false)])
        #expect(frame(CreaturePose(mood: .working, time: 0.1), art).props == [.laptop(tapLeft: true)])
        // Calmed down after the first excitement: the hand stays up.
        #expect(props(.waiting) == [.wave(high: true)])
        #expect(props(.celebrating) == [.happyEyes, .armsUp(high: true)])
        #expect(props(.thumbsUp) == [.happyEyes, .thumbUp])
        #expect(props(.error) == [.crossedEyes])
    }

    @Test func blinkFramesReplaceTheClosedEyeProp() throws {
        let times = try blinkTimes()
        let bare = try bareArt()
        #expect(frame(CreaturePose(mood: .idle, time: times.blinking), bare).props == [.closedEyes])
        #expect(frame(CreaturePose(mood: .idle, time: times.blinking), bare).drawing == .body)
        #expect(frame(CreaturePose(mood: .idle, time: times.open), bare).props.isEmpty)

        let own = try art(with: ["blink": 1])
        let blinking = frame(CreaturePose(mood: .idle, time: times.blinking), own)
        #expect(blinking.drawing == .mood("blink", 0))
        #expect(blinking.props.isEmpty)
        #expect(frame(CreaturePose(mood: .idle, time: times.open), own).drawing == .body)
    }

    @Test func headphonesWhileRecordingUnlessTheAvatarDrawsThem() throws {
        let times = try blinkTimes()
        var pose = CreaturePose(mood: .idle, time: times.open)
        #expect(!frame(pose, try bareArt()).props.contains(.headphones))
        pose.headphones = true
        let propped = frame(pose, try bareArt())
        #expect(propped.drawing == .body)
        #expect(propped.props == [.headphones])

        let own = frame(pose, try art(with: ["recording": 1]))
        #expect(own.drawing == .mood("recording", 0))
        #expect(!own.props.contains(.headphones))
    }

    @Test func runningFacesItsDirectionAndLeansWithoutOwnFrames() throws {
        var pose = CreaturePose(mood: .idle, time: 0)
        pose.running = -1
        let left = frame(pose, try bareArt())
        #expect(left.mirrored)
        #expect(left.lean == 8)
        #expect(left.drawing == .body)

        pose.running = 1
        let right = frame(pose, try bareArt())
        #expect(!right.mirrored)
        #expect(right.lean == 8)

        pose.running = -1
        let own = frame(pose, try art(with: ["running": 2]))
        #expect(own.mirrored)
        #expect(own.lean == 0)
        #expect(own.drawing == .mood("running", 0))

        // A still creature does not run.
        pose.animated = false
        let still = frame(pose, try bareArt())
        #expect(!still.mirrored)
        #expect(still.lean == 0)
    }

    @Test func frameIndexFollowsFpsAndStaysAtZeroWhenNotAnimated() throws {
        let art = try art(with: ["working": 3], fps: 4)
        var pose = CreaturePose(mood: .working, time: 0)
        func index(at time: TimeInterval) -> SVGCreatureFrame.Drawing {
            pose.time = time
            return frame(pose, art).drawing
        }
        #expect(index(at: 0.1) == .mood("working", 0))
        #expect(index(at: 0.3) == .mood("working", 1))
        #expect(index(at: 0.6) == .mood("working", 2))
        // Wraps after the last frame.
        #expect(index(at: 0.8) == .mood("working", 0))

        let slow = try self.art(with: ["working": 3], fps: 1)
        pose.time = 0.6
        #expect(frame(pose, slow).drawing == .mood("working", 0))
        pose.time = 1.2
        #expect(frame(pose, slow).drawing == .mood("working", 1))

        pose.animated = false
        pose.time = 0.6
        #expect(frame(pose, art).drawing == .mood("working", 0))
    }
}
