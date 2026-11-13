/// Epic model for grouping tasks into larger initiatives on the workboard.
/// Depends on: Foundation only (its colour palette is its own).
/// Used by: WorkboardView, EpicManagementSheet, AppViewModel

import Foundation

struct Epic: Identifiable, Codable, Equatable {
    let id: UUID
    var projectID: UUID
    var title: String
    var summary: String
    var colorHex: String
    var sortOrder: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        projectID: UUID,
        title: String,
        summary: String = "",
        colorHex: String = Epic.defaultColors.randomElement() ?? "#007AFF",
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.summary = summary
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// Colour options for epics on the workboard.
    static let defaultColors: [String] = [
        "#007AFF", // Blue
        "#34C759", // Green
        "#FF9500", // Orange
        "#FF3B30", // Red
        "#AF52DE", // Purple
        "#5856D6", // Indigo
        "#FF2D55", // Pink
        "#00C7BE", // Teal
    ]
}
