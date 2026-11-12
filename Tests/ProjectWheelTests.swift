// Purpose: Tests for ProjectWheel: wheel notches step once each, trackpad deltas add up to steps,
//          momentum is ignored, the list wraps, and the selection starts at the current project.
// Dependencies: Sources/App/Supporting/ProjectWheel.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("ProjectWheel Tests")
struct ProjectWheelTests {
    private let acme = UUID()
    private let beta = UUID()

    private var wheel: ProjectWheel {
        ProjectWheel(
            items: [.init(projectID: nil, name: "No Project"), .init(projectID: acme, name: "Acme"), .init(projectID: beta, name: "Beta")],
            selected: acme)
    }

    /// #expect cannot call a mutating method inside its macro.
    private func step(_ wheel: inout ProjectWheel, deltaY: CGFloat, precise: Bool, momentum: Bool, began: Bool = false) -> Bool {
        wheel.scroll(deltaY: deltaY, precise: precise, momentum: momentum, began: began)
    }

    @Test func startsAtTheCurrentProject() {
        #expect(wheel.selected?.name == "Acme")
        #expect(ProjectWheel(items: wheel.items, selected: UUID()).selected?.name == "No Project")
    }

    @Test func eachWheelNotchIsOneStepWhateverItsSize() {
        var wheel = self.wheel
        #expect(step(&wheel, deltaY: -9, precise: false, momentum: false))
        #expect(wheel.selected?.name == "Beta")
        #expect(step(&wheel, deltaY: 0.3, precise: false, momentum: false))
        #expect(wheel.selected?.name == "Acme")
    }

    @Test func trackpadDeltasAddUpToSteps() {
        var wheel = self.wheel
        #expect(!step(&wheel, deltaY: -10, precise: true, momentum: false, began: true))
        #expect(!step(&wheel, deltaY: -10, precise: true, momentum: false))
        #expect(step(&wheel, deltaY: -10, precise: true, momentum: false))
        #expect(wheel.selected?.name == "Beta")
        // A long swipe moves several rows at once.
        #expect(step(&wheel, deltaY: -60, precise: true, momentum: false))
        #expect(wheel.selected?.name == "Acme")
    }

    @Test func momentumIsIgnored() {
        var wheel = self.wheel
        #expect(!step(&wheel, deltaY: -200, precise: true, momentum: true))
        #expect(wheel.selected?.name == "Acme")
    }

    @Test func theListWrapsAround() {
        var wheel = self.wheel
        _ = wheel.scroll(deltaY: -1, precise: false, momentum: false)
        _ = wheel.scroll(deltaY: -1, precise: false, momentum: false)
        #expect(wheel.selected?.name == "No Project")
        _ = wheel.scroll(deltaY: 1, precise: false, momentum: false)
        #expect(wheel.selected?.name == "Beta")
    }

    @Test func aClickJumpsAndTheStartStaysKnown() {
        var wheel = self.wheel
        wheel.select(2)
        #expect(wheel.selected?.name == "Beta")
        #expect(wheel.startIndex == 1)
        wheel.select(9)
        #expect(wheel.selected?.name == "Beta")
    }

    @Test func anUnfiledRecordingStartsAtLaterOnTheSavedCard() {
        let items: [ProjectWheel.Item] = [
            .init(projectID: acme, name: "Acme", isStarred: true), .init(projectID: beta, name: "Beta"),
            .init(projectID: nil, name: "Later", isLater: true),
        ]
        var wheel = ProjectWheel(items: items, selected: nil)
        #expect(wheel.selected?.isLater == true)
        // One step down wraps to the first starred project.
        _ = wheel.scroll(deltaY: -1, precise: false, momentum: false)
        #expect(wheel.selected?.name == "Acme")
    }
}
