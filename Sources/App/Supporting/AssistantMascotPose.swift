// Purpose: AssistantMascotPose, the pixel art and animation logic of the desktop companion, the
//          little Tamagotchi-style creature that floats over every app: which mood it is in and
//          which 12 x 13 pixel frame it shows at a given moment.
// Dependencies: Sources/App/Supporting/TerminalSessionStatus.swift (the Claude sessions' status),
//               Sources/App/Supporting/MascotAvatar.swift (the bodies of every creature)
// Used by: Sources/App/Supporting/CompanionController.swift (picks the mood, samples frames),
//          Sources/App/Views/CompanionView.swift (draws them), Tests/AssistantMascotPoseTests.swift
// Notes: User request 2026-10-13: a small animated pixel creature, Tamagotchi style. It started as
//        the main page's assistant button and became the desktop companion the same day, taking
//        over the meeting pill's job (user decision: it replaces the pill completely).
//        Decisions:
//        - Mood priority: dictation > a Claude mini task working > a meeting question (detected,
//          consent, "Meeting over?") > a Claude session waiting > error > celebrating (a saved
//          recording, a finished Claude turn) > a Claude session working > sleeping > idle.
//          A recording is not a mood: headphones go on over whatever mood shows.
//        - It "talks" (the mouth flaps) for the first 1.5 s of every notification mood.
//        - Pure functions of time: no timers or state here, the controller samples `frame`. Blinks
//          and glances come from a hash of the time slot, so tests are deterministic.
//        - Inks instead of colours: the view maps them to the active theme (body = accent).
//        - `animated == false` (Reduce Motion) gives a still pose that still shows the mood.
//        - Design review (2026-10-13): faces must not touch in the 8 pixel wide face (spread
//          "^ ^" when happy, "> <" on error), eyes in a fixed near-black ink, slow breathing
//          (every 4.5 s), no motion while recording (it lasts hours), waiting and celebrating calm
//          down after 8 and 3 s, hops and typing timed to whole 8 fps frames, sleep shows a
//          drifting "z" instead of a speech bubble.
//        - Running (user request 2026-10-13: shaking the mouse makes it run cutely to the pointer,
//          fast): two poses swapping ten times a second, a stride on the ground with dust behind
//          and a tucked step one pixel up; arms pump, eyes look ahead, mouth open; no hop and no
//          blink while running, the mood's bubble rides along. Still poses never run.
//        - The small companions (sidekicks) show no bubble and no status light, only poses: a
//          finished turn is a thumb up (`thumbsUp`, the thumb reaching into the canvas headroom
//          through `MascotFrame.overhead`), and waiting keeps waving until answered
//          (`keepsWaving`).

import Foundation

/// What a pixel is painted with; the view turns inks into theme colours.
enum MascotInk: Character, Sendable {
    case outline = "o"
    /// Fixed near-black, so the eyes stay readable on any accent.
    case eye = "e"
    case body = "b"
    case shine = "h"
    case cheek = "c"
    /// Headphones while a recording runs.
    case gear = "p"
    case laptop = "k"
    case laptopLogo = "s"
    /// The avatar's own feature colour: beak and feet, ears, stem and leaf (MascotAvatar).
    case feature = "f"

    /// A puff of dust behind running feet, in the laptop's neutral grey.
    static let dust = MascotInk.laptop
    /// The glint on the Cool Cat's shades, in the laptop logo's white.
    static let glint = MascotInk.laptopLogo
}

/// A 12 x 13 pixel image; row 12 holds the feet.
struct MascotGrid: Equatable, Sendable {
    static let width = 12
    static let height = 13

    private(set) var cells: [MascotInk?]

    init(rows: [String]) {
        cells = Array(repeating: nil, count: Self.width * Self.height)
        for (y, row) in rows.prefix(Self.height).enumerated() {
            for (x, character) in row.prefix(Self.width).enumerated() {
                cells[y * Self.width + x] = MascotInk(rawValue: character)
            }
        }
    }

