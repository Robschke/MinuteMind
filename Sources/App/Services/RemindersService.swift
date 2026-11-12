import EventKit
import Foundation

/// Service for syncing tasks with Apple Reminders
@MainActor
class RemindersService: ObservableObject {
    private let eventStore = EKEventStore()

    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var isAuthorized = false
    @Published var defaultList: EKCalendar?

    /// The app's dedicated reminders list name
    private let appListName = "MinuteMind Tasks"

    init() {
        updateAuthorizationStatus()
    }

    // MARK: - Authorization

    func updateAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        isAuthorized =
            authorizationStatus == .fullAccess || authorizationStatus == .writeOnly
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToReminders()
            await MainActor.run {
                updateAuthorizationStatus()
            }
            return granted
        } catch {
            print("Reminders access error: \(error)")
            return false
        }
    }

    // MARK: - List Management

    /// Get or create the app's dedicated reminders list.
    /// Falls back through progressively broader source candidates before giving up.
    func getOrCreateAppList() -> EKCalendar? {
        guard isAuthorized else { return nil }

        // Return existing list if already created
        let calendars = eventStore.calendars(for: .reminder)
        if let existing = calendars.first(where: { $0.title == appListName }) {
            return existing
        }

        // Find the best source to host the new list, in preference order:
        //   1. Local device store
        //   2. iCloud CalDAV
        //   3. Any other CalDAV
        //   4. The source behind the system default reminders calendar
        //   5. Any source that can hold reminders (excludes subscribed/birthdays)
        let sources = eventStore.sources
        let source: EKSource? =
            sources.first(where: { $0.sourceType == .local })
            ?? sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") })
            ?? sources.first(where: { $0.sourceType == .calDAV })
            ?? eventStore.defaultCalendarForNewReminders()?.source
            ?? sources.first(where: { $0.sourceType != .subscribed && $0.sourceType != .birthdays })

        guard let source else {
            NSLog("RemindersService: No writable source found — cannot create list")
            return nil
        }

        let newList = EKCalendar(for: .reminder, eventStore: eventStore)
        newList.title = appListName
        newList.source = source

        do {
            try eventStore.saveCalendar(newList, commit: true)
            NSLog("RemindersService: Created '%@' list on source '%@'", appListName, source.title)
            return newList
        } catch {
            NSLog("RemindersService: Failed to create reminders list: %@", error.localizedDescription)
            return nil
        }
    }

    /// Get all available reminder lists
    func getAllLists() -> [EKCalendar] {
        guard isAuthorized else { return [] }
        return eventStore.calendars(for: .reminder)
    }

    // MARK: - Reminder Operations

    /// Create or update a reminder from a task
    func syncTask(_ task: ProjectTask, projectName: String, list: EKCalendar? = nil) async throws
        -> String?
    {
        guard isAuthorized else {
            throw RemindersError.notAuthorized
        }

        let targetList = list ?? getOrCreateAppList()
        guard let calendar = targetList else {
            throw RemindersError.noListAvailable
        }

        let reminder: EKReminder

        // Try to fetch existing reminder
        if let existingID = task.reminderID,
            let existing = eventStore.calendarItem(withIdentifier: existingID) as? EKReminder
        {
            reminder = existing
        } else {
            reminder = EKReminder(eventStore: eventStore)
            reminder.calendar = calendar
        }

        // Update reminder properties
        reminder.title = task.title
        reminder.notes = buildReminderNotes(task: task, projectName: projectName)
        reminder.isCompleted = task.isCompleted
        reminder.priority = mapPriority(task.priority)

        // Set due date with alarm
        if let dueDate = task.dueDate {
            let dueDateComponents = Calendar.current.dateComponents(
                task.hasDueTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day],
                from: dueDate
            )
            reminder.dueDateComponents = dueDateComponents

            // Add alarm if there's a time
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            if task.hasDueTime {
                let alarm = EKAlarm(absoluteDate: dueDate)
                reminder.addAlarm(alarm)
            }
        } else {
            reminder.dueDateComponents = nil
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
        }

        try eventStore.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    /// Delete a reminder
    func deleteReminder(withID reminderID: String) async throws {
        guard isAuthorized else { return }

        if let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder {
            try eventStore.remove(reminder, commit: true)
        }
    }

    /// Fetch updates from Reminders (for sync back to app)
    func fetchReminderStatus(reminderID: String) -> (isCompleted: Bool, dueDate: Date?)? {
        guard isAuthorized,
            let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder
        else {
            return nil
        }

        var dueDate: Date?
        if let components = reminder.dueDateComponents {
            dueDate = Calendar.current.date(from: components)
        }

        return (reminder.isCompleted, dueDate)
    }

    // MARK: - Helper Methods

    private func buildReminderNotes(task: ProjectTask, projectName: String) -> String {
        var notes = "Project: \(projectName)"

        if let assignee = task.assignee, !assignee.isEmpty {
            notes += "\nAssignee: \(assignee)"
        }

        if !task.notes.isEmpty {
            notes += "\n\n\(task.notes)"
        }

        notes += "\n\n[Synced from MinuteMind]"
        return notes
    }

    private func mapPriority(_ priority: TaskPriority?) -> Int {
        // EKReminder priority: 0 = none, 1-4 = high, 5 = medium, 6-9 = low
        switch priority {
        case .critical: return 1
        case .high: return 2
        case .medium: return 5
        case .low: return 7
        case nil: return 0
        }
    }

    // MARK: - Agent Tool Methods

    /// List all reminders with optional filtering
    func listReminders(
        includeCompleted: Bool = false,
        listName: String? = nil,
        daysAhead: Int? = nil
    ) async throws -> [ReminderInfo] {
        guard isAuthorized else {
            throw RemindersError.notAuthorized
        }

        // Build predicate to fetch reminders
        var calendars: [EKCalendar]
        if let listName = listName {
            let allLists = eventStore.calendars(for: .reminder)
            if let targetList = allLists.first(where: { $0.title == listName }) {
                calendars = [targetList]
            } else {
                throw RemindersError.syncFailed("List '\(listName)' not found")
            }
        } else {
            calendars = eventStore.calendars(for: .reminder)
        }

        // Create date range if specified
        var endDate: Date?
        if let days = daysAhead {
            endDate = Calendar.current.date(byAdding: .day, value: days, to: Date())
        }

        let predicate: NSPredicate
        if includeCompleted {
            predicate = eventStore.predicateForReminders(in: calendars)
        } else {
            // For incomplete reminders, we need to provide a date range or nil for both
            if let endDate = endDate {
                predicate = eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: Date(),
                    ending: endDate,
                    calendars: calendars
                )
            } else {
                // Fetch all incomplete reminders without date filtering
                predicate = eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: nil,
                    ending: nil,
                    calendars: calendars
                )
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            // @Sendable keeps this callback nonisolated. Without it the closure inherits
            // @MainActor from this class, and EventKit calls it on its own background queue
            // (com.apple.eventkit.reminders.search), so the Swift 6 runtime isolation check
            // traps and the app crashes. Touch only the reminders and the continuation here.
            eventStore.fetchReminders(matching: predicate) { @Sendable reminders in
                guard let reminders = reminders else {
                    continuation.resume(throwing: RemindersError.syncFailed("Failed to fetch reminders"))
                    return
                }

                let reminderInfos = reminders.map { reminder in
                    ReminderInfo(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "Untitled",
                        notes: reminder.notes,
                        isCompleted: reminder.isCompleted,
                        dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        priority: reminder.priority,
                        listName: reminder.calendar?.title ?? "Unknown",
                        creationDate: reminder.creationDate,
                        completionDate: reminder.completionDate
                    )
                }

                continuation.resume(returning: reminderInfos)
            }
        }
    }

    /// Create a reminder with full options (for agent tool use)
    func createReminder(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: Int? = nil,
        listName: String? = nil
    ) async throws -> String {
        guard isAuthorized else {
            throw RemindersError.notAuthorized
        }

        // Find target list
        let targetList: EKCalendar?
        if let listName = listName {
            let lists = eventStore.calendars(for: .reminder)
            targetList = lists.first { $0.title == listName }
            if targetList == nil {
                throw RemindersError.syncFailed("List '\(listName)' not found")
            }
        } else {
            targetList = eventStore.defaultCalendarForNewReminders() ?? getOrCreateAppList()
        }

        guard let calendar = targetList else {
            throw RemindersError.noListAvailable
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes

        // Set due date
        if let due = dueDate {
            let dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            reminder.dueDateComponents = dueDateComponents

            // Add alarm for the due time
            let alarm = EKAlarm(absoluteDate: due)
            reminder.addAlarm(alarm)
        }

        // Set priority (0 = none, 1-4 = high, 5 = medium, 6-9 = low)
        if let pri = priority {
            reminder.priority = pri
        }

        try eventStore.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }
}

// MARK: - Data Models

/// Information about a reminder
struct ReminderInfo {
    let id: String
    let title: String
    let notes: String?
    let isCompleted: Bool
    let dueDate: Date?
    let priority: Int
    let listName: String
    let creationDate: Date?
    let completionDate: Date?
}

// MARK: - Errors

enum RemindersError: Error, LocalizedError {
    case notAuthorized
    case noListAvailable
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Reminders access not authorized. Please enable in System Settings."
        case .noListAvailable:
            return "No reminders list available. Please check your Reminders app."
        case .syncFailed(let detail):
            return "Failed to sync reminder: \(detail)"
        }
    }
}
