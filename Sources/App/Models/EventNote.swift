// Purpose: EventNote — a user-authored note linked to a calendar event or created manually,
//          optionally associated with a project.
// Dependencies: Foundation
// Used by: Sources/App/Store/EventNotesStore.swift, Sources/App/ViewModels/AppViewModel.swift

import Foundation

struct EventNote: Identifiable, Codable, Equatable {
    var id: UUID
    /// Stable EKEvent identifier (CalendarEvent.id). Nil for manually created notes.
    let eventId: String?
    /// Denormalized event title — or user-provided title for manual notes.
    var eventTitle: String
    /// Denormalized event start date — or creation date for manual notes.
    var eventDate: Date
    /// Optional association with a MinuteMind project.
    var projectId: UUID?
    var content: String
    var tags: [String]
    let createdAt: Date
    var updatedAt: Date

    /// True when the note was created manually (not tied to a calendar event).
    var isManual: Bool { eventId == nil }

    /// Creates a note linked to a calendar event.
    init(eventId: String, eventTitle: String, eventDate: Date, projectId: UUID? = nil) {
        self.id = UUID()
        self.eventId = eventId
        self.eventTitle = eventTitle
        self.eventDate = eventDate
        self.projectId = projectId
        self.content = ""
        self.tags = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Creates a standalone note not linked to any calendar event.
    init(title: String, projectId: UUID? = nil) {
        self.id = UUID()
        self.eventId = nil
        self.eventTitle = title
        self.eventDate = Date()
        self.projectId = projectId
        self.content = ""
        self.tags = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
