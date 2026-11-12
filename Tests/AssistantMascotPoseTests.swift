// Purpose: Tests for the desktop companion's pixel creature: which mood wins, and that frames show
//          what the mood promises (bubbles, closed eyes, headphones, talking, hops, still poses,
//          running to the pointer, a small companion's thumb up and endless waving).
// Dependencies: Sources/App/Supporting/AssistantMascotPose.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("AssistantMascotPose Tests")
struct AssistantMascotPoseTests {
    private func frame(
        _ mood: MascotMood, at time: TimeInterval = 0.05, hopAge: TimeInterval? = nil,
        moodAge: TimeInterval = 0, headphones: Bool = false, animated: Bool = true
    ) -> MascotFrame {
        AssistantMascotPose.frame(.init(
            mood: mood, time: time, look: (0, 0), hopAge: hopAge, moodAge: moodAge,
            headphones: headphones, animated: animated))
    }

    private func mood(_ change: (inout MascotMood.Signals) -> Void) -> MascotMood {
        var signals = MascotMood.Signals()
        change(&signals)
        return MascotMood.resolve(signals)
    }

    @Test("Dictation beats everything, a meeting question beats Claude")
    func moodPriority() {
        #expect(mood { $0.dictating = true; $0.meetingQuestion = true; $0.claudeStatuses = [.waiting] } == .dictating)
        #expect(mood { $0.claudeTaskWorking = true; $0.meetingQuestion = true } == .working)
        #expect(mood { $0.meetingQuestion = true; $0.claudeStatuses = [.waiting, .error] } == .asking)
        #expect(mood { $0.claudeStatuses = [.working, .waiting, .error]; $0.isCelebrating = true } == .waiting)
        #expect(mood { $0.claudeStatuses = [.working, .error] } == .error)
    }

    @Test("Celebrating beats a working session; sleep never during a recording")
    func moodWithoutQuestions() {
        #expect(mood { $0.claudeStatuses = [.working]; $0.isCelebrating = true } == .celebrating)
        #expect(mood { $0.claudeStatuses = [.done, .working] } == .working)
        #expect(mood { $0.isDrowsy = true } == .sleeping)
        #expect(mood { $0.isDrowsy = true; $0.isRecording = true } == .idle)
        #expect(mood { $0.isDrowsy = true; $0.meetingRunning = true } == .idle)
        #expect(mood { $0.claudeStatuses = [.done] } == .idle)
    }

    @Test("Notification moods talk at first, then stop")
    func talking() {
        let early = (0..<12).map { frame(.asking, at: 0.05, moodAge: Double($0) * 0.125).grid[5, 10] }
        #expect(early.contains(.cheek) && early.contains(.body))
        let later = (0..<12).map { frame(.asking, at: 0.05, moodAge: 3 + Double($0) * 0.125).grid[5, 10] }
        #expect(later.allSatisfy { $0 == .cheek })
    }

    @Test("Meeting questions ask, dictation listens")
    func companionBubbles() {
        #expect(frame(.asking).bubble == .question)
        if case .sound = frame(.dictating).bubble {} else { Issue.record("dictating shows no sound bars") }
    }

    @Test("Each mood carries its bubble; idle has none")
    func bubbles() {
        #expect(frame(.idle).bubble == nil)
        #expect(frame(.waiting).bubble == .attention)
        #expect(frame(.celebrating).bubble == .done)
        #expect(frame(.error).bubble == .error)
        if case .thinking = frame(.working).bubble {} else { Issue.record("working shows no thinking bubble") }
        if case .sleep = frame(.sleeping).bubble {} else { Issue.record("sleeping shows no z") }
    }

    @Test("Sleeping eyes are closed lines, open eyes are two pixels tall")
    func eyes() {
        let asleep = frame(.sleeping).grid
        #expect(asleep[4, 7] == .eye && asleep[4, 6] == .body)
        let awake = frame(.idle, animated: false).grid
        #expect(awake[4, 6] == .eye && awake[4, 7] == .eye)
        #expect(awake[7, 6] == .eye && awake[7, 7] == .eye)
    }

    @Test("A recording puts headphones on over any mood")
    func headphones() {
        for mood in [MascotMood.idle, .working, .waiting, .asking] {
            let grid = frame(mood, headphones: true, animated: false).grid
            #expect(grid[5, 0] == .gear)
            #expect(grid[0, 5] == .gear && grid[11, 5] == .gear)
        }
        #expect(frame(.idle, animated: false).grid[5, 0] == nil)
    }

