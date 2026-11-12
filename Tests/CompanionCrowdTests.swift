// Purpose: Tests for the huddle of small project creatures behind the desktop companion: where
//          each stands, the squeeze at a screen edge, the big creature's step-in, hit testing and
//          the neighbours' glances.
// Dependencies: Sources/App/Supporting/CompanionCrowd.swift

import CoreGraphics
import Testing

@testable import MinuteMindApp

@Suite("CompanionCrowd Tests")
struct CompanionCrowdTests {
    /// The big creature at 3 pt pixels (36 x 48), sidekicks at 2 pt (24 x 32).
    private let creature = CGRect(x: 1000, y: 200, width: 36, height: 48)
    private let pixel: CGFloat = 2

    @Test("Relaxed huddle on the right: front row on the ground, back row raised between it")
    func relaxedRight() {
        let layout = CompanionCrowd.layout(
            count: 5, creature: creature, pixel: pixel, outwardRight: true, room: 1000, allowsStepIn: true)
        #expect(layout.stepIn == 0)
        let xs = layout.slots.map(\.minX)
        // The nearest is tucked 2 pixels behind the big one's side; 2 pixel gaps in the front row.
        #expect(xs == [1032, 1046, 1060, 1074, 1088])
        #expect(layout.slots.map(\.minY) == [200, 210, 200, 210, 200])
        #expect(layout.slots.allSatisfy { $0.size == CGSize(width: 24, height: 32) })
    }

    @Test("On the left the huddle is mirrored")
    func relaxedLeft() {
        let layout = CompanionCrowd.layout(
            count: 3, creature: creature, pixel: pixel, outwardRight: false, room: 1000, allowsStepIn: true)
        #expect(layout.slots.map(\.maxX) == [1004, 990, 976])
        #expect(layout.slots.allSatisfy { $0.maxX > creature.minX - 200 })
    }

    @Test("Short of room it squeezes and stays inside the edge without stepping in")
    func squeezes() {
        let relaxed = CompanionCrowd.extent(count: 5, squeeze: 0, pixel: pixel)
        let tight = CompanionCrowd.extent(count: 5, squeeze: 1, pixel: pixel)
        let room = (relaxed + tight) / 2
        let layout = CompanionCrowd.layout(
            count: 5, creature: creature, pixel: pixel, outwardRight: true, room: room, allowsStepIn: true)
        #expect(layout.stepIn == 0)
        #expect(layout.frame.maxX <= creature.maxX + room + 1)
        #expect(layout.frame.maxX > creature.maxX + tight - 1)
    }

    @Test("Flush at the edge the big creature steps in just enough for the tightest huddle")
    func stepsIn() {
        let tight = CompanionCrowd.extent(count: 5, squeeze: 1, pixel: pixel)
        let layout = CompanionCrowd.layout(
            count: 5, creature: creature, pixel: pixel, outwardRight: true, room: 0, allowsStepIn: true)
        #expect(layout.stepIn == tight)
        #expect(layout.frame.maxX == creature.maxX)
        // Every one keeps at least half its width outside the big creature's new place.
        let bigMaxX = creature.maxX - layout.stepIn
        let fronts = layout.slots.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        #expect(fronts.allSatisfy { $0.maxX - bigMaxX >= $0.width / 2 })
    }

    @Test("Without step-in (docked or dragged) the tight huddle hangs over instead")
    func noStepIn() {
        let layout = CompanionCrowd.layout(
            count: 5, creature: creature, pixel: pixel, outwardRight: true, room: 0, allowsStepIn: false)
        #expect(layout.stepIn == 0)
        #expect(layout.frame.maxX > creature.maxX)
    }

    @Test("Draw order: back row first, nearest of each row last; hits find the one on top")
    func drawingAndHits() {
        #expect(CompanionCrowd.drawOrder(count: 5) == [3, 1, 4, 2, 0])
        #expect(CompanionCrowd.drawOrder(count: 0).isEmpty)
        let slots = CompanionCrowd.layout(
            count: 3, creature: .zero, pixel: 2, outwardRight: true, room: 1000, allowsStepIn: true).slots
        // Where front 0 and back 1 overlap, the front one is on top.
        let overlap = CGPoint(x: slots[1].minX + 2, y: slots[1].minY + 2)
        #expect(CompanionCrowd.index(at: overlap, slots: slots) == 0)
        // Above the front row only the raised back one is there.
        #expect(CompanionCrowd.index(at: CGPoint(x: slots[1].midX, y: slots[1].maxY - 1), slots: slots) == 1)
        #expect(CompanionCrowd.index(at: CGPoint(x: -500, y: 0), slots: slots) == nil)
    }

    @Test("Glances come in pairs that face each other, or the nearest looks up at the big one")
    func glances() {
        var sawPair = false
        var sawLookUp = false
        for beat in 0..<200 {
            let time = Double(beat) * CompanionCrowd.beat + CompanionCrowd.glanceStart + 0.5
            let looks = (0..<4).map { CompanionCrowd.glance(index: $0, count: 4, outwardRight: true, time: time) }
            let active = looks.enumerated().compactMap { index, look in look.map { (index, $0) } }
            if active.count == 1 {
                // The nearest, looking inward (left) and up.
                #expect(active[0].0 == 0)
                #expect(active[0].1.x == -1 && active[0].1.y == -1)
                sawLookUp = true
            } else if active.count == 2 {
                let (inner, outer) = (active[0], active[1])
                #expect(outer.0 == inner.0 + 1)
                #expect(inner.1.x == 1 && outer.1.x == -1)
                #expect(inner.1.y == -outer.1.y)
                sawPair = true
            } else {
                #expect(active.isEmpty)
            }
            // Outside the glance window nobody is steered.
            let quiet = Double(beat) * CompanionCrowd.beat + 0.2
            #expect((0..<4).allSatisfy { CompanionCrowd.glance(index: $0, count: 4, outwardRight: true, time: quiet) == nil })
        }
        #expect(sawPair && sawLookUp)
    }
}
