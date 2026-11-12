// Purpose: MCPJobTools, the MCP tools for scheduled jobs: list, read, create, update, delete, run
//          now, and read their runs, so Claude can set up and manage jobs from any session.
// Dependencies: Sources/App/Supporting/ScheduledJobStore.swift (jobs, runs, queue),
//               Sources/App/ViewModels/AppViewModel.swift (scheduledJobs, projects),
//               Sources/App/Store/ScheduledJobFiles.swift (day and time parsing)
// Used by: Sources/App/Services/MCP/MinuteMindMCPServer.swift
// RBAC: none inside the app; every MCP client holding the bearer token may manage jobs, including
//       raising a job's access to "full". delete_job carries destructiveHint (delete_ prefix) and is
//       blocked for jobs running with standard access.
// Notes: Same OpenAI function shape as MCPMeetingTools. Jobs live per workspace: project_id is a
//        project UUID or the General workspace's all-zero UUID. Changes are written and committed
//        at once.

import Foundation

@MainActor
struct MCPJobTools {
    let appViewModel: AppViewModel

    static let names: Set<String> = [
        "list_jobs", "get_job", "create_job", "update_job", "delete_job", "run_job_now", "list_job_runs", "get_job_run",
    ]

    private static let generalNote = "Project UUID (see list_projects), or 00000000-0000-0000-0000-000000000000 for the General workspace."