    subscript(x: Int, y: Int) -> MascotInk? {
        get {
            guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return nil }
            return cells[y * Self.width + x]
        }
        set {
            guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return }
            cells[y * Self.width + x] = newValue
        }
    }

    mutating func paint(_ points: [(Int, Int)], _ ink: MascotInk?) {
        for (x, y) in points { self[x, y] = ink }
    }

    /// The resting creature: a round body with a shine, side nubs and two feet.
    static let body = MascotGrid(rows: [
        "............",
        "....oooo....",
        "..oobbbboo..",
        ".obhhbbbbbo.",
        ".obhbbbbbbo.",
        ".obbbbbbbbo.",
        ".obbbbbbbbo.",
        ".obbbbbbbbo.",
        "oobbbbbbbboo",
        ".obbbbbbbbo.",
        "..obbbbbbo..",
        "...oooooo...",
        "...oo..oo...",
    ])

    /// Breathing out: the top sinks one row (row 4 drops out), the face stays where it is.
    static let squashed: MascotGrid = {
        var grid = body
        for y in stride(from: 4, through: 2, by: -1) {
            for x in 0..<width { grid[x, y] = body[x, y - 1] }
        }
        for x in 0..<width { grid[x, 1] = nil }
        return grid
    }()
}

/// The little speech bubble above the creature.
enum MascotBubble: Equatable, Sendable {
    /// Claude waits for the user: "!".
    case attention
    /// Claude works: one to three dots.
    case thinking(dots: Int)
    /// A turn finished or a recording was saved: a check mark.
    case done
    case error
    /// A meeting question (record it? is it over?): "?".
    case question
    /// Dictation: three bars that move (step picks their heights).
    case sound(step: Int)
    /// Asleep: no bubble, a small "z" that drifts up and to the right (step 0 to 3).
    case sleep(step: Int)
    /// The Sweet Cat idles: no bubble, now and then a pink heart rising beside its head.
    case heart
}

enum MascotMood: Equatable, Sendable {
    case idle
    /// Nothing happened for a long time.
    case sleeping
    /// A Claude session or a Claude mini task works.
    case working
    /// A Claude session waits for the user.
    case waiting
    /// Something finished: a Claude turn, a saved recording, a Claude mini task.
    case celebrating
    case error
    /// The meeting pill asks something: a detected meeting, consent, "Meeting over?".
    case asking
    /// Quick dictation or a Claude mini task listening.
    case dictating
    /// A small companion's Claude turn just finished: it holds its thumb up. Never resolved from
    /// signals; the controller gives it to the sidekicks in place of celebrating.
    case thumbsUp

    /// What the companion knows about the app at one moment.
    struct Signals: Equatable {
        var claudeStatuses: [TerminalSessionStatus] = []
        var isRecording = false
        /// A detected meeting runs unrecorded (the pill's ignored-meeting ring).
        var meetingRunning = false
        var meetingQuestion = false
        var dictating = false
        var claudeTaskWorking = false
        var claudeTaskFailed = false
        /// A recording was just saved, or a Claude turn or mini task just finished.
        var isCelebrating = false
        var isDrowsy = false
    }

    static func resolve(_ signals: Signals) -> MascotMood {
        if signals.dictating { return .dictating }
        if signals.claudeTaskWorking { return .working }
        if signals.claudeTaskFailed { return .error }
        if signals.meetingQuestion { return .asking }
        if signals.claudeStatuses.contains(.waiting) { return .waiting }
        if signals.claudeStatuses.contains(.error) { return .error }
        if signals.isCelebrating { return .celebrating }
        if signals.claudeStatuses.contains(.working) { return .working }
        // Never asleep during a call: people sit still while they listen.
        if signals.isDrowsy && !signals.isRecording && !signals.meetingRunning { return .sleeping }
        return .idle
    }

    /// Moods that start with the mouth flapping, as if the creature says something.
    var talks: Bool {
        switch self {
        case .waiting, .error, .asking, .celebrating: true
        default: false
        }
    }

    /// For VoiceOver and the tooltip.
    var spokenDescription: String {
        switch self {
        case .idle, .sleeping: "Ready"
        case .working: "Claude is working"
        case .waiting: "Claude is waiting for you"
        case .celebrating, .thumbsUp: "Done"
        case .error: "Something went wrong"
        case .asking: "MinuteMind has a question"
        case .dictating: "Listening"
        }
    }
}

/// One pixel outside the grid, in the canvas headroom above it (y -1 and -2).
struct MascotPixel: Equatable, Sendable {
    let x: Int
    let y: Int
    let ink: MascotInk
}