    @Test("A hop lifts the creature and tucks its feet, then it lands")
    func hop() {
        #expect(frame(.idle, hopAge: 0.05).lift == 0)
        let air = frame(.idle, hopAge: 0.3)
        #expect(air.lift == 2)
        #expect(air.grid[3, 12] == nil)
        #expect(frame(.idle, hopAge: 1).lift == 0)
        #expect(frame(.idle, hopAge: 0.3, animated: false).lift == 0)
    }

    @Test("A still pose never blinks, bounces or animates its bubble")
    func stillPose() {
        for time in stride(from: 0.0, to: 12, by: 0.05) {
            let still = frame(.waiting, at: time, animated: false)
            #expect(still.lift == 0 && still.bubbleLift == 0)
            #expect(frame(.idle, at: time, animated: false).grid[4, 6] == .eye)
        }
        #expect(frame(.working, at: 3.3, animated: false).bubble == .thinking(dots: 3))
    }

    @Test("Waiting calms down after a while: still bubble, at most a hop every five seconds")
    func waitingCalmsDown() {
        let excited = stride(from: 0.0, to: 5, by: 0.125).map { frame(.waiting, at: $0, moodAge: 1) }
        #expect(excited.contains { $0.bubbleLift > 0 })
        let calm = stride(from: 0.0, to: 10, by: 0.125).map { frame(.waiting, at: $0, moodAge: 30) }
        #expect(calm.allSatisfy { $0.bubbleLift == 0 })
        #expect(calm.filter { $0.lift > 0 }.count <= 4)
    }

    @Test("A small companion keeps waving while it waits")
    func sidekickKeepsWaving() {
        let arms = stride(from: 0.0, to: 2, by: 0.25).map { time in
            AssistantMascotPose.frame(.init(mood: .waiting, time: time, look: (0, 0), moodAge: 30, keepsWaving: true)).grid[11, 6]
        }
        #expect(arms.contains(.outline) && arms.contains(nil))
    }

    @Test("Thumbs up: right arm raised, a fist over the head's corner, the thumb above the grid")
    func thumbsUp() {
        for avatar in MascotAvatar.allCases {
            let frame = AssistantMascotPose.frame(.init(mood: .thumbsUp, time: 0.05, look: nil, avatar: avatar, animated: false))
            #expect(frame.overhead.contains(MascotPixel(x: 9, y: -2, ink: .outline)), "\(avatar) has a thumb")
            #expect(frame.grid[9, 1] == .body && frame.grid[10, 1] == .body, "\(avatar) has a fist")
            #expect((4...7).allSatisfy { frame.grid[11, $0] == .outline }, "\(avatar) raises its arm")
            #expect(frame.bubble == nil)
            #expect(frame.lift == 0)
        }
        // The arm goes up, so the right nub is gone; the lime has none and keeps its outline.
        let blob = AssistantMascotPose.frame(.init(mood: .thumbsUp, time: 0.05, look: nil, avatar: .blob))
        #expect(blob.grid[11, 8] == nil && blob.grid[0, 8] == .outline)
        let lime = AssistantMascotPose.frame(.init(mood: .thumbsUp, time: 0.05, look: nil, avatar: .lime))
        #expect(lime.grid[11, 8] == .outline)
        // No other mood draws above the grid.
        for mood in [MascotMood.idle, .working, .waiting, .celebrating, .error, .asking, .dictating, .sleeping] {
            #expect(frame(mood).overhead.isEmpty)
        }
    }

    @Test("A recording keeps still: no breathing, no bob")
    func listeningKeepsStill() {
        let first = frame(.idle, at: 0.3, headphones: true).grid
        for time in stride(from: 0.0, to: 10, by: 0.125) where !AssistantMascotPose.isBlinking(time) {
            #expect(frame(.idle, at: time, headphones: true).grid == first)
        }
    }

    @Test("Faces never touch in the middle column pair")
    func facesStayApart() {
        for mood in [MascotMood.celebrating, .error] {
            let grid = frame(mood, animated: false).grid
            for y in 5...7 {
                #expect(grid[5, y] == .body && grid[6, y] == .body)
            }
        }
    }

    @Test("Blinks happen about once every four seconds and are short")
    func blinking() {
        let samples = stride(from: 0.0, to: 400, by: 0.02).map(AssistantMascotPose.isBlinking)
        let blinkTime = Double(samples.filter { $0 }.count) * 0.02
        #expect(blinkTime > 400 / 4 * 0.12)
        #expect(blinkTime < 400 / 4 * 0.4)
    }

