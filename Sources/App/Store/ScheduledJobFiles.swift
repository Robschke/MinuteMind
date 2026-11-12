// Purpose: ScheduledJobFiles, reads and writes scheduled jobs and their runs as Markdown files in a
//          workspace repo: jobs/<slug>.md (settings in the frontmatter, the prompt as the body) and
//          jobs/<slug>/runs/<yyyy-MM-dd-HHmm>.md (run metadata in the frontmatter, Claude's reply as
//          the body).
// Dependencies: Sources/App/Models/ScheduledJob.swift, Sources/App/Models/JobSchedule.swift
// RBAC: None.
// Dependents: Sources/App/Supporting/ScheduledJobStore.swift, Sources/App/Services/ScheduledJobRunner.swift,
//             Tests/ScheduledJobFilesTests.swift
// Notes: The files are the source of truth so that Claude in the workspace terminal can read and
//        edit jobs like any other file, git keeps their history, and run results are plain
//        Markdown next to the meetings and knowledge. The parser is deliberately forgiving: unknown
//        keys are ignored and missing ones take defaults, because people and Claude edit these files
//        by hand. Only the keys the cadence uses are written, so a file reads like its schedule.

import Foundation

enum ScheduledJobFiles {
    static let folderName = "jobs"

    static func jobsFolder(in repo: URL) -> URL {
        repo.appendingPathComponent(folderName, isDirectory: true)
    }

    static func jobFile(_ jobID: String, in repo: URL) -> URL {
        jobsFolder(in: repo).appendingPathComponent("\(jobID).md")
    }

    static func runsFolder(_ jobID: String, in repo: URL) -> URL {
        jobsFolder(in: repo).appendingPathComponent(jobID, isDirectory: true).appendingPathComponent("runs", isDirectory: true)
    }

    static func runFile(_ runID: String, jobID: String, in repo: URL) -> URL {
        runsFolder(jobID, in: repo).appendingPathComponent("\(runID).md")
    }

    /// The run file's path relative to the repo, for git and for opening it in the workspace.
    static func relativeRunPath(_ runID: String, jobID: String) -> String {
        "\(folderName)/\(jobID)/runs/\(runID).md"
    }

    // MARK: - Jobs

