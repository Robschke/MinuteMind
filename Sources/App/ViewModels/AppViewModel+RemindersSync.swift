// Purpose: AppViewModel+RemindersSync, keeps the tasks and the "MinuteMind Tasks" list in Apple
//          Reminders in sync both ways: done in one place is done in the other, titles and due
//          dates flow back, a reminder deleted in Reminders closes its task, and reminders added
//          to the list become tasks without a project.
// Dependencies: Sources/App/Services/TaskReminderSync.swift (the rules, pure),
//               Sources/App/Services/RemindersService.swift (EventKit),
//               Sources/App/Config/AutomationSettings.swift (remindersSyncAll)
// Used by: Sources/App/ViewModels/AppViewModel.swift (tasks didSet, launch, deleting tasks),
//          Sources/App/Views/ProjectDetailView.swift and AllTasksView.swift (bell),
//          Sources/App/Views/AutomationSettingsView.swift, Sources/App/Help/AppSettingsCatalog.swift
// Notes: Every change to `tasks`, every EventKit change notification (Reminders on this Mac or
//        iCloud from another device) and every return to the app schedules one sync 1.5 s later;
//        a sync that finds nothing to do writes nothing, so the notifications its own writes
//        cause end in a no-op. Only one sync runs at a time, a request meanwhile runs once more
//        after it. Nothing runs without full Reminders access, and nothing in test processes.

import AppKit
import EventKit
import Foundation

extension AppViewModel {
    /// Whether the task is meant to be in Apple Reminders (the bell's state).
    func syncsToReminders(_ task: ProjectTask) -> Bool {
        TaskReminderSync.isSelected(task, syncAll: automationSettings.remindersSyncAll)
    }

