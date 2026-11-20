// Purpose: MascotAvatar, one creature the desktop companion or a project can be, as data: an id,
//          a name, its kind (how it is drawn), a 12 x 13 pixel body, its colours and its neutral
//          mouth. The built-in ones (blob, duck, dog, puppy, pug, three cats, lime) are static
//          instances; the moods (eyes, mouths, arms, headphones, laptop, bubbles) are shared.
// Dependencies: Sources/App/Supporting/AssistantMascotPose.swift (MascotGrid, MascotInk)
// Used by: Sources/App/Supporting/MascotAvatarCatalog.swift (lists and resolves them),
//          Sources/App/Supporting/AssistantMascotPose.swift (bodies and traits),
//          Sources/App/Supporting/CreatureRenderer.swift (picks the renderer by kind),
//          Sources/App/Supporting/CompanionAppearance.swift (the chosen one, colours),
//          Sources/App/Views/CreatureView.swift (colours), Sources/App/Models/Project.swift
// Notes: - The id is what projects and settings store. The built-in ids never change, or stored
//          choices would fall back to the Blob.
//        - Every body keeps the face where the blob has it (eyes at x 4 and 7 in rows 5 to 8,
//          mouth in rows 9 and 10, cheeks at (2,8) and (9,8), head top in row 1), so every mood
//          works for every creature without per-creature poses.
//        - Character lives in the body and one feature colour: the duck's dark cowlick, flat wide
//          bill and feet (a pointed beak and orange tuft read as a chick); the dog's ears, black
//          nose and lopsided grin; the lime's leaf lying on the fruit (a stem read as an apple).
//          The pug is drawn from the front like all the others, since they share the face layout.
//          The cat has no whiskers (beside the tail they read as extra legs) and a small forehead
//          patch (stripes above the eyes made it look grumpy).
//        - The traits are built-in only. The Cool Cat wears its shades over whatever eyes the
//          mood has and pushes them up onto its forehead when it waits, errs or sleeps, so those
//          eyes show (with the shades down its error face was its idle face); the glint sits in
//          the same corner of each lens (centred glints read as pupils). The Sweet Cat rests its
//          eyes half closed while idle (open on hover and in every other mood; flat lines would
//          read as asleep) and now and then a pink heart rises beside its head (a steady red
//          heart in the bubble's place read as the error bubble). The lime has no arms.
//        - Natural colours (yellow duck, tan dog, orange puppy, fawn pug, orange cats, yellow
//          Sweet Cat, green lime); the blob takes the theme accent. An own colour from Settings
//          recolours the body only, never the feature colour.
//        - `kind` says which renderer draws the avatar (CreatureRenderer): `pixel` (the grids
//          below) or `svg` (drawings in any style, `art`, SVGAvatarArt). The grids are built once
//          per avatar, since frames are sampled many times a second.

import Foundation

struct MascotAvatar: Identifiable, Hashable, Sendable, CustomStringConvertible {
    /// How an avatar is drawn.
    enum Kind: String, Sendable, CaseIterable {
        /// A 12 x 13 grid of inks, the moods painted over it (AssistantMascotPose).
        case pixel
        /// Drawings in any style (SVGAvatarArt), animated and propped by SVGCreatureRenderer.
        case svg
    }

    /// What projects and settings store.
    let id: String
    let name: String
    let kind: Kind

    /// The body at rest, 13 rows of 12 characters: o outline, b body, h shine, c pink,
    /// e near-black, f feature colour, anything else empty.
    let rows: [String]
    /// The body colour without an own colour; nil = the theme's accent.
    let naturalBody: UInt32?
    /// Beak and feet, ears, stem and leaf ("f" in the rows).
    let featureColor: UInt32
    /// The mouth when the mood has nothing to say (empty: the body already draws it, as the
    /// duck's bill and the Sweet Cat's nose do).
    let neutralMouth: [(Int, Int)]

    /// The side nubs (arms at rest); waving and laptop hands replace them.
    let nubs: [(Int, Int)]
    /// Sunglasses over the eyes in every mood (the pose paints them last).
    let wearsShades: Bool
    /// Idle with half closed eyes and now and then a heart beside the head.
    let isContent: Bool
    /// The drawings of an avatar of kind svg; nil for pixel avatars.
    let art: SVGAvatarArt?
    /// The hash of `art`, taken once: SVGAvatarImageCache keys its bitmaps with it on every draw.
    let artHash: Int

    let body: MascotGrid
    /// Breathing out: everything above the face sinks one row (row 4 drops out).
    let squashed: MascotGrid

    init(
        id: String, name: String, kind: Kind = .pixel, rows: [String], naturalBody: UInt32?,
        featureColor: UInt32, neutralMouth: [(Int, Int)], hasArms: Bool = true,
        wearsShades: Bool = false, isContent: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rows = rows
        self.naturalBody = naturalBody
        self.featureColor = featureColor
        self.neutralMouth = neutralMouth
        self.nubs = hasArms ? [(0, 8), (11, 8)] : []
        self.wearsShades = wearsShades
        self.isContent = isContent
        self.art = nil
        self.artHash = 0
        let body = MascotGrid(rows: rows)
        var squashed = body
        for y in stride(from: 4, through: 1, by: -1) {
            for x in 0..<MascotGrid.width { squashed[x, y] = body[x, y - 1] }
        }
        for x in 0..<MascotGrid.width { squashed[x, 0] = nil }
        self.body = body
        self.squashed = squashed
    }

