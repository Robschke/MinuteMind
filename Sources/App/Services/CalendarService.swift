// Purpose: CalendarService and CalendarEvent — EKEventStore wrapper + CalendarEvent value type.
// Dependencies: EventKit (EKEvent, EKEventStore, EKCalendar, EKParticipant)
// Used by: Sources/App/ViewModels/AppViewModel.swift (calendarService property),
//          Sources/App/Services/CalendarBlockerService.swift, AgentTools.swift
// Notes: CalendarEvent is a value type (struct) derived from EKEvent to decouple views from EventKit.
//        attendees field is populated from EKParticipant.name falling back to emailAddress.

import EventKit
import Foundation

/// Represents a calendar event for display/editing
struct CalendarEvent: Identifiable, Equatable {
    /// The current user's participation status for this event.
    enum ParticipantStatus: String, Codable {
        case accepted
        case declined
        case tentative
        case pending
        case unknown
    }

    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String?
    let location: String?
    let notes: String?
    let url: URL?
    /// Names (or email addresses) of meeting attendees, derived from EKParticipant.
    let attendees: [String]
    /// Shared identifier across all occurrences of a recurring event series
    /// (EKEvent.calendarItemExternalIdentifier). Nil for non-recurring events.
    let seriesId: String?
    /// True if this event belongs to a recurring series.
    let isRecurring: Bool
    /// The current user's acceptance status for this event.
    let participantStatus: ParticipantStatus

    /// The key used to look up project assignments: seriesId when recurring, id otherwise.
    var seriesKey: String { seriesId ?? id }

    init(from ekEvent: EKEvent) {
        self.id = ekEvent.eventIdentifier ?? UUID().uuidString
        self.title = ekEvent.title ?? "Untitled"
        self.startDate = ekEvent.startDate
        self.endDate = ekEvent.endDate
        self.isAllDay = ekEvent.isAllDay
        self.calendarTitle = ekEvent.calendar?.title
        self.location = ekEvent.location
        self.notes = ekEvent.notes
        self.url = ekEvent.url
        self.isRecurring = ekEvent.hasRecurrenceRules
        // calendarItemExternalIdentifier is nil for non-recurring events in some configurations;
        // only store it when the event actually has recurrence rules so single events don't
        // accidentally share a key with an unrelated event.
        self.seriesId = ekEvent.hasRecurrenceRules ? ekEvent.calendarItemExternalIdentifier : nil
        // EKParticipant.name is the display name; fall back to the mailto: URL for email address.
        self.attendees = ekEvent.attendees?.compactMap { participant -> String? in
            if let name = participant.name, !name.isEmpty { return name }
            let participantURL = participant.url
            if participantURL.scheme == "mailto" {
                // Strip "mailto:" prefix to get bare email address
                return participantURL.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            }
            return nil
        } ?? []

        // Derive current user's participation status from EKEvent attendees.
        if let currentUser = ekEvent.attendees?.first(where: { $0.isCurrentUser }) {
            switch currentUser.participantStatus {
            case .accepted: self.participantStatus = .accepted
            case .declined: self.participantStatus = .declined
            case .tentative: self.participantStatus = .tentative
            case .pending: self.participantStatus = .pending
            default: self.participantStatus = .unknown
            }
        } else {
            // No attendee list or organizer-only event — treat as accepted.
            self.participantStatus = .accepted
        }
    }

    init(
        id: String = UUID().uuidString, title: String, startDate: Date, endDate: Date,
        isAllDay: Bool = false, calendarTitle: String? = nil, location: String? = nil,
        notes: String? = nil, url: URL? = nil, attendees: [String] = [],
        seriesId: String? = nil, isRecurring: Bool = false,
        participantStatus: ParticipantStatus = .accepted
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.location = location
        self.notes = notes
        self.url = url
        self.attendees = attendees
        self.seriesId = seriesId
        self.isRecurring = isRecurring
        self.participantStatus = participantStatus
    }

    var durationMinutes: Int {
        Int(endDate.timeIntervalSince(startDate) / 60)
    }
}

/// Proposed time block for a task
struct ProposedTimeBlock: Identifiable, Codable, Equatable {
    let id: UUID
    var startDate: Date
    var endDate: Date
    var title: String

    var durationMinutes: Int {
        Int(endDate.timeIntervalSince(startDate) / 60)
    }

    init(id: UUID = UUID(), startDate: Date, endDate: Date, title: String) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.title = title
    }
}

/// Service for interacting with Apple Calendar via EventKit
@MainActor
class CalendarService: ObservableObject {
    private let eventStore = EKEventStore()

    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var isAuthorized = false
    @Published var selectedCalendar: EKCalendar?

    init() {
        updateAuthorizationStatus()
    }

    // MARK: - Authorization

