import Foundation

/// A project that groups recordings and tasks together
struct Project: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var colorHex: String
    var createdAt: Date
    var updatedAt: Date
    /// Optional project start date for timeline tracking
    var startDate: Date?
    /// Optional target completion date for timeline tracking
    var targetDate: Date?
    /// Per-project override for auto-accepting extracted tasks.
    /// nil = use global AutomationSettings default.
    var autoAcceptExtractedTasks: Bool?
    /// Absolute path of the folder where transcripts and summaries are exported
    /// (`<folder>/<yyyy-MM-dd>/<meeting name>/`). nil = not configured yet.
    var exportFolderPath: String?
    /// Explicit opt-out from file export. Recording requires either a configured
    /// export folder or this flag — see `isExportConfigured`.
    var exportOptOut: Bool?
    /// Position in the user's own order (sidebar arranging). nil = never arranged; such
    /// projects come first, newest on top, so a new project appears at the top.
    var sortOrder: Int? = nil
    /// Starred in the sidebar (right click): first in the companion's project wheel, marked with
    /// a tiny companion avatar. nil = not starred.
    var isStarred: Bool? = nil
    /// The desktop companion creature that speaks for this project's Claude sessions
    /// (`MascotAvatar` raw value, set with a right click in the sidebar). nil = none: the
    /// companion itself reports them.
    var companionAvatar: String? = nil
    /// Set once the project is a Shared Project (its workspace repo has a shared remote). nil =
    /// Private, the default. See SharedProject.swift.
    var shared: SharedProjectInfo? = nil

    var isShared: Bool { shared != nil }

    /// `companionAvatar` as a creature; an unknown stored value counts as none.
    var companionCreature: MascotAvatar? { companionAvatar.flatMap(MascotAvatar.init(rawValue:)) }

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = Project.defaultColors.randomElement() ?? "#007AFF",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startDate: Date? = nil,
        targetDate: Date? = nil,
        autoAcceptExtractedTasks: Bool? = nil,
        exportFolderPath: String? = nil,
        exportOptOut: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startDate = startDate
        self.targetDate = targetDate
        self.autoAcceptExtractedTasks = autoAcceptExtractedTasks
        self.exportFolderPath = exportFolderPath
        self.exportOptOut = exportOptOut
    }

    /// The sidebar order: never-arranged projects first (newest on top), then the arranged ones.
    static func isOrderedBefore(_ a: Project, _ b: Project) -> Bool {
        switch (a.sortOrder, b.sortOrder) {
        case (nil, nil): return a.createdAt > b.createdAt
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return x < y
        }
    }

    /// True when the project either has an export folder or explicitly opted out.
    /// Starting a recording requires the assigned project to satisfy this.
    var isExportConfigured: Bool {
        exportOptOut == true || !(exportFolderPath ?? "").isEmpty
    }
    
    /// Predefined color options for projects
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

/// Board column position for kanban workflow
enum TaskStatus: String, Codable, CaseIterable {
    case backlog
    case todo
    case inProgress
    case review
    case done

    var displayName: String {
        switch self {
        case .backlog: return "Backlog"
        case .todo: return "To Do"
        case .inProgress: return "In Progress"
        case .review: return "Review"
        case .done: return "Done"
        }
    }

    var icon: String {
        switch self {
        case .backlog: return "tray"
        case .todo: return "circle"
        case .inProgress: return "play.circle"
        case .review: return "eye.circle"
        case .done: return "checkmark.circle.fill"
        }
    }
}

/// Priority level for tasks
enum TaskPriority: String, Codable, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case critical = "critical"
    
    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }
    
    var color: String {
        switch self {
        case .low: return "#8E8E93"      // Gray
        case .medium: return "#007AFF"   // Blue
        case .high: return "#FF9500"     // Orange
        case .critical: return "#FF3B30" // Red
        }
    }
}

/// A task belonging to a project
struct ProjectTask: Identifiable, Codable, Equatable {
    let id: UUID
    var projectID: UUID?
    var title: String
    var notes: String
    var isCompleted: Bool
    var createdAt: Date
    var completedAt: Date?
    /// Optional reference to the recording session that generated this task (for future AI extraction)
    var sourceSessionID: UUID?
    /// Person responsible for the task (extracted from AI or manually set)
    var assignee: String?
    /// Due date and time for the task
    var dueDate: Date?
    /// Whether to include time in the due date
    var hasDueTime: Bool
    /// Priority level of the task
    var priority: TaskPriority?
    /// Apple Reminders ID for syncing (nil if not synced)
    var reminderID: String?
    /// Whether reminders sync is enabled for this task
    var reminderEnabled: Bool
    /// Estimated duration in minutes to complete the task
    var estimatedDurationMinutes: Int?
    /// Calendar event IDs for time blockers created for this task
    var calendarBlockerIDs: [String]
    /// Whether this auto-extracted task needs user review (accept/reject/edit).
    /// Optional for backward compatibility — nil and false both mean "reviewed".
    var needsReview: Bool?
    /// Board column position. Optional for backward compatibility — nil derives from isCompleted.
    var status: TaskStatus?
    /// Optional epic grouping for board view
    var epicID: UUID?
    /// Linked knowledge base document IDs for quick access to related KB entries
    var knowledgeDocumentIDs: [Int64]?

    /// Effective board status, deriving from isCompleted when status is nil (backward compat)
    var effectiveStatus: TaskStatus {
        status ?? (isCompleted ? .done : .todo)
    }

    init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        title: String,
        notes: String = "",
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        sourceSessionID: UUID? = nil,
        assignee: String? = nil,
        dueDate: Date? = nil,
        hasDueTime: Bool = false,
        priority: TaskPriority? = nil,
        reminderID: String? = nil,
        reminderEnabled: Bool = false,
        estimatedDurationMinutes: Int? = nil,
        calendarBlockerIDs: [String] = [],
        needsReview: Bool? = nil,
        status: TaskStatus? = nil,
        epicID: UUID? = nil,
        knowledgeDocumentIDs: [Int64]? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.sourceSessionID = sourceSessionID
        self.assignee = assignee
        self.dueDate = dueDate
        self.hasDueTime = hasDueTime
        self.priority = priority
        self.reminderID = reminderID
        self.reminderEnabled = reminderEnabled
        self.estimatedDurationMinutes = estimatedDurationMinutes
        self.calendarBlockerIDs = calendarBlockerIDs
        self.needsReview = needsReview
        self.status = status
        self.epicID = epicID
        self.knowledgeDocumentIDs = knowledgeDocumentIDs
    }

    mutating func toggleCompleted() {
        isCompleted.toggle()
        completedAt = isCompleted ? Date() : nil
        // Sync status with completion state
        if isCompleted {
            status = .done
        } else if status == .done {
            status = .todo
        }
    }
}
