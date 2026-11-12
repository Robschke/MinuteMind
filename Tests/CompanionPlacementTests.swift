// Purpose: Tests for the desktop companion's geometry: start position, staying on screen, the
//          remembered position per display, the side popups open to, and fanned-out windows.
// Dependencies: Sources/App/Supporting/CompanionPlacement.swift

import CoreGraphics
import Testing

@testable import MinuteMindApp

@Suite("CompanionPlacement Tests")
@MainActor
struct CompanionPlacementTests {
    private let visible = CGRect(x: 0, y: 80, width: 1440, height: 820)
    private let insets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) = (16, 20, 24, 20)

    @Test("Starts on the right edge in the lower third, fully on screen")
    func defaultPosition() {
        let origin = CompanionPlacement.defaultOrigin(in: visible)
        let creature = CompanionPlacement.creatureRect(panelOrigin: origin)
        #expect(creature.maxX == visible.maxX - 12)
        #expect(creature.minY == visible.minY + visible.height * 0.25)
        #expect(CompanionPlacement.clamped(origin, in: visible) == origin)
    }

    @Test("A drop near an edge snaps onto it, a drop in the middle stays")
    func snapping() {
        let nearRight = CompanionPlacement.snapped(CGPoint(x: visible.maxX - 18 - 36 - 8, y: 400), in: visible)
        #expect(CompanionPlacement.creatureRect(panelOrigin: nearRight).maxX == visible.maxX)
        let nearBottom = CompanionPlacement.snapped(CGPoint(x: 500, y: visible.minY + 5), in: visible)
        #expect(nearBottom.y == visible.minY)
        let middle = CGPoint(x: 600, y: 400)
        #expect(CompanionPlacement.snapped(middle, in: visible) == middle)
    }

    @Test("A drop outside the screen keeps the creature itself visible")
    func clamping() {
        let far = CompanionPlacement.clamped(CGPoint(x: 5000, y: -300), in: visible)
        let creature = CompanionPlacement.creatureRect(panelOrigin: far)
        #expect(creature.maxX == visible.maxX)
        #expect(creature.minY == visible.minY)
        let left = CompanionPlacement.creatureRect(panelOrigin: CompanionPlacement.clamped(CGPoint(x: -500, y: 300), in: visible))
        #expect(left.minX == visible.minX)
    }

    @Test("The stored relative position comes back on a resized display in the same spot")
    func relativeRoundTrip() {
        let origin = CGPoint(x: 700, y: 400)
        let relative = CompanionPlacement.relative(origin, in: visible)
        #expect(abs(CompanionPlacement.absolute(relative, in: visible).x - origin.x) < 0.001)
        #expect(abs(CompanionPlacement.absolute(relative, in: visible).y - origin.y) < 0.001)
        let bigger = CGRect(x: 0, y: 0, width: 2560, height: 1400)
        let corner = CompanionPlacement.relative(CGPoint(x: visible.maxX - 54, y: visible.minY), in: visible)
        let moved = CompanionPlacement.creatureRect(panelOrigin: CompanionPlacement.absolute(corner, in: bigger))
        #expect(moved.maxX == bigger.maxX && moved.minY == bigger.minY)
    }

    @Test("Popups open towards the roomier side and centre on the creature")
    func popupSide() {
        let rightCreature = CGRect(x: 1300, y: 400, width: 36, height: 48)
        let size = CGSize(width: 300, height: 92)
        let left = CompanionPlacement.popupOrigin(creature: rightCreature, popupSize: size, insets: insets, in: visible)
        #expect(left.x + size.width - insets.trailing == rightCreature.minX - CompanionPlacement.gap)
        let contentMidY = left.y + insets.bottom + (size.height - insets.top - insets.bottom) / 2
        #expect(contentMidY == rightCreature.midY)

        let leftCreature = CGRect(x: 100, y: 400, width: 36, height: 48)
        let right = CompanionPlacement.popupOrigin(creature: leftCreature, popupSize: size, insets: insets, in: visible)
        #expect(right.x + insets.leading == leftCreature.maxX + CompanionPlacement.gap)
    }

    @Test("A popup next to a creature at the bottom edge stays on screen")
    func popupStaysOnScreen() {
        let creature = CGRect(x: 1300, y: visible.minY, width: 36, height: 48)
        let size = CGSize(width: 300, height: 200)
        let origin = CompanionPlacement.popupOrigin(creature: creature, popupSize: size, insets: insets, in: visible)
        #expect(origin.y + insets.bottom >= visible.minY)
    }

    @Test("Summoned windows sit beside the creature, stepped, inside the screen")
    func fannedWindows() {
        let creature = CGRect(x: 1300, y: 400, width: 36, height: 48)
        let frames = CompanionPlacement.fannedFrames(
            for: [CGSize(width: 760, height: 620), CGSize(width: 900, height: 2000)], creature: creature, in: visible)
        #expect(frames.count == 2)
        #expect(frames[0].maxX == creature.minX - CompanionPlacement.gap)
        #expect(frames[1].height <= visible.height * 0.9)
        for frame in frames {
            #expect(visible.contains(frame))
        }
        #expect(frames[1].minX < frames[0].minX)
    }

    @Test("Called by a shake it lands beside the pointer, never on it, and stays on screen")
    func landsBesidePointer() {
        let middle = CGPoint(x: 700, y: 500)
        let creature = CompanionPlacement.creatureRect(panelOrigin: CompanionPlacement.originNear(pointer: middle, in: visible))
        #expect(creature.minX > middle.x && creature.maxY < middle.y)
        #expect(!creature.contains(middle))

        let corner = CGPoint(x: visible.maxX - 5, y: visible.minY + 5)
        let cornered = CompanionPlacement.creatureRect(panelOrigin: CompanionPlacement.originNear(pointer: corner, in: visible))
        #expect(cornered.maxX < corner.x && cornered.minY > corner.y)
        #expect(visible.contains(cornered))
    }

    @Test("Docked it sits inside the window's bottom right corner; a drop nearby docks it")
    func docking() {
        let window = CGRect(x: 200, y: 150, width: 1100, height: 700)
        let origin = CompanionPlacement.dockedOrigin(in: window)
        let creature = CompanionPlacement.creatureRect(panelOrigin: origin)
        #expect(window.contains(creature))
        #expect(creature.maxX == window.maxX - 14 && creature.minY == window.minY + 12)
        #expect(CompanionPlacement.isNearDock(CGPoint(x: origin.x - 20, y: origin.y + 20), windowFrame: window))
        #expect(!CompanionPlacement.isNearDock(CGPoint(x: origin.x - 200, y: origin.y), windowFrame: window))
    }
}