    /// The bell: puts the task into Reminders or takes it out. While "sync all open tasks" is on
    /// it excludes the task, otherwise it opts the task in.
    func toggleTaskReminder(_ task: ProjectTask) async {
        guard let current = tasks.first(where: { $0.id == task.id }) else { return }
        let selected = !syncsToReminders(current)
        modifyTasks { tasks in
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                setReminderSelection(of: &tasks[index], selected: selected)
            }
        }
        await syncReminders()
    }

    /// Puts the task into Reminders or takes it out, by the setting's rules (see isSelected).
    func setReminderSelection(of task: inout ProjectTask, selected: Bool) {
        if automationSettings.remindersSyncAll {
            task.reminderExcluded = selected ? nil : true
        } else {
            task.reminderEnabled = selected
        }
    }

    /// Deletes the reminders of tasks that are being deleted in MinuteMind.
    func deleteReminders(of deletedTasks: [ProjectTask]) {
        let ids = deletedTasks.compactMap(\.reminderID)
        guard !ids.isEmpty else { return }
        Task {
            for id in ids { try? await remindersService.deleteReminder(withID: id) }
        }
    }

    /// Starts listening for Reminders changes and app activation, and syncs once. Called at launch.
    func setupRemindersSync() {
        guard !Self.isTestProcess else { return }
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: remindersService.changeNotificationObject, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRemindersSync() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRemindersSync() }
        }
        scheduleRemindersSync()
    }

    /// Runs a sync shortly, coalescing bursts of changes into one.
    func scheduleRemindersSync() {
        guard !Self.isTestProcess, remindersService.hasFullAccess else { return }
        remindersSyncDebounce?.cancel()
        remindersSyncDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.syncReminders()
        }
    }

    /// One pass over all tasks and the MinuteMind list.
    func syncReminders() async {
        remindersService.updateAuthorizationStatus()
        guard remindersService.hasFullAccess else { return }
        if isSyncingReminders {
            remindersSyncRequestedAgain = true
            return
        }
        isSyncingReminders = true
        defer { isSyncingReminders = false }
        repeat {
            remindersSyncRequestedAgain = false
            await runRemindersSyncPass()
        } while remindersSyncRequestedAgain
    }

    private func runRemindersSyncPass() async {
        let listReminders = await remindersService.appListReminders()
        // From here on everything is synchronous on the main actor, so `tasks` cannot change
        // underneath the pass.
        let listExists = remindersService.existingAppList() != nil
        let syncAll = automationSettings.remindersSyncAll
        let byID = Dictionary(listReminders?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let byMarker = Dictionary(
            listReminders?.compactMap { reminder in reminder.marker.map { ($0, reminder) } } ?? [],
            uniquingKeysWith: { first, _ in first })

        var updated = tasks
        var remotes: [UUID: RemoteReminder] = [:]
        for task in updated {
            if let id = task.reminderID, let remote = byID[id] ?? remindersService.remoteReminder(withID: id) {
                remotes[task.id] = remote
            } else if let remote = byMarker[task.id] {
                remotes[task.id] = remote
            }
        }

        // A missing reminder counts as deleted only while the list could be read; when every
        // linked reminder vanished at once, the store is more likely unreadable than emptied by
        // hand, and the tasks are unlinked instead of closed.
        let linked = updated.filter { $0.reminderID != nil }
        let vanished = linked.filter { remotes[$0.id] == nil }
        let massVanish = vanished.count >= TaskReminderSync.massDisappearanceThreshold
            && vanished.count == linked.count
        let canTellDeleted = listReminders != nil && !massVanish
        let unlinkMissing = !listExists || massVanish
        if massVanish {
            NSLog("RemindersSync: all %d linked reminders are gone at once, unlinking instead of closing", vanished.count)
        }

        for index in updated.indices {
            let task = updated[index]
            let desired = ReminderContent(task: task, projectName: reminderProjectName(task))
            var decision = TaskReminderSync.decide(
                task: task, desired: desired, remote: remotes[task.id],
                syncAll: syncAll, canTellDeleted: canTellDeleted)
            if decision == .nothing, unlinkMissing, task.reminderID != nil, remotes[task.id] == nil {
                decision = .remove(reminderID: nil)
            }
            updated[index] = apply(decision, to: task, remote: remotes[task.id])
        }

        // Reminders added to the MinuteMind list in Reminders become tasks.
        let linkedIDs = Set(updated.compactMap(\.reminderID))
        for reminder in TaskReminderSync.remindersToImport(listReminders ?? [], linkedIDs: linkedIDs) {
            var task = TaskReminderSync.task(importing: reminder)
            let content = ReminderContent(task: task, projectName: nil)
            if let stored = try? remindersService.write(content, taskID: task.id, reminderID: reminder.id) {
                task.reminderSnapshot = ReminderSyncSnapshot(pushed: content, seen: stored.content)
            }
            updated.append(task)
        }

        modifyTasks { $0 = updated }
    }

    private func apply(_ decision: TaskReminderSync.Decision, to task: ProjectTask, remote: RemoteReminder?) -> ProjectTask {
        var task = task
        switch decision {
        case .nothing:
            break
        case .create:
            let content = ReminderContent(task: task, projectName: reminderProjectName(task))
            do {
                let stored = try remindersService.write(content, taskID: task.id, reminderID: nil)
                task.reminderID = stored.id
                task.reminderSnapshot = ReminderSyncSnapshot(pushed: content, seen: stored.content)
            } catch {
                NSLog("RemindersSync: could not create a reminder: %@", error.localizedDescription)
            }
        case .sync(let reminderID, let pull, let push):
            applyPull(pull, to: &task)
            let content = ReminderContent(task: task, projectName: reminderProjectName(task))
            var seen = remote?.content ?? content
            if push {
                do {
                    seen = try remindersService.write(content, taskID: task.id, reminderID: reminderID).content
                } catch {
                    NSLog("RemindersSync: could not update a reminder: %@", error.localizedDescription)
                    return task
                }
            }
            task.reminderID = reminderID
            task.reminderSnapshot = ReminderSyncSnapshot(pushed: content, seen: seen)
        case .closeDeleted:
            if !task.isCompleted { setCompleted(true, on: &task) }
            task.reminderID = nil
            task.reminderSnapshot = nil
        case .remove(let reminderID):
            if let reminderID {
                do {
                    try remindersService.deleteReminderNow(withID: reminderID)
                } catch {
                    NSLog("RemindersSync: could not delete a reminder: %@", error.localizedDescription)
                    return task
                }
            }
            task.reminderID = nil
            task.reminderSnapshot = nil
        }
        return task
    }

    private func applyPull(_ pull: ReminderPull, to task: inout ProjectTask) {
        if let title = pull.title {
            task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let due = pull.due {
            task.dueDate = due?.date()
            task.hasDueTime = due?.hasTime ?? false
        }
        if let done = pull.isCompleted, done != task.isCompleted {
            setCompleted(done, on: &task)
        }
    }

    private func setCompleted(_ done: Bool, on task: inout ProjectTask) {
        guard task.isCompleted != done else { return }
        task.toggleCompleted()
    }

    /// The project name shown in the reminder's notes; nil for tasks without a project.
    private func reminderProjectName(_ task: ProjectTask) -> String? {
        guard let projectID = task.projectID else { return nil }
        return projects.first { $0.id == projectID }?.name
    }
}
