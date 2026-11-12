// Purpose: Tests for placing overlapping calendar events side by side in the week grid.
// Dependencies: Sources/App/Supporting/CalendarOverlapLayout.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("CalendarOverlapLayout Tests")
struct CalendarOverlapLayoutTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, _ startMinutes: Double, _ endMinutes: Double) -> CalendarOverlapLayout.Item {
        .init(id: id, start: base.addingTimeInterval(startMinutes * 60), end: base.addingTimeInterval(endMinutes * 60))
    }

    @Test("A lone event takes the full width")
    func loneEvent() {
        let slots = CalendarOverlapLayout.slots(for: [item("a", 0, 60)])
        #expect(slots["a"] == .init(column: 0, span: 1, columns: 1))
    }

    @Test("Back-to-back events do not share the width")
    func backToBack() {
        let slots = CalendarOverlapLayout.slots(for: [item("a", 0, 60), item("b", 60, 120)])
        #expect(slots["a"]?.columns == 1)
        #expect(slots["b"]?.columns == 1)
    }

    @Test("Two overlapping events stand side by side, the earlier one on the left")
    func twoOverlapping() {
        let slots = CalendarOverlapLayout.slots(for: [item("b", 30, 90), item("a", 0, 60)])
        #expect(slots["a"] == .init(column: 0, span: 1, columns: 2))
        #expect(slots["b"] == .init(column: 1, span: 1, columns: 2))
    }

    @Test("A chain of overlaps reuses a freed column and lines up in one cluster")
    func chain() {
        // a 9-10, b 9:30-11, c 10-11: c takes a's column once a has ended.
        let slots = CalendarOverlapLayout.slots(for: [item("a", 0, 60), item("b", 30, 120), item("c", 60, 120)])
        #expect(slots["a"] == .init(column: 0, span: 1, columns: 2))
        #expect(slots["b"] == .init(column: 1, span: 1, columns: 2))
        #expect(slots["c"] == .init(column: 0, span: 1, columns: 2))
    }

    @Test("An event widens over columns that stay free for its time")
    func widening() {
        // a 9-12 overlaps b 9-10 and c 9-10 (three columns); d 11-12 only overlaps a and spans two.
        let slots = CalendarOverlapLayout.slots(for: [
            item("a", 0, 180), item("b", 0, 60), item("c", 0, 60), item("d", 120, 180),
        ])
        #expect(slots["a"] == .init(column: 0, span: 1, columns: 3))
        #expect(slots["d"] == .init(column: 1, span: 2, columns: 3))
    }

    @Test("Short events overlap by their drawn height")
    func minimumDuration() {
        // a lasts 10 minutes but is drawn 22 minutes tall, so b at +15 minutes would be covered.
        let items = [item("a", 0, 10), item("b", 15, 60)]
        #expect(CalendarOverlapLayout.slots(for: items)["b"]?.columns == 1)
        #expect(CalendarOverlapLayout.slots(for: items, minimumDuration: 22 * 60)["b"]?.columns == 2)
    }

    @Test("Same start: the longer event goes left")
    func sameStart() {
        let slots = CalendarOverlapLayout.slots(for: [item("short", 0, 30), item("long", 0, 120)])
        #expect(slots["long"]?.column == 0)
        #expect(slots["short"]?.column == 1)
    }
}
