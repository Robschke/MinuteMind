// Purpose: Tests for TaskReminderSync, the rules of the two-way sync between tasks and Apple
//          Reminders: which tasks belong there, what changes flow which way, deleted and
//          imported reminders.
// Dependencies: Sources/App/Services/TaskReminderSync.swift, Sources/App/Models/Project.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("TaskReminderSync Tests")
struct TaskReminderSyncTests {
    private let projectName = "Acme"
    private let due = ReminderDue(year: 2026, month: 11, day: 27, hour: 16, minute: 0)

    private func openTask(bell: Bool = false) -> ProjectTask {
        ProjectTask(
            projectID: UUID(), title: "Send the offer", dueDate: due.date(), hasDueTime: true,
            priority: .high, reminderEnabled: bell)
    }

    /// A task linked to a reminder that matches it, as after a sync.
    private func linked(_ task: ProjectTask, id: String = "r1") -> (ProjectTask, RemoteReminder) {
        var task = task
        let content = ReminderContent(task: task, projectName: projectName)
        task.reminderID = id
        task.reminderSnapshot = ReminderSyncSnapshot(pushed: content, seen: content)
        return (task, RemoteReminder(id: id, marker: task.id, content: content))
    }

    private func decide(_ task: ProjectTask, _ remote: RemoteReminder?, syncAll: Bool = true, canTell: Bool = true)
        -> TaskReminderSync.Decision
    {
        TaskReminderSync.decide(
            task: task, desired: ReminderContent(task: task, projectName: projectName), remote: remote,
            syncAll: syncAll, canTellDeleted: canTell)
    }

    @Test("Sync all takes every accepted task unless its bell excludes it; otherwise only the bell counts")
    func selection() {
        var task = openTask()
        #expect(TaskReminderSync.isSelected(task, syncAll: true))
        #expect(!TaskReminderSync.isSelected(task, syncAll: false))
        task.reminderExcluded = true
        #expect(!TaskReminderSync.isSelected(task, syncAll: true))
        task.reminderEnabled = true
        #expect(TaskReminderSync.isSelected(task, syncAll: false))
        var pending = openTask(bell: true)
        pending.needsReview = true
        #expect(!TaskReminderSync.isSelected(pending, syncAll: true))
        #expect(!TaskReminderSync.isSelected(pending, syncAll: false))
    }

    @Test("Open tasks get a reminder, done ones only keep theirs")
    func createOnlyForOpenTasks() {
        var task = openTask()
        #expect(decide(task, nil) == .create)
        task.toggleCompleted()
        #expect(decide(task, nil) == .nothing)
        #expect(decide(openTask(), nil, syncAll: false) == .nothing)
    }

    @Test("An unchanged pair writes nothing")
    func unchangedIsQuiet() {
        let (task, remote) = linked(openTask())
        #expect(decide(task, remote) == .sync(reminderID: "r1", pull: ReminderPull(), push: false))
    }

    @Test("A change in MinuteMind is pushed")
    func pushesLocalChange() {
        var (task, remote) = linked(openTask())
        task.title = "Send the revised offer"
        #expect(decide(task, remote) == .sync(reminderID: "r1", pull: ReminderPull(), push: true))
        task.title = "Send the offer"
        task.toggleCompleted()
        #expect(decide(task, remote) == .sync(reminderID: "r1", pull: ReminderPull(), push: true))
    }

    @Test("Ticked off, renamed or redated in Reminders comes back without a write")
    func pullsRemoteChanges() {
        let (task, original) = linked(openTask())
        var remote = original
        remote.content.isCompleted = true
        remote.content.title = "Offer sent?"
        let newDue = ReminderDue(year: 2026, month: 12, day: 1)
        remote.content.due = newDue
        let expected = ReminderPull(title: "Offer sent?", due: .some(newDue), isCompleted: true)
        #expect(decide(task, remote) == .sync(reminderID: "r1", pull: expected, push: false))

        remote.content.due = nil
        guard case .sync(_, let pull, _) = decide(task, remote) else {
            Issue.record("expected a sync")
            return
        }
        #expect(pull.due == .some(nil))
    }

    @Test("Notes edited in Reminders stay until the task changes")
    func remoteNotesStay() {
        var (task, remote) = linked(openTask())
        remote.content.notes = "my own note"
        #expect(decide(task, remote) == .sync(reminderID: "r1", pull: ReminderPull(), push: false))
        task.priority = .low
        #expect(decide(task, remote) == .sync(reminderID: "r1", pull: ReminderPull(), push: true))
    }

