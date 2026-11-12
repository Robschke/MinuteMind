// Purpose: Tests for CalendarService.fetchEventsGroupedByDay date-grouping logic (CAL-01).
// Dependencies: Sources/App/Services/CalendarService.swift (CalendarEvent model, grouping logic)
// Notes: Tests grouping logic in isolation — no EKEventStore calls. RED state until Plan 02
//        extends CalendarService with the grouping helper method exposed for testing.

import Foundation
import Testing
@testable import MinuteMindApp

@Suite("Calendar Service Tests")
struct CalendarServiceTests {

    // MARK: - Grouping Logic Tests (CAL-01)

    @Test("fetchEventsGroupedByDay groups events by calendar day")
    func testGroupedByDayReturnsTodayFirst() throws {
        guard ProcessInfo.processInfo.environment["SKIP_CALENDAR_TESTS"] == nil else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let todayEvent = CalendarEvent(
            id: "evt-today",
            title: "Today's Meeting",
            startDate: today.addingTimeInterval(3600),     // 1 hour into today
            endDate: today.addingTimeInterval(7200)        // 2 hours into today
        )

        let tomorrowEvent = CalendarEvent(
            id: "evt-tomorrow",
            title: "Tomorrow's Meeting",
            startDate: tomorrow.addingTimeInterval(3600),
            endDate: tomorrow.addingTimeInterval(7200)
        )

        let events = [todayEvent, tomorrowEvent]

        // Test the grouping helper in isolation — not the EKEventStore call.
        // groupEventsByDay(_:) is a static/free helper that Plan 02 will expose.
        let grouped = CalendarService.groupEventsByDay(events)

        // Assert today's key exists and contains todayEvent
        let todayKey = calendar.startOfDay(for: todayEvent.startDate)
        let tomorrowKey = calendar.startOfDay(for: tomorrowEvent.startDate)

        #expect(grouped[todayKey] != nil)
        #expect(grouped[tomorrowKey] != nil)
        #expect(grouped[todayKey]?.first?.id == "evt-today")
        #expect(grouped[tomorrowKey]?.first?.id == "evt-tomorrow")

        // First key in sorted order should be today (not tomorrow)
        let sortedKeys = grouped.keys.sorted()
        #expect(sortedKeys.first == todayKey)
    }
}