    /// An avatar of kind svg. The pixel fields hold the Blob's, which nothing draws; they keep
    /// code that reads them (colours, the validator's face zones) working for every kind.
    init(id: String, name: String, art: SVGAvatarArt, naturalBody: UInt32?) {
        self.id = id
        self.name = name
        self.kind = .svg
        self.rows = MascotAvatar.blob.rows
        self.naturalBody = naturalBody
        self.featureColor = 0x000000
        self.neutralMouth = []
        self.nubs = []
        self.wearsShades = false
        self.isContent = false
        self.art = art
        self.artHash = art.hashValue
        self.body = MascotAvatar.blob.body
        self.squashed = MascotAvatar.blob.squashed
    }

    var description: String { id }

    /// Two avatars are the same when they are drawn the same; the grids follow from the rows.
    static func == (a: MascotAvatar, b: MascotAvatar) -> Bool {
        a.id == b.id && a.name == b.name && a.kind == b.kind && a.rows == b.rows
            && a.naturalBody == b.naturalBody && a.featureColor == b.featureColor
            && a.neutralMouth.elementsEqual(b.neutralMouth, by: ==) && a.nubs.elementsEqual(b.nubs, by: ==)
            && a.wearsShades == b.wearsShades && a.isContent == b.isContent && a.art == b.art
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - The built-in avatars

extension MascotAvatar {
    /// The original: a round body in the theme accent, two pixels of mouth.
    static let blob = MascotAvatar(
        id: "blob",
        name: "Blob",
        rows: [
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
        ],
        naturalBody: nil,
        featureColor: 0x000000,
        neutralMouth: [(5, 9), (6, 9)])

    /// A dark cowlick, a flat wide bill (its mouth) and orange feet.
    static let duck = MascotAvatar(
        id: "duck",
        name: "Duck",
        rows: [
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
        ],
        naturalBody: 0xFFD43B,
        featureColor: 0xFF8A1F,
        neutralMouth: [])

    /// A floppy left ear, a perked right one, a black nose, a lopsided grin with the tongue out.
    static let dog = MascotAvatar(
        id: "dog",
        name: "Dog",
        rows: [
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
        ],
        naturalBody: 0xC98B4E,
        featureColor: 0x7A4A24,
        neutralMouth: [(4, 9), (5, 10), (7, 9)])

    /// Sitting, the left ear flipped up, the right folded down, a "u" smile under the nose, a little tail.
    static let puppy = MascotAvatar(
        id: "puppy",
        name: "Puppy",
        rows: [
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
        ],
        naturalBody: 0xF2A65A,
        featureColor: 0xC8702A,
        neutralMouth: [(4, 9), (5, 10), (6, 10), (7, 9)])

    /// Dark folded ears, a dark forehead mark and muzzle with jowls, a flat mouth above the tongue.
    static let pug = MascotAvatar(
        id: "pug",
        name: "Pug",
        rows: [
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
        ],
        naturalBody: 0xEDCB98,
        featureColor: 0x6B4128,
        neutralMouth: [(4, 9), (5, 9), (6, 9), (7, 9)])

    /// Triangular ears with pink insides, a small forehead patch, a pink nose over a "u" smile, a tail curling up.
    static let cat = MascotAvatar(
        id: "cat",
        name: "Cat",
        rows: [
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
        ],
        naturalBody: 0xF5A65B,
        featureColor: 0xC8702A,
        neutralMouth: [(4, 9), (5, 10), (6, 10), (7, 9)])

    /// Sunglasses over whatever eyes the mood has, light ear insides, a sideways smirk.
    static let coolCat = MascotAvatar(
        id: "coolCat",
        name: "Cool Cat",
        rows: [
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
        ],
        naturalBody: 0xEE8A2E,
        featureColor: 0xB4531A,
        neutralMouth: [(5, 10), (6, 10), (7, 9)],
        wearsShades: true)

    /// An orange patch, orange ear insides and nose (all the mouth it needs), eyes half closed while idle.
    static let sweetCat = MascotAvatar(
        id: "sweetCat",
        name: "Sweet Cat",
        rows: [
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
        ],
        naturalBody: 0xF7C948,
        featureColor: 0xE8892B,
        neutralMouth: [],
        isContent: true)

    /// A citrus leaf lying on the fruit, no arms, one pixel legs and a sour squiggle of a mouth.
    static let lime = MascotAvatar(
        id: "lime",
        name: "Lime",
        rows: [
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
        ],
        naturalBody: 0x9CCB3B,
        featureColor: 0x3F7D1C,
        neutralMouth: [(4, 10), (5, 9), (6, 10), (7, 9)],
        hasArms: false)
}