    func updateAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        isAuthorized =
            authorizationStatus == .fullAccess || authorizationStatus == .writeOnly
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            await MainActor.run {
                updateAuthorizationStatus()
            }
            return granted
        } catch {
            print("Calendar access error: \(error)")
            return false
        }
    }

    // MARK: - Calendar Management

    /// Get all writable calendars
    func getWritableCalendars() -> [EKCalendar] {
        guard isAuthorized else { return [] }
        return eventStore.calendars(for: .event).filter { $0.allowsContentModifications }
    }

    /// Get the default calendar for events
    func getDefaultCalendar() -> EKCalendar? {
        guard isAuthorized else { return nil }
        return eventStore.defaultCalendarForNewEvents
    }

    // MARK: - Event Fetching

    /// Fetch all events between two dates
    func fetchEvents(from startDate: Date, to endDate: Date) -> [CalendarEvent] {
        guard isAuthorized else { return [] }

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        return events.map { CalendarEvent(from: $0) }
    }

    /// Fetch events grouped by day
    func fetchEventsGroupedByDay(from startDate: Date, to endDate: Date) -> [Date: [CalendarEvent]]
    {
        let events = fetchEvents(from: startDate, to: endDate)
        return CalendarService.groupEventsByDay(events)
    }

    /// Group a pre-fetched array of events by calendar day start.
    /// Exposed as a nonisolated static method so tests can call it without @MainActor context.
    nonisolated static func groupEventsByDay(_ events: [CalendarEvent]) -> [Date: [CalendarEvent]] {
        let calendar = Calendar.current
        var grouped: [Date: [CalendarEvent]] = [:]
        for event in events {
            let dayStart = calendar.startOfDay(for: event.startDate)
            grouped[dayStart, default: []].append(event)
        }
        return grouped
    }

    // MARK: - Event Creation

    /// Create a time blocker event in the calendar
    func createTimeBlocker(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String? = nil,
        calendar: EKCalendar? = nil
    ) throws -> String {
        guard isAuthorized else {
            throw CalendarError.notAuthorized
        }

        let targetCalendar = calendar ?? selectedCalendar ?? eventStore.defaultCalendarForNewEvents
        guard let cal = targetCalendar else {
            throw CalendarError.noCalendarAvailable
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.calendar = cal

        try eventStore.save(event, span: .thisEvent, commit: true)

        return event.eventIdentifier ?? ""
    }

    /// Create multiple time blockers
    func createTimeBlockers(
        _ blocks: [ProposedTimeBlock], taskNotes: String?, calendar: EKCalendar? = nil
    ) throws -> [String] {
        var eventIDs: [String] = []

        for block in blocks {
            let eventID = try createTimeBlocker(
                title: block.title,
                startDate: block.startDate,
                endDate: block.endDate,
                notes: taskNotes,
                calendar: calendar
            )
            eventIDs.append(eventID)
        }

        return eventIDs
    }

    /// Delete a calendar event by ID
    func deleteEvent(withID eventID: String) throws {
        guard isAuthorized else { return }
        guard let event = eventStore.event(withIdentifier: eventID) else { return }

        try eventStore.remove(event, span: .thisEvent, commit: true)
    }

    /// Delete multiple events
    func deleteEvents(withIDs eventIDs: [String]) throws {
        for eventID in eventIDs {
            try deleteEvent(withID: eventID)
        }
    }

    // MARK: - Agent Tool Methods

    /// List all events within a date range
    func listEvents(from startDate: Date, to endDate: Date) async throws -> [CalendarEvent] {
        guard isAuthorized else {
            throw CalendarError.notAuthorized
        }
        
        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )
        let events = eventStore.events(matching: predicate)
        return events.map { CalendarEvent(from: $0) }
    }

    /// Search for events matching a query string
    func searchEvents(query: String, daysAhead: Int = 30) async throws -> [CalendarEvent] {
        guard isAuthorized else {
            throw CalendarError.notAuthorized
        }
        
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: startDate) ?? startDate
        let events = try await listEvents(from: startDate, to: endDate)
        
        let lowercaseQuery = query.lowercased()
        return events.filter { event in
            event.title.lowercased().contains(lowercaseQuery) ||
            event.notes?.lowercased().contains(lowercaseQuery) == true ||
            event.location?.lowercased().contains(lowercaseQuery) == true
        }
    }

    /// Create a full-featured calendar event
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        isAllDay: Bool = false,
        alertMinutesBefore: Int? = nil,
        calendar: EKCalendar? = nil
    ) async throws -> String {
        guard isAuthorized else {
            throw CalendarError.notAuthorized
        }

        let targetCalendar = calendar ?? selectedCalendar ?? eventStore.defaultCalendarForNewEvents
        guard let cal = targetCalendar else {
            throw CalendarError.noCalendarAvailable
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = cal
        event.location = location
        event.notes = notes
        event.url = url
        event.isAllDay = isAllDay
        
        if let minutes = alertMinutesBefore {
            let alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
            event.addAlarm(alarm)
        }
        
        try eventStore.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? ""
    }

    // MARK: - Errors

    enum CalendarError: Error, LocalizedError {
        case notAuthorized
        case noCalendarAvailable
        case eventNotFound

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Calendar access not authorized"
            case .noCalendarAvailable: return "No writable calendar available"
            case .eventNotFound: return "Calendar event not found"
            }
        }
    }
}
