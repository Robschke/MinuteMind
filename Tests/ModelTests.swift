// Purpose: Model unit tests covering CalendarEvent, ProposedTimeBlock, ProjectTask,
//          calendar-session linking (CAL-03, CAL-04), and TaskPriority.
// Dependencies: Sources/App/Models/RecordingSession.swift, Sources/App/Services/CalendarService.swift,
//               Sources/App/Models/Project.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("Model Tests")
struct ModelTests {

    @Test("CalendarEvent duration calculation")
    func testCalendarEventDuration() {
        let now = Date()
        let event = CalendarEvent(
            title: "Test Event",
            startDate: now,
            endDate: now.addingTimeInterval(3600)  // 60 minutes
        )
        #expect(event.durationMinutes == 60)
    }

    @Test("ProposedTimeBlock duration calculation")
    func testProposedTimeBlockDuration() {
        let now = Date()
        let block = ProposedTimeBlock(
            startDate: now,
            endDate: now.addingTimeInterval(1800),  // 30 minutes
            title: "Test Block"
        )
        #expect(block.durationMinutes == 30)
    }

    @Test("ProjectTask toggle completed")
    func testProjectTaskToggleCompleted() {
        var task = ProjectTask(
            projectID: UUID(),
            title: "Test Task"
        )

        #expect(task.isCompleted == false)
        #expect(task.completedAt == nil)

        task.toggleCompleted()

        #expect(task.isCompleted == true)
        #expect(task.completedAt != nil)

        task.toggleCompleted()

        #expect(task.isCompleted == false)
        #expect(task.completedAt == nil)
    }

    @Test("TaskPriority display names and colors")
    func testTaskPriority() {
        #expect(TaskPriority.critical.displayName == "Critical")
        #expect(TaskPriority.high.displayName == "High")
        #expect(TaskPriority.medium.displayName == "Medium")
        #expect(TaskPriority.low.displayName == "Low")

        #expect(TaskPriority.critical.color == "#FF3B30")
        #expect(TaskPriority.high.color == "#FF9500")
        #expect(TaskPriority.medium.color == "#007AFF")
        #expect(TaskPriority.low.color == "#8E8E93")
    }

    // MARK: - Calendar Session Linking (CAL-03)

    @Test("createSession(from:) maps calendar event fields onto a new session")
    func testCreateSessionFromCalendarEvent() throws {
        let now = Date()
        let event = CalendarEvent(
            id: "evt-q4",
            title: "Q4 Planning",
            startDate: now,
            endDate: now.addingTimeInterval(3600),
            attendees: ["Alice", "Bob"]
        )

        // createSession(from:) is a free function (or AppViewModel factory) added in Plan 02.
        let session = createSession(from: event)

        #expect(session.title == "Q4 Planning")
        #expect(session.calendarEventTitle == "Q4 Planning")
        #expect(session.calendarAttendees == ["Alice", "Bob"])
    }

    // MARK: - Calendar Fields Round-Trip (CAL-04)

    @Test("RecordingSession with calendar fields encodes/decodes without data loss")
    func testCalendarFieldsRoundTrip() throws {
        let now = Date()

        // Build a session with all six calendar fields populated
        var session = RecordingSession(
            title: "Q4 Planning",
            languageCode: "en-US",
            status: .completed
        )
        session.calendarEventID = "evt-q4"
        session.calendarEventTitle = "Q4 Planning"
        session.calendarAttendees = ["Alice", "Bob"]
        session.calendarScheduledStart = now
        session.calendarScheduledEnd = now.addingTimeInterval(3600)
        session.calendarNotes = "Discuss roadmap"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingSession.self, from: data)

        #expect(decoded.calendarEventID == session.calendarEventID)
        #expect(decoded.calendarEventTitle == session.calendarEventTitle)
        #expect(decoded.calendarAttendees == session.calendarAttendees)
        #expect(decoded.calendarNotes == session.calendarNotes)

        // Legacy session (no calendar fields) must decode without crash and have nil fields
        var legacy = RecordingSession(title: "Old Session", languageCode: "en-US", status: .completed)
        // Intentionally leaving all calendar fields nil (simulates legacy JSON)
        let legacyData = try encoder.encode(legacy)
        let legacyDecoded = try decoder.decode(RecordingSession.self, from: legacyData)

        #expect(legacyDecoded.calendarEventID == nil)
        #expect(legacyDecoded.calendarEventTitle == nil)
        #expect(legacyDecoded.calendarAttendees == nil)
        #expect(legacyDecoded.calendarScheduledStart == nil)
        #expect(legacyDecoded.calendarScheduledEnd == nil)
        #expect(legacyDecoded.calendarNotes == nil)
    }
}