    @Test("Both sides changed: Reminders wins the field, MinuteMind's other changes are pushed")
    func conflict() {
        var (task, remote) = linked(openTask())
        task.title = "Mine"
        task.priority = .low
        remote.content.title = "Theirs"
        #expect(decide(task, remote) == .sync(reminderID: "r1", pull: ReminderPull(title: "Theirs"), push: true))
    }

    @Test("A reminder deleted in Reminders closes its task, unless the list could not be read")
    func deletedReminder() {
        let (task, _) = linked(openTask())
        #expect(decide(task, nil) == .closeDeleted)
        #expect(decide(task, nil, canTell: false) == .nothing)
    }

    @Test("Taking a task out removes its reminder")
    func removal() {
        var (task, remote) = linked(openTask())
        task.reminderExcluded = true
        #expect(decide(task, remote) == .remove(reminderID: "r1"))
        #expect(decide(task, nil) == .remove(reminderID: nil))
        let (bellTask, bellRemote) = linked(openTask(bell: false))
        #expect(decide(bellTask, bellRemote, syncAll: false) == .remove(reminderID: "r1"))
    }

    @Test("A reminder found by its marker under a new identifier is relinked")
    func relinkByMarker() {
        var (task, remote) = linked(openTask())
        remote.id = "r1-after-icloud-resync"
        task.reminderID = "r1"
        #expect(decide(task, remote) == .sync(reminderID: "r1-after-icloud-resync", pull: ReminderPull(), push: false))
    }

    @Test("Tasks linked by older builds only take over a tick from Reminders")
    func legacyLink() {
        var task = openTask(bell: true)
        task.reminderID = "old"
        var content = ReminderContent(task: task, projectName: projectName)
        content.title = "edited there"
        content.isCompleted = true
        let remote = RemoteReminder(id: "old", marker: nil, content: content)
        #expect(decide(task, remote, syncAll: false)
            == .sync(reminderID: "old", pull: ReminderPull(isCompleted: true), push: true))
    }

    @Test("Only open reminders without a MinuteMind marker are imported")
    func imports() {
        let content = ReminderContent(title: "Call Anna", notes: "about Friday", priority: 1, due: due, isCompleted: false)
        let fresh = RemoteReminder(id: "a", marker: nil, content: content)
        let fromMinuteMind = RemoteReminder(id: "b", marker: UUID(), content: content)
        var done = fresh
        done.id = "c"
        done.content.isCompleted = true
        var linkedOne = fresh
        linkedOne.id = "d"
        let result = TaskReminderSync.remindersToImport([fresh, fromMinuteMind, done, linkedOne], linkedIDs: ["d"])
        #expect(result.map(\.id) == ["a"])

        let task = TaskReminderSync.task(importing: fresh)
        #expect(task.title == "Call Anna")
        #expect(task.projectID == nil)
        #expect(task.priority == .critical)
        #expect(task.hasDueTime)
        #expect(task.reminderID == "a")
        #expect(task.reminderEnabled)
        #expect(ReminderContent(task: task, projectName: nil).notes == "about Friday")
    }

    @Test("The marker URL round-trips and ignores other URLs")
    func marker() {
        let id = UUID()
        #expect(TaskReminderSync.taskID(fromMarker: TaskReminderSync.markerURL(for: id)) == id)
        #expect(TaskReminderSync.taskID(fromMarker: URL(string: "https://example.com/task/\(id)")) == nil)
        #expect(TaskReminderSync.taskID(fromMarker: nil) == nil)
    }

    @Test("Notes carry project and assignee, the format older builds wrote")
    func notesFormat() {
        var task = openTask()
        task.assignee = "Sam"
        task.notes = "Draft is in the drive."
        #expect(ReminderContent(task: task, projectName: "Acme").notes
            == "Project: Acme\nAssignee: Sam\n\nDraft is in the drive.\n\n[Synced from MinuteMind]")
    }

    @Test("Due dates keep a time only when the task has one")
    func dueDates() {
        let date = due.date()!
        #expect(ReminderDue(date: date, hasTime: true) == due)
        let dayOnly = ReminderDue(date: date, hasTime: false)
        #expect(!dayOnly.hasTime)
        #expect(dayOnly.minute == nil)
        #expect(ReminderDue(components: DateComponents(year: 2026, month: 1)) == nil)
    }
}