/// One frame: the image, how many pixels it is lifted off the ground and the bubble.
struct MascotFrame: Equatable, Sendable {
    var grid: MascotGrid
    /// Pixels above the grid (the raised thumb), drawn into the canvas headroom.
    var overhead: [MascotPixel] = []
    /// Pixels above the resting position (hops).
    var lift = 0
    var bubble: MascotBubble?
    /// Pixels the bubble bounces up.
    var bubbleLift = 0
}

enum AssistantMascotPose {
    struct Input {
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
        /// Waiting waves until answered instead of calming down after `waitingExcitement` (the
        /// small companions, whose pose is their only sign).
        var keepsWaving = false
    }

    /// How long a hop takes, in seconds: six frames at 8 fps, squash to squash.
    static let hopDuration: TimeInterval = 0.75
    /// Waiting waves and bounces this long, then only hops now and then.
    static let waitingExcitement: TimeInterval = 8
    /// Celebrating flaps its arms this long, then holds the pose.
    static let celebrationFlapping: TimeInterval = 3
    /// The mouth flaps this long at the start of a notification mood.
    static let talkDuration: TimeInterval = 1.5
    /// Steps a second while running: each step swaps the feet.
    static let runningSteps: Double = 10
    /// The Sweet Cat's heart shows for `heartShown` seconds of every `heartPeriod`.
    static let heartPeriod: TimeInterval = 12
    static let heartShown: TimeInterval = 4

    static func frame(_ input: Input) -> MascotFrame {
        if input.animated, let direction = input.running {
            return runningFrame(input, direction: direction < 0 ? -1 : 1)
        }
        let mood = input.mood
        let t = input.time
        let animated = input.animated
        let avatar = input.avatar
        var frame = MascotFrame(grid: avatar.body)
        var squashed = false

        // Slow breathing; a recording keeps still (it can last hours).
        if animated, !input.headphones {
            switch mood {
            case .idle, .celebrating:
                squashed = cycle(t, 4.5) > 4
            case .sleeping:
                squashed = cycle(t, 4.5) > 3.3
            case .working, .waiting, .error, .asking, .dictating, .thumbsUp:
                break
            }
        }

        // Hop in whole 8 fps frames: squash, up one, up two, up two, up one, landing squash.
        if animated, let age = input.hopAge, age >= 0, age < hopDuration {
            switch age {
            case ..<0.125: squashed = true
            case ..<0.25: frame.lift = 1
            case ..<0.5: frame.lift = 2
            case ..<0.625: frame.lift = 1
            default: squashed = true
            }
        }
        if squashed { frame.grid = avatar.squashed }
        if frame.lift > 0 {
            frame.grid.paint([(3, 12), (4, 12), (7, 12), (8, 12)], nil)
        }

        let look = input.look ?? idleGlance(t, animated: animated)
        let wave = animated && Int(t * 4).isMultiple(of: 2)
        // Talking: the mouth opens and closes four times a second.
        let talking = animated && mood.talks && input.moodAge < talkDuration
        let mouthOpen = talking && Int(input.moodAge * 4).isMultiple(of: 2)

        switch mood {
        case .idle:
            if avatar.isContent, !input.hovering {
                contentEyes(&frame.grid)
            } else if animated, isBlinking(t) {
                closedEyes(&frame.grid)
            } else {
                openEyes(&frame.grid, look)
            }
            // The heart rises a pixel at a time, then goes; a still pose keeps it.
            if avatar.isContent {
                let age = cycle(t, heartPeriod)
                if !animated || age < heartShown {
                    frame.bubble = .heart
                    frame.bubbleLift = animated ? min(2, Int(age / (heartShown / 3))) : 0
                }
            }
            if input.hovering {
                smile(&frame.grid)
                waveRightArm(&frame.grid, high: wave, avatar: avatar)
            } else {
                frame.grid.paint(avatar.neutralMouth, .outline)
            }
        case .sleeping:
            closedEyes(&frame.grid)
            frame.grid.paint(avatar.neutralMouth, .outline)
            frame.bubble = .sleep(step: animated ? Int(cycle(t, 2) * 2) : 1)
        case .working:
            // Eyes down on a little laptop, hands tapping.
            frame.grid.paint([(4, 7), (7, 7)], .eye)
            laptop(&frame.grid, leftHandUp: animated && Int(t * 4).isMultiple(of: 2), avatar: avatar)
            frame.bubble = .thinking(dots: animated ? Int(t * 2.5) % 3 + 1 : 3)
        case .waiting:
            openEyes(&frame.grid, input.look ?? (0, 0))
            openMouth(&frame.grid)
            frame.bubble = .attention
            if input.keepsWaving || input.moodAge < waitingExcitement {
                waveRightArm(&frame.grid, high: wave, avatar: avatar)
                if animated, frame.lift == 0, cycle(t, 1.2) < 0.25 { frame.lift = 1 }
                frame.bubbleLift = animated && cycle(t, 0.6) < 0.3 ? 1 : 0
            } else {
                // Calmer after a while: arm up, a small hop every five seconds.
                waveRightArm(&frame.grid, high: true, avatar: avatar)
                if animated, frame.lift == 0, cycle(t, 5) < 0.25 { frame.lift = 1 }
            }
        case .asking:
            openEyes(&frame.grid, input.look ?? (0, 0))
            if talking, !mouthOpen {
                frame.grid.paint(avatar.neutralMouth, .outline)
            } else {
                openMouth(&frame.grid)
            }
            frame.bubble = .question
        case .celebrating:
            happyEyes(&frame.grid)
            if talking, mouthOpen { openMouth(&frame.grid) } else { wideSmile(&frame.grid) }
            armsUp(&frame.grid, high: input.moodAge >= celebrationFlapping || wave, avatar: avatar)
            frame.bubble = .done
        case .thumbsUp:
            happyEyes(&frame.grid)
            wideSmile(&frame.grid)
            thumbUp(&frame, avatar: avatar)
        case .error:
            crossedEyes(&frame.grid)
            if talking, mouthOpen {
                openMouth(&frame.grid)
            } else {
                frame.grid.paint([(4, 10), (5, 9), (6, 9), (7, 10)], .outline)
            }
            frame.grid.paint([(2, 8), (9, 8)], .body)
            frame.bubble = .error
        case .dictating:
            // Eyes up, mouth shut: it listens.
            openEyes(&frame.grid, (0, -1))
            frame.grid.paint(avatar.neutralMouth, .outline)
            frame.bubble = .sound(step: animated ? Int(t * 6) : 0)
        }

        if avatar.wearsShades {
            shades(&frame.grid, avatar: avatar, raised: [.waiting, .error, .sleeping].contains(mood))
        }
        if input.headphones { headphones(&frame.grid, sunk: squashed, avatar: avatar) }
        return frame
    }

