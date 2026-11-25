// Purpose: TaskReminderSync, the rules of the two-way sync between MinuteMind tasks and the
//          "MinuteMind Tasks" list in Apple Reminders: which tasks belong there, and per task
//          whether to create, update, pull from or let go of its reminder. Pure, so it is tested
//          without EventKit.
// Dependencies: Sources/App/Models/Project.swift (ProjectTask, TaskPriority)
// Used by: Sources/App/ViewModels/AppViewModel+RemindersSync.swift (applies the decisions),
//          Sources/App/Services/RemindersService.swift (reads and writes ReminderContent)
// Notes: Each linked task keeps a ReminderSyncSnapshot: what MinuteMind last wrote (`pushed`) and
//        what it last read back from the reminder (`seen`). A change on the Reminders side is
//        `remote != seen`, one on the MinuteMind side `desired != pushed`, both compared through
//        the same normalisation, so nothing is written twice and the sync cannot loop on its own
//        EventKit change notifications. Reminders wins where both sides changed the same field.
//        Only title, due date and done flow back from Reminders; notes and priority are
//        MinuteMind's (a notes edit made in Reminders stays until the task changes).
//        Reminders carry the task id in their URL (`marker`), so a reminder whose identifier
//        changed (iCloud resync) is found again, and only reminders without a marker are
//        imported as new tasks.

import Foundation

/// A due date as Reminders stores it: a day, optionally with a time.
struct ReminderDue: Codable, Equatable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int?
    var minute: Int?

    var hasTime: Bool { hour != nil }

    init(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = hour == nil ? nil : (minute ?? 0)
    }

    init(date: Date, hasTime: Bool, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(
            year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1,
            hour: hasTime ? parts.hour ?? 0 : nil, minute: hasTime ? parts.minute ?? 0 : nil)
    }

    /// Nil when the components lack a day (Reminders without a due date).
    init?(components: DateComponents?) {
        guard let components, let year = components.year, let month = components.month,
              let day = components.day
        else { return nil }
        self.init(year: year, month: month, day: day, hour: components.hour, minute: components.minute)
    }

    var components: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    func date(calendar: Calendar = .current) -> Date? {
        calendar.date(from: components)
    }
}

/// The fields of a reminder the sync reads and writes.
struct ReminderContent: Codable, Equatable {
    var title: String
    var notes: String
    /// EventKit's scale: 0 none, 1 to 4 high, 5 medium, 6 to 9 low.
    var priority: Int
    var due: ReminderDue?
    var isCompleted: Bool

    /// What the reminder of `task` should say.
    init(task: ProjectTask, projectName: String?) {
        title = task.title
        notes = Self.notes(for: task, projectName: projectName)
        priority = Self.priority(task.priority)
        due = task.dueDate.map { ReminderDue(date: $0, hasTime: task.hasDueTime) }
        isCompleted = task.isCompleted
    }

    init(title: String, notes: String, priority: Int, due: ReminderDue?, isCompleted: Bool) {
        self.title = title
        self.notes = notes
        self.priority = priority
        self.due = due
        self.isCompleted = isCompleted
    }

    /// Project and assignee above the task's own notes. Tasks without a project (imported from
    /// Reminders) keep their notes as they are.
    static func notes(for task: ProjectTask, projectName: String?) -> String {
        guard let projectName else { return task.notes }
        var lines = ["Project: \(projectName)"]
        if let assignee = task.assignee, !assignee.isEmpty { lines.append("Assignee: \(assignee)") }
        if !task.notes.isEmpty { lines.append("\n\(task.notes)") }
        lines.append("\n[Synced from MinuteMind]")
        return lines.joined(separator: "\n")
    }

    static func priority(_ priority: TaskPriority?) -> Int {
        switch priority {
        case .critical: 1
        case .high: 2
        case .medium: 5
        case .low: 7
        case nil: 0
        }
    }

    static func taskPriority(_ priority: Int) -> TaskPriority? {
        switch priority {
        case 1: .critical
        case 2...4: .high
        case 5: .medium
        case 6...9: .low
        default: nil
        }
    }
}

/// What the sync last wrote to a task's reminder and last read back from it.
struct ReminderSyncSnapshot: Codable, Equatable {
    var pushed: ReminderContent
    var seen: ReminderContent
}

/// A reminder as the sync sees it.
struct RemoteReminder: Equatable {
    var id: String
    /// The MinuteMind task id stored in the reminder's URL, nil for reminders made in Reminders.
    var marker: UUID?
    var content: ReminderContent
}

/// The fields of a task to take over from its reminder.
struct ReminderPull: Equatable {
    var title: String?
    /// Set when the due date changed; the inner value nil means the date was removed.
    var due: ReminderDue??
    var isCompleted: Bool?

    var isEmpty: Bool { title == nil && due == nil && isCompleted == nil }
}

enum TaskReminderSync {
    static let markerScheme = "minutemind"

