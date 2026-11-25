// Purpose: RemindersService, the EventKit side of Apple Reminders: access, the "MinuteMind Tasks"
//          list, reading and writing the reminders of synced tasks, and the reminder tools Claude
//          uses over MCP.
// Dependencies: Sources/App/Services/TaskReminderSync.swift (ReminderContent, RemoteReminder, marker)
// Used by: Sources/App/ViewModels/AppViewModel+RemindersSync.swift (task sync),
//          Sources/App/Services/ToolExecutor.swift (list/create/delete reminder tools)
// Notes: A new MinuteMind list goes to the account of the default reminders list first, so it
//        shows on the user's other devices; an existing list stays where it is (found by title).

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

        // Find the best source to host the new list, in preference order, so the list reaches
        // the user's iPhone and Watch where possible:
        //   1. The account of the default reminders list (usually iCloud)
        //   2. iCloud CalDAV
        //   3. Any other CalDAV
        //   4. Local device store ("On My Mac")
        //   5. Any source that can hold reminders (excludes subscribed/birthdays)
        let sources = eventStore.sources
        let source: EKSource? =
            eventStore.defaultCalendarForNewReminders()?.source
            ?? sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") })
            ?? sources.first(where: { $0.sourceType == .calDAV })
            ?? sources.first(where: { $0.sourceType == .local })
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

    // MARK: - Task Sync (TaskReminderSync)

    /// Reading reminders back needs full access; write-only access can only add them.
    /// Read from EventKit each time, so access granted in System Settings counts at once.
    var hasFullAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// The MinuteMind list when it exists, without creating it.
    func existingAppList() -> EKCalendar? {
        guard isAuthorized else { return nil }
        return eventStore.calendars(for: .reminder).first(where: { $0.title == appListName })
    }

    /// Every reminder in the MinuteMind list, done ones included; nil when the list does not
    /// exist or EventKit could not read it.
    func appListReminders() async -> [RemoteReminder]? {
        guard hasFullAccess, let list = existingAppList() else { return nil }
        let predicate = eventStore.predicateForReminders(in: [list])
        return await withCheckedContinuation { continuation in
            // @Sendable keeps the callback off the main actor (see listReminders).
            eventStore.fetchReminders(matching: predicate) { @Sendable reminders in
                continuation.resume(returning: reminders?.map(Self.remote))
            }
        }
    }

    /// The reminder with this identifier in any list, nil when it does not exist (anymore).
    func remoteReminder(withID id: String) -> RemoteReminder? {
        guard hasFullAccess, let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder
        else { return nil }
        return Self.remote(reminder)
    }

    /// Writes `content` into reminder `reminderID`, or into a new reminder in the MinuteMind list
    /// when it is nil or gone, marks it with the task's id and returns it as stored.
    func write(_ content: ReminderContent, taskID: UUID, reminderID: String?) throws -> RemoteReminder {
        guard isAuthorized else { throw RemindersError.notAuthorized }
        let reminder: EKReminder
        if let reminderID, let existing = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder {
            reminder = existing
        } else {
            guard let list = getOrCreateAppList() else { throw RemindersError.noListAvailable }
            reminder = EKReminder(eventStore: eventStore)
            reminder.calendar = list
        }
        reminder.title = content.title
        reminder.notes = content.notes.isEmpty ? nil : content.notes
        reminder.priority = content.priority
        reminder.url = TaskReminderSync.markerURL(for: taskID)
        reminder.alarms?.forEach { reminder.removeAlarm($0) }
        if let due = content.due {
            reminder.dueDateComponents = due.components
            // An alarm only for a due time, as Reminders does for dated reminders.
            if due.hasTime, let date = due.date() { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        } else {
            reminder.dueDateComponents = nil
        }
        reminder.isCompleted = content.isCompleted
        try eventStore.save(reminder, commit: true)
        return Self.remote(reminder)
    }

    /// Posted by EventKit when reminders change, here or in Reminders (also on other devices).
    var changeNotificationObject: EKEventStore { eventStore }

    nonisolated private static func remote(_ reminder: EKReminder) -> RemoteReminder {
        RemoteReminder(
            id: reminder.calendarItemIdentifier,
            marker: TaskReminderSync.taskID(fromMarker: reminder.url),
            content: ReminderContent(
                title: reminder.title ?? "",
                notes: reminder.notes ?? "",
                priority: reminder.priority,
                due: ReminderDue(components: reminder.dueDateComponents),
                isCompleted: reminder.isCompleted))
    }

    /// Delete a reminder
    func deleteReminder(withID reminderID: String) async throws {
        try deleteReminderNow(withID: reminderID)
    }

    /// Deletes the reminder when it still exists.
    func deleteReminderNow(withID reminderID: String) throws {
        guard isAuthorized else { return }
        if let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder {
            try eventStore.remove(reminder, commit: true)
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
