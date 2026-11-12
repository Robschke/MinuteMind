// Purpose: Tests for the scheduled jobs' calendar math: slots per cadence and weekday, the latest
//          and next slot, and the due rule (one catch-up, nothing before activeSince).
// Dependencies: Sources/App/Models/JobSchedule.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("JobSchedule Tests")
struct JobScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// 2026-11-12 is a Thursday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("Times parse in the usual spellings and reject nonsense")
    func timeParsing() {
        #expect(JobTime("08:00") == JobTime(hour: 8, minute: 0))
        #expect(JobTime("8:05") == JobTime(hour: 8, minute: 5))
        #expect(JobTime("\"17:30\"") == JobTime(hour: 17, minute: 30))
        #expect(JobTime("0730") == JobTime(hour: 7, minute: 30))
        #expect(JobTime("25:00") == nil)
        #expect(JobTime("soon") == nil)
    }

    @Test("Daily runs once on the chosen weekdays only")
    func dailySlots() {
        var schedule = JobSchedule(cadence: .daily, time: JobTime(hour: 8, minute: 0))
        schedule.days = JobWeekday.workdays
        #expect(schedule.slots(onDayOf: date(12, 12), calendar: calendar) == [date(12, 8)])
        #expect(schedule.slots(onDayOf: date(14, 12), calendar: calendar).isEmpty)  // Saturday
        schedule.days = []
        #expect(schedule.slots(onDayOf: date(14, 12), calendar: calendar) == [date(14, 8)])
    }

    @Test("Hourly runs every full hour from start to end, inclusive")
    func hourlySlots() {
        let schedule = JobSchedule(cadence: .hourly, time: JobTime(hour: 8, minute: 15), until: JobTime(hour: 11, minute: 0), days: [])
        #expect(schedule.slots(onDayOf: date(12, 0), calendar: calendar)
            == [date(12, 8, 15), date(12, 9, 15), date(12, 10, 15)])
        let single = JobSchedule(cadence: .hourly, time: JobTime(hour: 9, minute: 0), until: JobTime(hour: 7, minute: 0), days: [])
        #expect(single.slots(onDayOf: date(12, 0), calendar: calendar) == [date(12, 9)])
    }

    @Test("Weekly runs on its weekday and ignores the day set")
    func weeklySlots() {
        let schedule = JobSchedule(cadence: .weekly, time: JobTime(hour: 7, minute: 30), days: [.sunday], weekday: .monday)
        #expect(schedule.slots(onDayOf: date(16, 0), calendar: calendar) == [date(16, 7, 30)])
        #expect(schedule.slots(onDayOf: date(15, 0), calendar: calendar).isEmpty)
    }

    @Test("Last and next slot skip days without runs")
    func lastAndNext() {
        let schedule = JobSchedule(cadence: .daily, time: JobTime(hour: 8, minute: 0), days: JobWeekday.workdays)
        // Saturday noon: the last run was Friday 08:00, the next is Monday 08:00.
        #expect(schedule.lastSlot(atOrBefore: date(14, 12), calendar: calendar) == date(13, 8))
        #expect(schedule.nextSlot(after: date(14, 12), calendar: calendar) == date(16, 8))
        // Exactly on the slot: it counts as the last one, the next is tomorrow.
        #expect(schedule.lastSlot(atOrBefore: date(12, 8), calendar: calendar) == date(12, 8))
        #expect(schedule.nextSlot(after: date(12, 8), calendar: calendar) == date(13, 8))
    }

    @Test("A due slot fires once, and missed slots collapse into one catch-up")
    func dueRule() {
        let schedule = JobSchedule(cadence: .hourly, time: JobTime(hour: 8, minute: 0), until: JobTime(hour: 18, minute: 0), days: [])
        let since = date(10, 0)
        // Never ran: the latest slot is due.
        #expect(schedule.dueSlot(now: date(12, 9, 10), activeSince: since, lastScheduled: nil, calendar: calendar) == date(12, 9))
        // Ran for 09:00 already: nothing until 10:00.
        #expect(schedule.dueSlot(now: date(12, 9, 50), activeSince: since, lastScheduled: date(12, 9), calendar: calendar) == nil)
        // Slept from 09:00 to 14:30: only the 14:00 slot runs.
        #expect(schedule.dueSlot(now: date(12, 14, 30), activeSince: since, lastScheduled: date(12, 9), calendar: calendar) == date(12, 14))
    }

    @Test("Slots before activeSince never fire")
    func activeSince() {
        let schedule = JobSchedule(cadence: .daily, time: JobTime(hour: 8, minute: 0), days: [])
        // Created at 10:00: today's 08:00 is not due, tomorrow's is.
        #expect(schedule.dueSlot(now: date(12, 10, 1), activeSince: date(12, 10), lastScheduled: nil, calendar: calendar) == nil)
        #expect(schedule.dueSlot(now: date(13, 8, 0), activeSince: date(12, 10), lastScheduled: nil, calendar: calendar) == date(13, 8))
    }

    @Test("Summaries read like the schedule")
    func summaries() {
        #expect(JobSchedule(cadence: .daily, time: JobTime(hour: 8, minute: 0), days: JobWeekday.workdays).summary == "Daily at 08:00, Mon to Fri")
        #expect(JobSchedule(cadence: .daily, time: JobTime(hour: 8, minute: 0), days: []).summary == "Daily at 08:00")
        #expect(JobSchedule(cadence: .hourly, time: JobTime(hour: 9, minute: 0), until: JobTime(hour: 17, minute: 0), days: [.monday, .wednesday]).summary
            == "Hourly 09:00 to 17:00, Mon Wed")
        #expect(JobSchedule(cadence: .weekly, time: JobTime(hour: 7, minute: 0), weekday: .friday).summary == "Weekly on Friday at 07:00")
    }
}
