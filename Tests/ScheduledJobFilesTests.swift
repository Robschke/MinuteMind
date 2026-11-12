// Purpose: Tests for the job and run files: round trips, forgiving parsing of hand-edited files,
//          slugs, run ids and the latest scheduled slot.
// Dependencies: Sources/App/Store/ScheduledJobFiles.swift, Sources/App/Models/ScheduledJob.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("ScheduledJobFiles Tests")
struct ScheduledJobFilesTests {
    private func temporaryRepo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let created = Date(timeIntervalSince1970: 1_794_000_000)

    @Test("A job survives a round trip through its file")
    func jobRoundTrip() throws {
        var job = ScheduledJob(id: "daily-brief", title: "Daily \"Brief\": today", prompt: "Summarize today.\n\n- meetings\n- todos", created: created)
        job.schedule = JobSchedule(cadence: .hourly, time: JobTime(hour: 8, minute: 30), until: JobTime(hour: 17, minute: 30), days: [.monday, .friday])
        job.access = .readOnly
        job.model = "opus"
        job.notify = .failures
        job.enabled = false
        job.activeSince = created.addingTimeInterval(3600)

        let text = ScheduledJobFiles.render(job)
        #expect(text.contains("schedule: hourly"))
        #expect(text.contains("days: [mon, fri]"))
        #expect(!text.contains("day: mon\n"))
        #expect(ScheduledJobFiles.parseJob(text, id: "daily-brief") == job)
    }

    @Test("Weekly jobs write their day, daily jobs every day as the full week")
    func cadenceKeys() {
        var job = ScheduledJob(id: "w", title: "W", prompt: "p", created: created)
        job.schedule = JobSchedule(cadence: .weekly, time: JobTime(hour: 9, minute: 0), weekday: .thursday)
        let weekly = ScheduledJobFiles.render(job)
        #expect(weekly.contains("day: thu"))
        #expect(!weekly.contains("days:"))
        job.schedule = JobSchedule(cadence: .daily, time: JobTime(hour: 9, minute: 0), days: [])
        #expect(ScheduledJobFiles.render(job).contains("days: [mon, tue, wed, thu, fri, sat, sun]"))
        #expect(ScheduledJobFiles.parseJob(ScheduledJobFiles.render(job), id: "w")?.schedule.days == [])
    }

    @Test("Hand-written files parse with defaults; files without frontmatter are no jobs")
    func forgivingParse() throws {
        let text = """
            ---
            title: Morning check   # a comment
            schedule: daily
            time: 7:45
            days: mon, wed
            something_else: ignored
            ---
            Look at my calendar.
            """
        let job = try #require(ScheduledJobFiles.parseJob(text, id: "morning"))
        #expect(job.title == "Morning check")
        #expect(job.schedule.time == JobTime(hour: 7, minute: 45))
        #expect(job.schedule.days == [.monday, .wednesday])
        #expect(job.access == .standard)
        #expect(job.model == nil)
        #expect(job.enabled)
        #expect(job.prompt == "Look at my calendar.")
        #expect(ScheduledJobFiles.parseJob("Just a note", id: "x") == nil)
    }

    @Test("Slugs are ASCII, short and unique in the repo")
    func slugs() throws {
        #expect(ScheduledJobFiles.slug("Tägliches Briefing: Größe!") == "tagliches-briefing-grosse")
        #expect(ScheduledJobFiles.slug("   ") == "job")
        let repo = try temporaryRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try ScheduledJobFiles.save(ScheduledJob(id: "brief", title: "Brief", prompt: "p", created: created), in: repo)
        #expect(ScheduledJobFiles.uniqueSlug(for: "Brief", in: repo) == "brief-2")
    }

    @Test("Runs are stored newest first and the latest scheduled slot skips manual runs")
    func runs() throws {
        let repo = try temporaryRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let slot = created
        let first = ScheduledJobRun(
            id: ScheduledJobFiles.newRunID(started: slot, jobID: "brief", in: repo), jobID: "brief", status: .succeeded,
            trigger: .schedule, scheduled: slot, started: slot, finished: slot.addingTimeInterval(42),
            model: "sonnet", access: .standard, output: "## Today\n- three meetings")
        try ScheduledJobFiles.writeRun(first, in: repo)
        let manualStart = slot.addingTimeInterval(7200)
        let manual = ScheduledJobRun(
            id: ScheduledJobFiles.newRunID(started: manualStart, jobID: "brief", in: repo), jobID: "brief", status: .failed,
            trigger: .manual, scheduled: nil, started: manualStart, finished: manualStart.addingTimeInterval(3),
            model: "opus", access: .full, output: "Claude Code is not installed.")
        try ScheduledJobFiles.writeRun(manual, in: repo)

        let runs = ScheduledJobFiles.loadRuns("brief", in: repo)
        #expect(runs.map(\.id) == [manual.id, first.id])
        #expect(runs.last == first)
        #expect(runs.last?.headline == "Today")
        #expect(ScheduledJobFiles.lastScheduledSlot("brief", in: repo) == slot)
        // Same minute again: a suffix keeps both.
        #expect(ScheduledJobFiles.newRunID(started: slot, jobID: "brief", in: repo) == first.id + "-2")
        ScheduledJobFiles.delete("brief", in: repo)
        #expect(ScheduledJobFiles.runIDs("brief", in: repo).isEmpty)
    }
}
