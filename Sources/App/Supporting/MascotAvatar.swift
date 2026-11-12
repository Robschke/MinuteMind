// Purpose: MascotAvatar, the creatures the desktop companion can be: the original blob, a cute
//          duck, a funny dog, a puppy, a pug, three cats and a sour lime. Each is a 12 x 13 pixel body plus its
//          colours; the moods (eyes, mouths, arms, headphones, laptop, bubbles) are shared.
// Dependencies: Sources/App/Supporting/AssistantMascotPose.swift (MascotGrid, MascotInk)
// Used by: Sources/App/Supporting/AssistantMascotPose.swift (bodies), Sources/App/Supporting/
//          CompanionAppearance.swift (the chosen one), Sources/App/Views/CompanionView.swift
//          (colours), Sources/App/Views/AppearanceSettingsView.swift (picker)
// Notes: User request 2026-10-13: a choice of avatars, "a cute duck, a funny dog and a sour lime",
//        picked in Settings, Appearance. Decisions:
//        - Every body keeps the face where the blob has it (eyes at x 4 and 7 in rows 5 to 8,
//          mouth in rows 9 and 10, cheeks at (2,8) and (9,8), head top in row 1), so every mood
//          works for every creature without per-creature poses.
//        - Character lives in the body and one feature colour (design review): the duck's dark
//          cowlick, flat wide bill and feet (a pointed beak and orange tuft read as a chick); the
//          dog's floppy left ear, perked right ear, black nose and a lopsided grin with the tongue
//          out; the lime's citrus leaf lying on the fruit (a stem read as an apple) and a sour
//          squiggle of a mouth.
//        - Two more dogs (user request 2026-10-14, after two pixel art references): a sitting
//          orange puppy (left ear flipped up, right ear folded down, a "u" smile under the nose,
//          a little tail at the bottom right) and a pug (fawn, dark folded ears, a dark forehead
//          mark, a dark muzzle with jowls and the tongue out). The pug reference is a side view;
//          it is drawn from the front because every creature shares the face layout.
//        - A cat (user request 2026-10-19, after a draft): triangular ears with pink insides, a
//          small forehead patch (stripes above the eyes made it look grumpy), a pink nose over a
//          "u" smile, a tail curling up at the bottom right; no whiskers (beside the tail they
//          read as extra legs). Orange by default.
//        - Two more cats after a pixel art reference (an orange cat in sunglasses and a yellow cat
//          with content closed eyes and a heart above it, both side views drawn from the front):
//          the Cool Cat wears its shades over whatever eyes the mood has (no blinks or glances;
//          mouth, arms and bubbles carry the mood) and pushes them up onto its forehead when it
//          waits, errs or sleeps, so those eyes show (design review: with the shades down its error
//          face was its idle face); light ear insides, a sideways smirk, a glint in the same corner
//          of each lens (centred glints read as pupils). The Sweet Cat has an orange patch on its
//          head, orange ear insides and an orange nose, rests its eyes half closed while idle (open
//          on hover and in every other mood; flat lines would read as asleep) and now and then a
//          heart rises beside its head. The heart is pink and comes and goes (design review: a
//          steady red heart in the bubble's place read as the error bubble).
//        - Natural colours (yellow duck, tan dog, orange puppy, fawn pug, orange cats, yellow Sweet Cat,
//          green lime); the blob
//          takes the theme accent.
//          An own colour from Settings recolours the body only, never the feature colour.

import Foundation

enum MascotAvatar: String, CaseIterable, Identifiable, Sendable {
    case blob, duck, dog, puppy, pug, cat, coolCat, sweetCat, lime

    var id: String { rawValue }

    var name: String {
        switch self {
        case .blob: "Blob"
        case .duck: "Duck"
        case .dog: "Dog"
        case .puppy: "Puppy"
        case .pug: "Pug"
        case .cat: "Cat"
        case .coolCat: "Cool Cat"
        case .sweetCat: "Sweet Cat"
        case .lime: "Lime"
        }
    }

    /// The body colour without an own colour; nil = the theme's accent.
    var naturalBody: UInt32? {
        switch self {
        case .blob: nil
        case .duck: 0xFFD43B
        case .dog: 0xC98B4E
        case .puppy: 0xF2A65A
        case .pug: 0xEDCB98
        case .cat: 0xF5A65B
        case .coolCat: 0xEE8A2E
        case .sweetCat: 0xF7C948
        case .lime: 0x9CCB3B
        }
    }

    /// Beak and feet, ears, stem and leaf ("f" in the rows).
    var featureColor: UInt32 {
        switch self {
        case .blob: 0x000000
        case .duck: 0xFF8A1F
        case .dog: 0x7A4A24
        case .puppy: 0xC8702A
        case .pug: 0x6B4128
        case .cat: 0xC8702A
        case .coolCat: 0xB4531A
        case .sweetCat: 0xE8892B
        case .lime: 0x3F7D1C
        }
    }

    /// The side nubs (arms at rest); waving and laptop hands replace them.
    var nubs: [(Int, Int)] {
        self == .lime ? [] : [(0, 8), (11, 8)]
    }