    @Test("Eyes looking sideways never touch the outline")
    func eyesKeepClearOfOutline() {
        for dx in [-1, 1] {
            let grid = AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: (dx, 0), animated: false)).grid
            for y in 6...7 {
                #expect(grid[2, y] == .body && grid[9, y] == .body)
            }
        }
    }

    @Test("The squashed body keeps the face rows in place")
    func squash() {
        for y in 5..<MascotGrid.height {
            for x in 0..<MascotGrid.width {
                #expect(MascotGrid.squashed[x, y] == MascotGrid.body[x, y])
            }
        }
        #expect(MascotGrid.squashed[4, 1] == nil)
        #expect(MascotGrid.squashed[4, 2] == .outline)
    }

    @Test("Every avatar keeps the shared face: eyes, squash, headphones, waving")
    func avatarsShareTheFace() {
        for avatar in MascotAvatar.allCases {
            // Hovered, so the Sweet Cat opens its eyes too.
            let idle = AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: (0, 0), hovering: true, avatar: avatar, animated: false)).grid
            // The Cool Cat's glint sits on the right lens where the eye would be.
            #expect(idle[4, 6] == .eye && (idle[7, 6] == .eye || avatar.wearsShades), "\(avatar) eyes")
            for y in 5..<MascotGrid.height {
                for x in 0..<MascotGrid.width {
                    #expect(avatar.squashed[x, y] == avatar.body[x, y], "\(avatar) squash keeps row \(y)")
                }
            }
            let recording = AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: (0, 0), headphones: true, avatar: avatar, animated: false)).grid
            #expect(recording[5, 0] == .gear && recording[0, 5] == .gear, "\(avatar) headphones")
            #expect(!avatar.wearsShades || recording[1, 6] == .outline, "\(avatar) cups clear of the shades")
            // After the excited start the arm stays up.
            let waving = AssistantMascotPose.frame(.init(mood: .waiting, time: 0.05, look: (0, 0), moodAge: 30, avatar: avatar, animated: false)).grid
            #expect(waving[11, 3] == .outline && waving[11, 4] == .outline, "\(avatar) waves")
        }
        // The lime has no nubs: waving must not cut a hole in its outline.
        let lime = AssistantMascotPose.frame(.init(mood: .waiting, time: 0.05, look: (0, 0), avatar: .lime, animated: false)).grid
        #expect(lime[11, 8] == .outline)
        #expect(MascotAvatar.duck.body[5, 8] == .feature, "the duck has its beak")
        #expect(MascotAvatar.pug.body[3, 8] == .feature && MascotAvatar.pug.body[5, 10] == .cheek, "the pug has its muzzle and tongue")
        #expect(MascotAvatar.puppy.body[11, 9] == .feature, "the puppy has its tail")
        #expect(MascotAvatar.cat.body[2, 1] == .cheek && MascotAvatar.cat.body[9, 1] == .cheek, "the cat has pink ears")
        #expect(MascotAvatar.cat.body[5, 9] == .cheek && MascotAvatar.cat.body[11, 9] == .feature, "the cat has its nose and tail")
    }

    @Test("The Cool Cat wears its shades down, and pushes them up to wait, err or sleep")
    func coolCatShades() {
        func shadesAt(_ grid: MascotGrid, _ top: Int) -> Bool {
            (2...9).allSatisfy { grid[$0, top] == .eye || grid[$0, top] == .glint }
                && [2, 3, 4, 7, 8, 9].allSatisfy { grid[$0, top + 1] == .eye }
        }
        func frame(_ mood: MascotMood) -> MascotGrid {
            AssistantMascotPose.frame(.init(mood: mood, time: 0.05, look: (1, -1), moodAge: 30, avatar: .coolCat, animated: false)).grid
        }
        var down = [MascotMood.idle, .working, .celebrating, .asking, .dictating].map(frame)
        down.append(running(.coolCat, -1, at: 0.05).grid)
        for grid in down {
            #expect(shadesAt(grid, 6) && grid[5, 7] == .body, "shades down")
            // Nothing of the mood's eyes peeks out above the shades.
            #expect((2...9).allSatisfy { grid[$0, 5] != .eye }, "nothing above the shades")
        }
        for mood in [MascotMood.waiting, .error, .sleeping] {
            let grid = frame(mood)
            #expect(shadesAt(grid, 3), "\(mood) pushes the shades up")
            #expect((5...7).contains { y in (2...9).contains { grid[$0, y] == .eye } }, "\(mood) shows its eyes")
        }
    }

    @Test("The Sweet Cat idles with half closed eyes and a heart now and then, and opens its eyes for everything else")
    func sweetCatContent() {
        let idle = AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: (0, 0), avatar: .sweetCat, animated: false))
        #expect(idle.bubble == .heart)
        #expect(idle.grid[2, 7] == .eye && idle.grid[3, 6] == .eye && idle.grid[4, 7] == .body, "half closed eyes")
        let hearts = stride(from: 0.0, to: AssistantMascotPose.heartPeriod, by: 0.5).map {
            AssistantMascotPose.frame(.init(mood: .idle, time: $0, look: (0, 0), avatar: .sweetCat)).bubble == .heart
        }
        #expect(hearts.contains(true) && hearts.contains(false), "the heart comes and goes")
        let rising = AssistantMascotPose.frame(.init(mood: .idle, time: AssistantMascotPose.heartShown - 0.1, look: (0, 0), avatar: .sweetCat))
        #expect(rising.bubbleLift == 2, "the heart rises")
        let waiting = AssistantMascotPose.frame(.init(mood: .waiting, time: 0.05, look: (0, 0), avatar: .sweetCat, animated: false))
        #expect(waiting.bubble == .attention && waiting.grid[4, 6] == .eye)
        let other = AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: (0, 0), avatar: .cat, animated: false))
        #expect(other.bubble == nil, "only the Sweet Cat carries a heart")
    }

    private func running(_ avatar: MascotAvatar = .blob, _ direction: Int = 1, at time: TimeInterval,
                         mood: MascotMood = .idle, animated: Bool = true) -> MascotFrame {
        AssistantMascotPose.frame(.init(
            mood: mood, time: time, look: (0, 0), hopAge: 0.3, avatar: avatar, animated: animated, running: direction))
    }

    @Test("Running swaps the feet every step and bobs on every other one")
    func runningFeetAlternate() {
        let steps = (0..<6).map { running(at: (Double($0) + 0.5) / AssistantMascotPose.runningSteps) }
        for (first, next) in zip(steps, steps.dropFirst()) {
            let feet = { (frame: MascotFrame) in (0..<MascotGrid.width).map { frame.grid[$0, 12] } }
            #expect(feet(first) != feet(next))
            #expect(first.lift != next.lift)
            #expect(Set([first.lift, next.lift]) == [0, 1])
        }
        // No hop while running: lift is the bob alone, never two pixels.
        #expect(steps.allSatisfy { $0.lift <= 1 })
    }

    @Test("Running looks ahead, pumps the arms and mirrors to the left")
    func runningDirection() {
        let right = running(at: 0.05).grid
        #expect(right[5, 6] == .eye && right[8, 6] == .eye)
        #expect(right[0, 7] == .outline && right[11, 9] == .outline && right[0, 8] == nil)
        let left = running(.blob, -1, at: 0.05).grid
        #expect(left[3, 6] == .eye && left[6, 6] == .eye)
        for y in 7..<MascotGrid.height {
            for x in 0..<MascotGrid.width where right[x, y] != .eye && right[x, y] != .cheek {
                let mirrored = left[MascotGrid.width - 1 - x, y]
                #expect(mirrored == right[x, y] || mirrored == .eye || mirrored == .cheek, "(\(x), \(y)) mirrored")
            }
        }
        let pumped = running(at: 0.15).grid
        #expect(pumped[0, 9] == .outline && pumped[11, 7] == .outline)
    }

    @Test("Every avatar keeps its eyes and outline while running; Reduce Motion does not run")
    func runningAvatars() {
        for avatar in MascotAvatar.allCases {
            for time in [0.05, 0.15] {
                for direction in [-1, 1] {
                    let grid = running(avatar, direction, at: time).grid
                    let eyes = (5...7).flatMap { y in (0..<MascotGrid.width).filter { grid[$0, y] == .eye }.map { ($0, y) } }
                    #expect(eyes.count >= 4, "\(avatar) keeps its eyes")
                    #expect((0..<MascotGrid.width).contains { grid[$0, 12] != nil }, "\(avatar) has a foot down")
                }
            }
        }
        // The lime has no nubs: running must not cut its outline or add arms.
        let lime = running(.lime, at: 0.05).grid
        for y in 5...8 { #expect(lime[0, y] == .outline && lime[11, y] == .outline) }
        #expect(lime[0, 9] == nil && lime[11, 9] == nil)
        // The dog's eyes never sit on its nose.
        let dog = running(.dog, at: 0.05).grid
        #expect(dog[5, 7] != .eye && dog[6, 7] != .eye)
        // A still pose stays the mood's pose.
        #expect(running(at: 0.05, animated: false) == AssistantMascotPose.frame(.init(
            mood: .idle, time: 0.05, look: (0, 0), hopAge: 0.3, animated: false)))
        // The mood's bubble rides along.
        #expect(running(at: 0.05, mood: .waiting).bubble == .attention)
    }
}