    /// Every job in the repo, sorted by title. Files that are not jobs (no frontmatter) are skipped.
    static func loadJobs(in repo: URL) -> [ScheduledJob] {
        let folder = jobsFolder(in: repo)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parseJob(text, id: url.deletingPathExtension().lastPathComponent)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func save(_ job: ScheduledJob, in repo: URL) throws {
        try FileManager.default.createDirectory(at: jobsFolder(in: repo), withIntermediateDirectories: true)
        try Data(render(job).utf8).write(to: jobFile(job.id, in: repo), options: .atomic)
    }

    /// Removes the job file and all its runs.
    static func delete(_ jobID: String, in repo: URL) {
        try? FileManager.default.removeItem(at: jobFile(jobID, in: repo))
        try? FileManager.default.removeItem(at: jobsFolder(in: repo).appendingPathComponent(jobID, isDirectory: true))
    }

    /// A slug for a new job that no other job in the repo uses yet.
    static func uniqueSlug(for title: String, in repo: URL) -> String {
        let base = slug(title)
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: jobFile(candidate, in: repo).path)
            || FileManager.default.fileExists(atPath: jobsFolder(in: repo).appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "ß", with: "ss")
        var result = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-"), !result.isEmpty {
                result.append("-")
            }
        }
        let trimmed = String(result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "job" : trimmed
    }

    // MARK: - Runs

    /// Run ids of a job, newest first (ids sort by start time).
    static func runIDs(_ jobID: String, in repo: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: runsFolder(jobID, in: repo), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted(by: >)
    }

    static func loadRun(_ runID: String, jobID: String, in repo: URL) -> ScheduledJobRun? {
        guard let text = try? String(contentsOf: runFile(runID, jobID: jobID, in: repo), encoding: .utf8) else { return nil }
        return parseRun(text, id: runID, jobID: jobID)
    }

    /// The newest runs of a job, at most `limit`.
    static func loadRuns(_ jobID: String, in repo: URL, limit: Int = 100) -> [ScheduledJobRun] {
        runIDs(jobID, in: repo).prefix(limit).compactMap { loadRun($0, jobID: jobID, in: repo) }
    }

    /// The slot of the newest run that ran for a slot (schedule or catch-up); nil when none did.
    static func lastScheduledSlot(_ jobID: String, in repo: URL, lookBack: Int = 60) -> Date? {
        runIDs(jobID, in: repo).prefix(lookBack).lazy.compactMap { loadRun($0, jobID: jobID, in: repo)?.scheduled }.first
    }

    /// An id for a run starting at `started`: its minute, with -2, -3 ... when taken.
    static func newRunID(started: Date, jobID: String, in repo: URL) -> String {
        let base = runIDFormatter.string(from: started)
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: runFile(candidate, jobID: jobID, in: repo).path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    static func writeRun(_ run: ScheduledJobRun, in repo: URL) throws {
        try FileManager.default.createDirectory(at: runsFolder(run.jobID, in: repo), withIntermediateDirectories: true)
        try Data(render(run).utf8).write(to: runFile(run.id, jobID: run.jobID, in: repo), options: .atomic)
    }

    private static let runIDFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    // MARK: - Format

    static func render(_ job: ScheduledJob) -> String {
        let schedule = job.schedule
        var lines = [
            "---",
            "title: \(quoted(job.title))",
            "enabled: \(job.enabled)",
            "schedule: \(schedule.cadence.rawValue)",
        ]
        switch schedule.cadence {
        case .hourly:
            lines += ["time: \"\(schedule.time.text)\"", "until: \"\(schedule.until.text)\"", "days: \(daysList(schedule.days))"]
        case .daily:
            lines += ["time: \"\(schedule.time.text)\"", "days: \(daysList(schedule.days))"]
        case .weekly:
            lines += ["day: \(schedule.weekday.code)", "time: \"\(schedule.time.text)\""]
        }
        lines += [
            "access: \(job.access.rawValue)",
            "model: \(job.model ?? "default")",
            "notify: \(job.notify.rawValue)",
            "created: \(isoString(job.created))",
            "active_since: \(isoString(job.activeSince))",
            "---",
            "",
            job.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
        ]
        return lines.joined(separator: "\n")
    }

    static func parseJob(_ text: String, id: String) -> ScheduledJob? {
        guard let (fields, body) = frontmatter(text) else { return nil }
        let created = fields["created"].flatMap(parseDate) ?? Date(timeIntervalSince1970: 0)
        var job = ScheduledJob(id: id, title: fields["title"].map(unquoted) ?? id, prompt: body, created: created)
        job.activeSince = fields["active_since"].flatMap(parseDate) ?? created
        job.enabled = fields["enabled"].map { $0.lowercased() != "false" && $0.lowercased() != "no" } ?? true
        job.access = fields["access"].flatMap { ScheduledJob.Access(rawValue: $0.lowercased()) } ?? .standard
        job.notify = fields["notify"].flatMap { ScheduledJob.Notify(rawValue: $0.lowercased()) } ?? .always
        let model = fields["model"]?.lowercased()
        job.model = ScheduledJob.models.contains(model ?? "") ? model : nil

        var schedule = JobSchedule()
        schedule.cadence = fields["schedule"].flatMap { JobSchedule.Cadence(rawValue: $0.lowercased()) } ?? .daily
        if let time = fields["time"].flatMap({ JobTime(unquoted($0)) }) { schedule.time = time }
        if let until = fields["until"].flatMap({ JobTime(unquoted($0)) }) { schedule.until = until }
        if let day = fields["day"].flatMap({ JobWeekday(code: unquoted($0)) }) { schedule.weekday = day }
        if let days = fields["days"] { schedule.days = parseDays(days) }
        job.schedule = schedule
        return job
    }

    static func render(_ run: ScheduledJobRun) -> String {
        var lines = [
            "---",
            "job: \(run.jobID)",
            "status: \(run.status.rawValue)",
            "trigger: \(run.trigger.rawValue)",
        ]
        if let scheduled = run.scheduled { lines.append("scheduled: \(isoString(scheduled))") }
        lines += [
            "started: \(isoString(run.started))",
            "finished: \(isoString(run.finished))",
            "model: \(run.model)",
            "access: \(run.access.rawValue)",
            "---",
            "",
            run.output.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
        ]
        return lines.joined(separator: "\n")
    }

    static func parseRun(_ text: String, id: String, jobID: String) -> ScheduledJobRun? {
        guard let (fields, body) = frontmatter(text),
              let started = fields["started"].flatMap(parseDate) else { return nil }
        return ScheduledJobRun(
            id: id,
            jobID: jobID,
            status: fields["status"].flatMap { ScheduledJobRun.Status(rawValue: $0) } ?? .failed,
            trigger: fields["trigger"].flatMap { ScheduledJobRun.Trigger(rawValue: $0) } ?? .manual,
            scheduled: fields["scheduled"].flatMap(parseDate),
            started: started,
            finished: fields["finished"].flatMap(parseDate) ?? started,
            model: fields["model"] ?? "",
            access: fields["access"].flatMap { ScheduledJob.Access(rawValue: $0) } ?? .standard,
            output: body)
    }

    // MARK: - Helpers

    /// The frontmatter's key/value pairs and the trimmed body, or nil without frontmatter.
    static func frontmatter(_ text: String) -> (fields: [String: String], body: String)? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // A trailing comment, outside quotes.
            if !value.hasPrefix("\""), let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if !key.isEmpty { fields[key] = value }
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields, body)
    }

    static func quoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, let first = trimmed.first, first == "\"" || first == "'", trimmed.last == first {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return trimmed
    }

    private static func daysList(_ days: Set<JobWeekday>) -> String {
        let all = days.isEmpty ? JobWeekday.weekOrder : days.sorted()
        return "[" + all.map(\.code).joined(separator: ", ") + "]"
    }

    /// "[mon, tue]", "mon, tue", "every day" / "daily" (all days).
    static func parseDays(_ text: String) -> Set<JobWeekday> {
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] \"'")).lowercased()
        if cleaned.isEmpty || cleaned == "every day" || cleaned == "daily" || cleaned == "all" { return [] }
        let days = Set(cleaned.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { JobWeekday(code: String($0)) })
        return days.count == 7 ? [] : days
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseDate(_ text: String) -> Date? {
        let value = unquoted(text)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