    /// The mouth when the mood has nothing to say: the duck's bill is its mouth, the dog grins
    /// lopsided with its tongue out, the puppy and the cat smile under their noses, the pug's flat mouth sits
    /// under its muzzle above the tongue, the Cool Cat smirks, the Sweet Cat's nose is all it
    /// needs, the lime has a sour squiggle.
    var neutralMouth: [(Int, Int)] {
        switch self {
        case .lime: [(4, 10), (5, 9), (6, 10), (7, 9)]
        case .duck: []
        case .dog: [(4, 9), (5, 10), (7, 9)]
        case .puppy: [(4, 9), (5, 10), (6, 10), (7, 9)]
        case .pug: [(4, 9), (5, 9), (6, 9), (7, 9)]
        case .cat: [(4, 9), (5, 10), (6, 10), (7, 9)]
        case .coolCat: [(5, 10), (6, 10), (7, 9)]
        case .sweetCat: []
        case .blob: [(5, 9), (6, 9)]
        }
    }

    /// Sunglasses over the eyes in every mood (the pose paints them last).
    var wearsShades: Bool { self == .coolCat }

    /// Idle with half closed eyes and now and then a heart beside the head.
    var isContent: Bool { self == .sweetCat }

    /// The body at rest. o outline, b body, h shine, c pink, e near-black, f feature colour.
    private var rows: [String] {
        switch self {
        case .blob:
            return [
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
            ]
        case .duck:
            return [
                "......oo....",
                "....oooo....",
                "..oobbbboo..",
                ".obhhbbbbbo.",
                ".obhbbbbbbo.",
                ".obbbbbbbbo.",
                ".obbbbbbbbo.",
                ".obbbbbbbbo.",
                "oobbffffbboo",
                ".obbffffbbo.",
                "..obbbbbbo..",
                "...oooooo...",
                "...ff..ff...",
            ]
        case .dog:
            return [
                ".........oo.",
                "...ooooooffo",
                ".oobbbbbbffo",
                "offbhbbbbbo.",
                "offbbbbbbbo.",
                "offbbbbbbbo.",
                ".ofbbbbbbbo.",
                ".obbbbbbbbo.",
                "oobbbeebbboo",
                ".obbbbbbbbo.",
                "..obbbcbbo..",
                "...oooooo...",
                "...oo..oo...",
            ]
        case .puppy:
            return [
                ".oo.........",
                "offoooooo...",
                "offfbbbbbooo",
                ".offbhbbbffo",
                ".obhbbbbbffo",
                ".obbbbbbbffo",
                ".obbbbbbbbfo",
                ".obbbbbbbbo.",
                "oobbbeebbboo",
                ".obbbbbbbbof",
                "..obbbbbbof.",
                "...oooooo...",
                "...ff..ff...",
            ]
        case .pug:
            return [
                "............",
                "...oooooo...",
                "..oobffboo..",
                ".offbbbbffo.",
                "offfbbbbfffo",
                "offbbbbbbffo",
                ".obbbbbbbbo.",
                ".obbbbbbbbo.",
                "oobffeeffboo",
                ".obfbbbbfbo.",
                "..obbcbbbo..",
                "...oooooo...",
                "...ff..ff...",
            ]
        case .cat:
            return [
                "..o......o..",
                ".oco....oco.",
                ".obboooobbo.",
                ".obbbffbbbo.",
                ".obhbbbbbbo.",
                ".obhbbbbbbo.",
                ".obbbbbbbbo.",
                ".obbbbbbbbo.",
                "oobbbbbbbboo",
                ".obbbccbbbof",
                "..obbbbbbofo",
                "...oooooo.o.",
                "...oo..oo...",
            ]
        case .coolCat:
            return [
                "..o......o..",
                ".oho....oho.",
                ".obboooobbo.",
                ".obhbffbbbo.",
                ".obbbbbbbbo.",
                ".obbbbbbbbo.",
                ".obbbbbbbbo.",
                ".obbbbbbbbo.",
                "oobbbbbbbboo",
                ".obbbbbbbbof",
                "..obbbbbbofo",
                "...oooooo.o.",
                "...ff..ff...",
            ]
        case .sweetCat:
            return [
                "..o......o..",
                ".ofo....ofo.",
                ".offoooobbo.",
                ".offbbbbbbo.",
                ".obbhbbbbbo.",
                ".obhbbbbbbo.",
                ".obbbbbbbbo.",
                ".obbbbbbbbo.",
                "oobbbbbbbboo",
                ".obbbffbbbof",
                "..obbbbbbofo",
                "...oooooo.f.",
                "...oo..oo...",
            ]
        case .lime:
            return [
                ".....oof....",
                "...ooooooff.",
                "..obbbbbbo..",
                ".obhhbbbbbo.",
                ".obhbbbbbbo.",
                "obbbbbbbbbbo",
                "obbbbbbbbbbo",
                "obbbbbbbbbbo",
                "obbbbbbbbbbo",
                ".obbbbbbbbo.",
                "..obbbbbbo..",
                "...oooooo...",
                "....o..o....",
            ]
        }
    }

    var body: MascotGrid { Self.bodies[self] ?? .body }
    var squashed: MascotGrid { Self.squashedBodies[self] ?? .squashed }

    private static let bodies: [MascotAvatar: MascotGrid] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, MascotGrid(rows: $0.rows)) })

    /// Breathing out: everything above the face sinks one row (row 4 drops out).
    private static let squashedBodies: [MascotAvatar: MascotGrid] = Dictionary(
        uniqueKeysWithValues: allCases.map { avatar in
            let body = MascotGrid(rows: avatar.rows)
            var grid = body
            for y in stride(from: 4, through: 1, by: -1) {
                for x in 0..<MascotGrid.width { grid[x, y] = body[x, y - 1] }
            }
            for x in 0..<MascotGrid.width { grid[x, 0] = nil }
            return (avatar, grid)
        })
}