    static func markerURL(for taskID: UUID) -> URL {
        URL(string: "\(markerScheme)://task/\(taskID.uuidString)")!
    }

    static func taskID(fromMarker url: URL?) -> UUID? {
        guard let url, url.scheme == markerScheme, url.host == "task" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// Whether the user wants this task in Reminders: every accepted task while "sync all" is
    /// on (unless its bell took it out), otherwise only tasks with the bell on.
    static func isSelected(_ task: ProjectTask, syncAll: Bool) -> Bool {
        guard task.needsReview != true else { return false }
        return syncAll ? task.reminderExcluded != true : task.reminderEnabled
    }

    /// Whether the task should have a reminder now: selected, and open or already linked (a
    /// task closed in MinuteMind keeps its reminder, ticked off; a closed one never gets a new one).
    static func wantsReminder(_ task: ProjectTask, syncAll: Bool) -> Bool {
        isSelected(task, syncAll: syncAll) && (!task.isCompleted || task.reminderID != nil)
    }

    enum Decision: Equatable {
        case nothing
        /// Make a new reminder for the task.
        case create
        /// The reminder exists: take `pull` into the task, then write the task's content when
        /// `push`, and store the snapshot. `reminderID` may differ from the task's (found by marker).
        case sync(reminderID: String, pull: ReminderPull, push: Bool)
        /// The reminder was deleted in Reminders: close the task (when open) and unlink it.
        case closeDeleted
        /// Unlink the task and delete its reminder when there is one.
        case remove(reminderID: String?)
    }

    /// The step for one task. `remote` is its reminder (by id or marker), nil when none was found;
    /// `canTellDeleted` is false when a missing reminder might only be unreadable right now.
    static func decide(
        task: ProjectTask, desired: ReminderContent, remote: RemoteReminder?,
        syncAll: Bool, canTellDeleted: Bool
    ) -> Decision {
        guard wantsReminder(task, syncAll: syncAll) else {
            if let remote { return .remove(reminderID: remote.id) }
            return task.reminderID == nil ? .nothing : .remove(reminderID: nil)
        }
        guard let remote else {
            if task.reminderID == nil { return task.isCompleted ? .nothing : .create }
            return canTellDeleted ? .closeDeleted : .nothing
        }
        let pull = pullFromReminder(task: task, remote: remote.content)
        let afterPull = applying(pull, to: desired)
        // Changed in MinuteMind: a field the pull does not overwrite differs from the last write.
        let changedHere = task.reminderSnapshot.map { applying(pull, to: $0.pushed) != afterPull } ?? true
        let push = changedHere && afterPull != remote.content
        return .sync(reminderID: remote.id, pull: pull, push: push)
    }

    /// The fields changed in Reminders since the last sync. Without a snapshot (tasks linked by
    /// older builds) only a reminder ticked off there counts.
    static func pullFromReminder(task: ProjectTask, remote: ReminderContent) -> ReminderPull {
        guard let seen = task.reminderSnapshot?.seen else {
            return ReminderPull(isCompleted: remote.isCompleted && !task.isCompleted ? true : nil)
        }
        var pull = ReminderPull()
        if remote.title != seen.title, !remote.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pull.title = remote.title
        }
        if remote.due != seen.due { pull.due = .some(remote.due) }
        if remote.isCompleted != seen.isCompleted { pull.isCompleted = remote.isCompleted }
        return pull
    }

    /// `content` with the pulled fields taken over (what the task will say once they apply).
    static func applying(_ pull: ReminderPull, to content: ReminderContent) -> ReminderContent {
        var result = content
        if let title = pull.title { result.title = title }
        if let due = pull.due { result.due = due }
        if let done = pull.isCompleted { result.isCompleted = done }
        return result
    }

    /// The reminders in the MinuteMind list that should become tasks: open, without a
    /// MinuteMind marker, and not linked to a task already.
    static func remindersToImport(_ reminders: [RemoteReminder], linkedIDs: Set<String>) -> [RemoteReminder] {
        reminders.filter { reminder in
            reminder.marker == nil && !linkedIDs.contains(reminder.id) && !reminder.content.isCompleted
                && !reminder.content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// A new task (no project) for a reminder made in Reminders.
    static func task(importing reminder: RemoteReminder, now: Date = Date()) -> ProjectTask {
        let content = reminder.content
        var task = ProjectTask(
            title: content.title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: content.notes,
            createdAt: now,
            dueDate: content.due?.date(),
            hasDueTime: content.due?.hasTime ?? false,
            priority: ReminderContent.taskPriority(content.priority),
            reminderID: reminder.id,
            reminderEnabled: true)
        task.needsReview = false
        return task
    }

    /// When this many linked reminders or more vanish at once and none is left, the store is
    /// more likely unreadable (iCloud signing out, a list deleted) than every reminder deleted
    /// by hand: the tasks are then unlinked, not closed.
    static let massDisappearanceThreshold = 5
}