    // MARK: - Running

    /// A dash to the pointer, two poses that swap every step. Coordinates are written for running
    /// right and mirrored for running left. Pose A: the back foot pushes off on the ground, the
    /// front foot reaches forward, a puff of dust behind. Pose B, one pixel up: the other foot
    /// lands under the body, the back foot kicks up behind. The arms pump against the feet.
    private static func runningFrame(_ input: Input, direction: Int) -> MascotFrame {
        let avatar = input.avatar
        let body = avatar.body
        let step = Int((input.time * runningSteps).rounded(.down))
        let poseA = step.isMultiple(of: 2)
        // The mood's bubble rides along; no hop, no blinking, no laptop while running.
        var still = input
        still.running = nil
        still.hopAge = nil
        let bubble = frame(still).bubble
        var frame = MascotFrame(grid: body, lift: poseA ? 0 : 1, bubble: bubble)
        let mx: (Int) -> Int = { direction > 0 ? $0 : MascotGrid.width - 1 - $0 }

        // Feet: the avatar's own foot ink and width (the lime stands on one pixel legs).
        let footInk = body[3, 12] ?? body[4, 12] ?? .outline
        let slim = body[3, 12] == nil
        frame.grid.paint((0..<MascotGrid.width).map { ($0, 12) }, nil)
        let feet: [(Int, Int)]
        if poseA {
            // Stride: the front foot lands ahead, the back foot pushes off with its heel up.
            feet = slim ? [(8, 12), (3, 12), (2, 11)] : [(8, 12), (9, 12), (2, 12), (1, 11)]
            frame.grid.paint([(mx(0), 12)], .dust)
        } else {
            // In the air: the feet pass under the body, the other one tucked out of sight.
            feet = slim ? [(5, 12)] : [(4, 12), (5, 12)]
        }
        frame.grid.paint(feet.map { (mx($0.0), $0.1) }, footInk)

        // Arms (the side nubs) pump: front arm down while the front foot reaches, then up.
        if !avatar.nubs.isEmpty {
            frame.grid.paint(avatar.nubs, nil)
            frame.grid.paint([(mx(0), poseA ? 7 : 9), (mx(11), poseA ? 9 : 7)], .outline)
        }

        // Eyes ahead, mouth open: a happy dash. Eyes that would sit on the dog's nose look up a
        // little instead.
        let onNose = body[4 + direction, 8] == .eye || body[7 + direction, 8] == .eye
        openEyes(&frame.grid, (direction, onNose ? -1 : 0))
        openMouth(&frame.grid)
        if avatar.wearsShades { shades(&frame.grid, avatar: avatar, raised: false) }
        if input.headphones { headphones(&frame.grid, sunk: false, avatar: avatar) }
        return frame
    }

