// Purpose: JobSchedule, when a scheduled job runs (hourly in a window, daily, weekly, each limited
//          to weekdays) and the calendar math the scheduler needs: the latest slot before a moment,
//          the next one after it, and whether a job is due.
// Dependencies: Foundation (Calendar) only.
// RBAC: None.
// Dependents: Sources/App/Models/ScheduledJob.swift, Sources/App/Store/ScheduledJobFiles.swift,
//             Sources/App/Supporting/ScheduledJobStore.swift (due check, next run),
//             Sources/App/Views/ScheduledJobEditorView.swift, Sources/App/Services/MCP/MCPJobTools.swift
// Notes: A missed slot is caught up exactly once: `dueSlot` only ever looks at the latest slot
//        before now, so a Mac that slept through several slots runs the job one time. Slots
//        before `activeSince` never count, so creating, enabling or rescheduling a job does not
//        fire it for a time that already passed.
//        Hourly runs start at `time` and repeat every full hour up to and including `until`.
//        Weekly ignores `days` and uses `weekday`. Empty `days` mean every day.

import Foundation

enum JobWeekday: Int, CaseIterable, Codable, Comparable, Sendable {
    // Calendar weekday numbers (Gregorian: 1 = Sunday).
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    /// Monday first, the order the UI shows.
    static let weekOrder: [JobWeekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
    static let workdays: Set<JobWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    /// Three-letter code used in job files and over MCP.
    var code: String {
        switch self {
        case .monday: return "mon"
        case .tuesday: return "tue"
        case .wednesday: return "wed"
        case .thursday: return "thu"
        case .friday: return "fri"
        case .saturday: return "sat"
        case .sunday: return "sun"
        }
    }

    var shortName: String {
        switch self {
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        case .sunday: return "Sun"
        }
    }

    var name: String {
        switch self {
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        case .sunday: return "Sunday"
        }
    }

    init?(code: String) {
        let key = code.trimmingCharacters(in: .whitespaces).lowercased().prefix(3)
        guard let match = Self.allCases.first(where: { $0.code == key }) else { return nil }
        self = match
    }

    static func < (lhs: JobWeekday, rhs: JobWeekday) -> Bool {
        (weekOrder.firstIndex(of: lhs) ?? 0) < (weekOrder.firstIndex(of: rhs) ?? 0)
    }
}

/// A time of day, minute precision.
struct JobTime: Equatable, Comparable, Codable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// Parses "8:00", "08:00" or "0800".
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        let parts = trimmed.split(separator: ":")
        let hourText: Substring
        let minuteText: Substring
        if parts.count == 2 {
            hourText = parts[0]; minuteText = parts[1]
        } else if parts.count == 1, trimmed.count == 4 {
            hourText = trimmed.prefix(2); minuteText = trimmed.suffix(2)
        } else {
            return nil
        }
        guard let hour = Int(hourText), let minute = Int(minuteText),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    var text: String { String(format: "%02d:%02d", hour, minute) }
    var minutesOfDay: Int { hour * 60 + minute }

    static func < (lhs: JobTime, rhs: JobTime) -> Bool { lhs.minutesOfDay < rhs.minutesOfDay }
}

struct JobSchedule: Equatable, Sendable {
    enum Cadence: String, CaseIterable, Codable, Sendable {
        case hourly, daily, weekly

        var label: String {
            switch self {
            case .hourly: return "Hourly"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            }
        }
    }

    var cadence: Cadence = .daily
    /// Daily and weekly: the run time. Hourly: the first run of the day.
    var time = JobTime(hour: 8, minute: 0)
    /// Hourly only: the last run of the day (inclusive).
    var until = JobTime(hour: 18, minute: 0)
    /// Hourly and daily: the weekdays it runs on; empty means every day.
    var days: Set<JobWeekday> = JobWeekday.workdays
    /// Weekly only.
    var weekday: JobWeekday = .monday

    // MARK: - Slots

    /// The run times on the day that contains `day`, ascending.
    func slots(onDayOf day: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: day)
        guard let weekdayNumber = Optional(calendar.component(.weekday, from: start)),
              let dayOfWeek = JobWeekday(rawValue: weekdayNumber) else { return [] }
        let times: [JobTime]
        switch cadence {
        case .weekly:
            times = dayOfWeek == weekday ? [time] : []
        case .daily:
            times = runsOn(dayOfWeek) ? [time] : []
        case .hourly:
            guard runsOn(dayOfWeek) else { return [] }
            var list = [time]
            var next = time.hour + 1
            while next <= 23, JobTime(hour: next, minute: time.minute) <= until {
                list.append(JobTime(hour: next, minute: time.minute))
                next += 1
            }
            times = list
        }
        return times.compactMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: start) }
    }

    private func runsOn(_ day: JobWeekday) -> Bool { days.isEmpty || days.contains(day) }

    /// The latest run time at or before `date`, looking back at most 8 days.
    func lastSlot(atOrBefore date: Date, calendar: Calendar = .current) -> Date? {
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            if let slot = slots(onDayOf: day, calendar: calendar).last(where: { $0 <= date }) { return slot }
        }
        return nil
    }

    /// The first run time strictly after `date`, looking ahead at most 8 days.
    func nextSlot(after date: Date, calendar: Calendar = .current) -> Date? {
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            if let slot = slots(onDayOf: day, calendar: calendar).first(where: { $0 > date }) { return slot }
        }
        return nil
    }

    /// The slot a job should run for now, or nil. `lastScheduled` is the slot of its latest
    /// scheduled run; slots before `activeSince` never count.
    func dueSlot(now: Date, activeSince: Date, lastScheduled: Date?, calendar: Calendar = .current) -> Date? {
        guard let slot = lastSlot(atOrBefore: now, calendar: calendar), slot >= activeSince else { return nil }
        if let lastScheduled, slot <= lastScheduled { return nil }
        return slot
    }

    // MARK: - Description

    /// "Daily at 08:00, Mon to Fri" and the like.
    var summary: String {
        switch cadence {
        case .weekly:
            return "Weekly on \(weekday.name) at \(time.text)"
        case .daily:
            return "Daily at \(time.text)\(daysSuffix)"
        case .hourly:
            return "Hourly \(time.text) to \(until.text)\(daysSuffix)"
        }
    }

    private var daysSuffix: String {
        if days.isEmpty || days.count == 7 { return "" }
        if days == JobWeekday.workdays { return ", Mon to Fri" }
        if days == [.saturday, .sunday] { return ", weekends" }
        return ", " + days.sorted().map(\.shortName).joined(separator: " ")
    }
}
