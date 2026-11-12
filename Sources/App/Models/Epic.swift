/// Epic model for grouping tasks into larger initiatives on the workboard.
/// Depends on: Project.swift (uses Project.defaultColors palette)
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
        colorHex: String = Project.defaultColors.randomElement() ?? "#007AFF",
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
}