    // MARK: - Timing

    private static func cycle(_ t: TimeInterval, _ period: TimeInterval) -> TimeInterval {
        let value = t.truncatingRemainder(dividingBy: period)
        return value < 0 ? value + period : value
    }

    /// A stable pseudo-random number in 0..<1 for a time slot.
    static func noise(_ slot: Int) -> Double {
        var x = UInt64(bitPattern: Int64(slot)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x % 10_000) / 10_000
    }

    /// One blink somewhere in every four seconds, now and then a double blink.
    static func isBlinking(_ t: TimeInterval) -> Bool {
        let slot = Int((t / 4).rounded(.down))
        let local = cycle(t, 4)
        let start = 0.4 + noise(slot) * 3.2
        if local >= start, local < start + 0.16 { return true }
        return noise(slot + 7_919) > 0.8 && local >= start + 0.32 && local < start + 0.48
    }

    /// Without a mouse to follow the creature sometimes looks to one side for a second.
    private static func idleGlance(_ t: TimeInterval, animated: Bool) -> (x: Int, y: Int) {
        guard animated else { return (0, 0) }
        let slot = Int((t / 9).rounded(.down))
        let local = cycle(t, 9)
        guard noise(slot + 104_729) > 0.45, local >= 3, local < 4.2 else { return (0, 0) }
        return (noise(slot + 15_485_863) > 0.5 ? 1 : -1, 0)
    }

    // MARK: - Faces and props

    private static func openEyes(_ grid: inout MascotGrid, _ look: (x: Int, y: Int)) {
        let dx = max(-1, min(1, look.x))
        let dy = max(-1, min(1, look.y))
        // Eyes at x 4 and 7: shifted either way they still keep a body pixel to the outline.
        for x in [4, 7] {
            grid.paint([(x + dx, 6 + dy), (x + dx, 7 + dy)], .eye)
        }
        cheeks(&grid)
    }

    private static func closedEyes(_ grid: inout MascotGrid) {
        grid.paint([(3, 7), (4, 7), (7, 7), (8, 7)], .eye)
        cheeks(&grid)
    }

    private static func happyEyes(_ grid: inout MascotGrid) {
        // "^ ^" spread out to x 3 and 8: centred on the normal eyes they would touch in the middle.
        grid.paint([(2, 7), (3, 6), (4, 7), (7, 7), (8, 6), (9, 7)], .eye)
        cheeks(&grid)
    }

    /// Half closed and at ease: a line on the eye row whose outer ends droop.
    private static func contentEyes(_ grid: inout MascotGrid) {
        grid.paint([(2, 7), (3, 6), (4, 6), (7, 6), (8, 6), (9, 7)], .eye)
        cheeks(&grid)
    }

    private static func crossedEyes(_ grid: inout MascotGrid) {
        // "> <": crosses would touch in the middle.
        grid.paint([(3, 5), (4, 6), (3, 7), (8, 5), (7, 6), (8, 7)], .eye)
    }

    private static func cheeks(_ grid: inout MascotGrid) {
        grid.paint([(2, 8), (9, 8)], .cheek)
    }

    /// Dark top, pink inside, clear of the bottom outline.
    private static func openMouth(_ grid: inout MascotGrid) {
        grid.paint([(5, 9), (6, 9)], .outline)
        grid.paint([(5, 10), (6, 10)], .cheek)
    }