    private static var settingProperties: [String: Any] {
        [
            "title": ["type": "string", "description": "Short name shown in the Jobs tab."],
            "prompt": ["type": "string", "description": "What Claude should do on every run. Claude runs headless in the workspace folder with MinuteMind's tools; its final message becomes the run's result (Markdown)."],
            "cadence": ["type": "string", "enum": ["hourly", "daily", "weekly"], "description": "hourly: every full hour from time to until. daily: once at time. weekly: once on weekday at time."],
            "time": ["type": "string", "description": "HH:mm, local time. Daily and weekly: the run time. Hourly: the first run of the day."],
            "until": ["type": "string", "description": "HH:mm, hourly only: the last run of the day (inclusive)."],
            "days": ["type": "array", "items": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]], "description": "Hourly and daily: weekdays it runs on. Empty or omitted on create: Monday to Friday. Pass all seven for every day."],
            "weekday": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"], "description": "Weekly only."],
            "access": ["type": "string", "enum": ["read-only", "standard", "full"], "description": "read-only: reads files, MinuteMind and the web. standard (default): also writes workspace files and creates or updates tasks, notes, events; no deleting, no shell. full: also shell commands and deleting. Use full only when the user asks for it."],
            "model": ["type": "string", "enum": ["default", "sonnet", "opus", "haiku"], "description": "Claude model; default uses MinuteMind's AI setting."],
            "notify": ["type": "string", "enum": ["always", "failures", "never"], "description": "When to show a macOS notification. Default always."],
            "enabled": ["type": "boolean", "description": "Whether the schedule is active. Default true."],
        ]
    }

    static var definitions: [[String: Any]] {
        let project: [String: Any] = ["type": "string", "description": generalNote]
        let jobID: [String: Any] = ["type": "string", "description": "Job id (its slug, from list_jobs)."]
        var create = settingProperties
        create["project_id"] = project
        var update = settingProperties
        update["project_id"] = project
        update["job_id"] = jobID
        return [
            function(
                "list_jobs",
                "List scheduled jobs: prompts MinuteMind has Claude run on a schedule inside a workspace. Shows schedule, access, model, next run and the latest run's status.",
                properties: ["project_id": ["type": "string", "description": "Optional. " + generalNote + " Omit for every workspace."]],
                required: []),
            function(
                "get_job",
                "Get one scheduled job with its prompt, settings, next run and its five latest runs.",
                properties: ["project_id": project, "job_id": jobID],
                required: ["project_id", "job_id"]),
            function(
                "create_job",
                "Create a scheduled job in a workspace. It first runs at the next slot after now (a time that already passed today does not fire). Stored as jobs/<id>.md in the workspace.",
                properties: create,
                required: ["project_id", "title", "prompt", "cadence", "time"]),
            function(
                "update_job",
                "Change a scheduled job. Only the fields given change. A new schedule, or switching it on, takes effect from now on.",
                properties: update,
                required: ["project_id", "job_id"]),
            function(
                "delete_job",
                "Delete a scheduled job and its run history (git keeps both in the workspace history).",
                properties: ["project_id": project, "job_id": jobID],
                required: ["project_id", "job_id"]),
            function(
                "run_job_now",
                "Run a scheduled job right away, outside its schedule. Runs one at a time in the background; check list_job_runs for the result.",
                properties: ["project_id": project, "job_id": jobID],
                required: ["project_id", "job_id"]),
            function(
                "list_job_runs",
                "List a job's runs, newest first: status, trigger (schedule, catch-up, manual), times, model and the first line of the result.",
                properties: [
                    "project_id": project, "job_id": jobID,
                    "limit": ["type": "integer", "description": "Maximum number of runs. Default 20."],
                ],
                required: ["project_id", "job_id"]),
            function(
                "get_job_run",
                "Get one run of a job with its full result (Claude's final message, Markdown).",
                properties: [
                    "project_id": project, "job_id": jobID,
                    "run_id": ["type": "string", "description": "Run id from list_job_runs."],
                ],
                required: ["project_id", "job_id", "run_id"]),
        ]
    }

    private var store: ScheduledJobStore { appViewModel.scheduledJobs }

    func execute(toolName: String, arguments: [String: Any]) async throws -> String {
        switch toolName {
        case "list_jobs": return try listJobs(arguments)
        case "get_job": return try getJob(arguments)
        case "create_job": return try createJob(arguments)
        case "update_job": return try updateJob(arguments)
        case "delete_job": return try deleteJob(arguments)
        case "run_job_now": return try runNow(arguments)
        case "list_job_runs": return try listRuns(arguments)
        case "get_job_run": return try getRun(arguments)
        default: throw ToolError.invalidArguments("Unknown tool \(toolName)")
        }
    }

    // MARK: - Tools

    private func listJobs(_ args: [String: Any]) throws -> String {
        let projectIDs: [UUID]
        if let raw = args["project_id"] as? String {
            projectIDs = [try workspace(raw)]
        } else {
            // Only workspaces that exist: reading a project's jobs would otherwise create its repo.
            projectIDs = appViewModel.projectRepositories.existingRepositories().map(\.projectID)
                .filter { appViewModel.scheduledJobWorkspaceName($0) != nil }
        }
        var items: [[String: Any]] = []
        for projectID in projectIDs {
            store.reload(projectID)
            items += store.jobs(for: projectID).map { summary($0, projectID: projectID) }
        }
        return try json(["count": items.count, "jobs": items])
    }

    private func getJob(_ args: [String: Any]) throws -> String {
        let (projectID, job) = try existingJob(args)
        var result = summary(job, projectID: projectID)
        result["prompt"] = job.prompt
        result["recent_runs"] = store.runs(ScheduledJobKey(projectID: projectID, jobID: job.id), limit: 5).map(runSummary)
        return try json(result)
    }

    private func createJob(_ args: [String: Any]) throws -> String {
        let projectID = try workspace(args["project_id"] as? String)
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw ToolError.invalidArguments("title must not be empty")
        }
        guard let prompt = (args["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw ToolError.invalidArguments("prompt must not be empty")
        }
        var template = ScheduledJob(id: "new", title: title, prompt: prompt)
        try apply(args, to: &template)
        store.reload(projectID)
        let job = try store.create(in: projectID, title: title, prompt: prompt) { job in
            job.schedule = template.schedule
            job.access = template.access
            job.model = template.model
            job.notify = template.notify
            job.enabled = template.enabled
        }
        return try json(["success": true, "job": summary(job, projectID: projectID)])
    }

    private func updateJob(_ args: [String: Any]) throws -> String {
        let (projectID, existing) = try existingJob(args)
        var job = existing
        try apply(args, to: &job)
        if let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { job.title = title }
        if let prompt = (args["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty { job.prompt = prompt }
        store.update(in: projectID, job, immediately: true)
        let saved = store.job(ScheduledJobKey(projectID: projectID, jobID: job.id)) ?? job
        return try json(["success": true, "job": summary(saved, projectID: projectID)])
    }

    private func deleteJob(_ args: [String: Any]) throws -> String {
        let (projectID, job) = try existingJob(args)
        store.delete(ScheduledJobKey(projectID: projectID, jobID: job.id))
        return try json(["success": true, "deleted_job_id": job.id, "title": job.title])
    }

    private func runNow(_ args: [String: Any]) throws -> String {
        let (projectID, job) = try existingJob(args)
        let key = ScheduledJobKey(projectID: projectID, jobID: job.id)
        if store.isRunning(key) { return try json(["started": false, "reason": "The job is running right now."]) }
        let queued = store.runNow(key)
        return try json(["started": queued, "reason": queued ? "Queued; jobs run one at a time." : "The job is already waiting to run."])
    }

    private func listRuns(_ args: [String: Any]) throws -> String {
        let (projectID, job) = try existingJob(args)
        let limit = max(1, (args["limit"] as? Int) ?? 20)
        let runs = store.runs(ScheduledJobKey(projectID: projectID, jobID: job.id), limit: limit).map(runSummary)
        return try json(["count": runs.count, "runs": runs])
    }

    private func getRun(_ args: [String: Any]) throws -> String {
        let (projectID, job) = try existingJob(args)
        guard let runID = args["run_id"] as? String,
              let run = store.run(ScheduledJobKey(projectID: projectID, jobID: job.id), runID: runID) else {
            throw ToolError.invalidArguments("No run with that run_id")
        }
        var result = runSummary(run)
        result["output"] = run.output
        result["file"] = ScheduledJobFiles.relativeRunPath(run.id, jobID: job.id)
        return try json(result)
    }

    // MARK: - Settings

    /// Applies the optional setting fields of a create or update call.
    private func apply(_ args: [String: Any], to job: inout ScheduledJob) throws {
        if let raw = args["cadence"] as? String {
            guard let cadence = JobSchedule.Cadence(rawValue: raw.lowercased()) else {
                throw ToolError.invalidArguments("cadence must be hourly, daily or weekly")
            }
            job.schedule.cadence = cadence
        }
        if let raw = args["time"] as? String {
            guard let time = JobTime(raw) else { throw ToolError.invalidArguments("time must be HH:mm") }
            job.schedule.time = time
        }
        if let raw = args["until"] as? String {
            guard let until = JobTime(raw) else { throw ToolError.invalidArguments("until must be HH:mm") }
            job.schedule.until = until
        }
        if let raw = args["days"] {
            let text = (raw as? [String])?.joined(separator: ",") ?? (raw as? String) ?? ""
            job.schedule.days = text.isEmpty ? JobWeekday.workdays : ScheduledJobFiles.parseDays(text)
        }
        if let raw = args["weekday"] as? String {
            guard let day = JobWeekday(code: raw) else { throw ToolError.invalidArguments("weekday must be mon to sun") }
            job.schedule.weekday = day
        }
        if let raw = args["access"] as? String {
            guard let access = ScheduledJob.Access(rawValue: raw.lowercased()) else {
                throw ToolError.invalidArguments("access must be read-only, standard or full")
            }
            job.access = access
        }
        if let raw = (args["model"] as? String)?.lowercased() {
            guard raw == "default" || ScheduledJob.models.contains(raw) else {
                throw ToolError.invalidArguments("model must be default, sonnet, opus or haiku")
            }
            job.model = raw == "default" ? nil : raw
        }
        if let raw = args["notify"] as? String {
            guard let notify = ScheduledJob.Notify(rawValue: raw.lowercased()) else {
                throw ToolError.invalidArguments("notify must be always, failures or never")
            }
            job.notify = notify
        }
        if let enabled = args["enabled"] as? Bool { job.enabled = enabled }
    }

    // MARK: - Helpers

    private func summary(_ job: ScheduledJob, projectID: UUID) -> [String: Any] {
        let key = ScheduledJobKey(projectID: projectID, jobID: job.id)
        var result: [String: Any] = [
            "id": job.id,
            "project_id": projectID.uuidString,
            "workspace": appViewModel.scheduledJobWorkspaceName(projectID) ?? NSNull(),
            "title": job.title,
            "schedule": job.schedule.summary,
            "cadence": job.schedule.cadence.rawValue,
            "time": job.schedule.time.text,
            "enabled": job.enabled,
            "access": job.access.rawValue,
            "model": job.model ?? "default",
            "notify": job.notify.rawValue,
            "file": "\(ScheduledJobFiles.folderName)/\(job.id).md",
        ]
        switch job.schedule.cadence {
        case .hourly:
            result["until"] = job.schedule.until.text
            result["days"] = days(job.schedule.days)
        case .daily:
            result["days"] = days(job.schedule.days)
        case .weekly:
            result["weekday"] = job.schedule.weekday.code
        }
        result["next_run"] = store.nextRun(of: job).map(ScheduledJobFiles.isoString) ?? NSNull()
        if store.isRunning(key) { result["state"] = "running" } else if store.isQueued(key) { result["state"] = "queued" }
        if let last = store.latestRuns[key] { result["last_run"] = runSummary(last) }
        return result
    }

    private func days(_ days: Set<JobWeekday>) -> [String] {
        (days.isEmpty ? JobWeekday.weekOrder : days.sorted()).map(\.code)
    }

    private func runSummary(_ run: ScheduledJobRun) -> [String: Any] {
        var result: [String: Any] = [
            "run_id": run.id,
            "status": run.status.rawValue,
            "trigger": run.trigger.rawValue,
            "started": ScheduledJobFiles.isoString(run.started),
            "duration_seconds": Int(run.duration.rounded()),
            "model": run.model,
            "headline": run.headline,
        ]
        if let scheduled = run.scheduled { result["scheduled"] = ScheduledJobFiles.isoString(scheduled) }
        return result
    }

    private func workspace(_ raw: String?) throws -> UUID {
        guard let raw else { throw ToolError.invalidArguments("project_id is required") }
        guard let id = UUID(uuidString: raw) else { throw ToolError.invalidArguments("project_id is not a valid UUID") }
        guard appViewModel.scheduledJobWorkspaceName(id) != nil else {
            throw ToolError.invalidArguments("No project with id \(raw)")
        }
        return id
    }

    private func existingJob(_ args: [String: Any]) throws -> (UUID, ScheduledJob) {
        let projectID = try workspace(args["project_id"] as? String)
        guard let jobID = args["job_id"] as? String else { throw ToolError.invalidArguments("job_id is required") }
        store.reload(projectID)
        guard let job = store.job(ScheduledJobKey(projectID: projectID, jobID: jobID)) else {
            throw ToolError.invalidArguments("No job \(jobID) in that workspace (see list_jobs)")
        }
        return (projectID, job)
    }

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func function(
        _ name: String, _ description: String, properties: [String: Any], required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": ["type": "object", "properties": properties, "required": required] as [String: Any],
            ] as [String: Any],
        ]
    }
}