    private static func smile(_ grid: inout MascotGrid) {
        grid.paint([(4, 9), (5, 10), (6, 10), (7, 9)], .outline)
    }

    private static func wideSmile(_ grid: inout MascotGrid) {
        grid.paint([(3, 9), (4, 10), (5, 10), (6, 10), (7, 10), (8, 9)], .outline)
    }

    private static func waveRightArm(_ grid: inout MascotGrid, high: Bool, avatar: MascotAvatar) {
        if avatar.nubs.contains(where: { $0 == (11, 8) }) { grid[11, 8] = nil }
        grid.paint(high ? [(11, 4), (11, 3)] : [(11, 6), (11, 5)], .outline)
    }

    /// The right arm raised beside the head, a fist in the body colour over the head's corner
    /// (it covers a right ear), the thumb on top reaching into the canvas headroom.
    private static func thumbUp(_ frame: inout MascotFrame, avatar: MascotAvatar) {
        frame.grid.paint(avatar.nubs.filter { $0.0 == 11 }, nil)
        frame.grid.paint([(11, 4), (11, 5), (11, 6), (11, 7)], .outline)
        frame.grid.paint([(8, 0), (10, 0), (11, 0), (8, 1), (11, 1), (8, 2), (11, 2), (9, 3), (10, 3), (11, 3)], .outline)
        frame.grid.paint([(9, 0), (9, 1), (10, 1), (9, 2), (10, 2)], .body)
        frame.overhead = [
            MascotPixel(x: 9, y: -2, ink: .outline),
            MascotPixel(x: 8, y: -1, ink: .outline),
            MascotPixel(x: 9, y: -1, ink: .body),
            MascotPixel(x: 10, y: -1, ink: .outline),
        ]
    }

    private static func armsUp(_ grid: inout MascotGrid, high: Bool, avatar: MascotAvatar) {
        grid.paint(avatar.nubs, nil)
        grid.paint(high ? [(0, 4), (0, 3), (11, 4), (11, 3)] : [(0, 6), (0, 5), (11, 6), (11, 5)], .outline)
    }

    /// The Cool Cat's sunglasses: a bar, lenses three pixels wide hanging below it, a glint in
    /// the same corner of each. Down (rows 6 and 7) they cover the eyes, which are wiped first so
    /// none peek out (happy and crossed eyes reach past the lenses); raised (rows 3 and 4) they sit
    /// on the forehead and the mood's eyes show.
    private static func shades(_ grid: inout MascotGrid, avatar: MascotAvatar, raised: Bool) {
        let top = raised ? 3 : 6
        if !raised {
            for y in 5...7 {
                for x in 2...9 { grid[x, y] = avatar.body[x, y] }
            }
        }
        grid.paint((2...9).map { ($0, top) }, .eye)
        grid.paint([2, 3, 4, 7, 8, 9].map { ($0, top + 1) }, .eye)
        grid.paint([(2, top), (7, top)], .glint)
    }

    /// Every avatar's head top is row 1; `sunk` while breathing out.
    /// The Cool Cat's cups sit a row higher, or they would run into its shades as one dark visor.
    private static func headphones(_ grid: inout MascotGrid, sunk: Bool, avatar: MascotAvatar) {
        let band = [(1, 3), (1, 2), (2, 1), (3, 0), (4, 0), (5, 0), (6, 0), (7, 0), (8, 0), (9, 1), (10, 2), (10, 3)]
        grid.paint(band.map { ($0.0, $0.1 + (sunk ? 1 : 0)) }, .gear)
        let cups = avatar.wearsShades ? 3...5 : 4...6
        grid.paint(cups.flatMap { [(0, $0), (1, $0), (10, $0), (11, $0)] }, .gear)
    }

    /// A two row lid below the cheeks, so the face stays readable (design review).
    private static func laptop(_ grid: inout MascotGrid, leftHandUp: Bool, avatar: MascotAvatar) {
        for y in 9...10 {
            for x in 3...8 { grid[x, y] = .laptop }
        }
        grid.paint([(5, 10), (6, 10)], .laptopLogo)
        for x in 2...9 { grid[x, 11] = .laptop }
        grid.paint(avatar.nubs, nil)
        grid.paint([(2, leftHandUp ? 9 : 10), (9, leftHandUp ? 10 : 9)], .outline)
    }
}
