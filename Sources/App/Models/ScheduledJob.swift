// Purpose: ScheduledJob and ScheduledJobRun, a prompt Claude runs on a schedule inside a workspace
//          and the record of one run. Value types only; files and execution live elsewhere.
// Dependencies: Sources/App/Models/JobSchedule.swift
// RBAC: `access` is the job's permission level for the headless Claude run (read only, standard,
//       full); ScheduledJobRunner turns it into the CLI's tool allow and deny lists.
// Dependents: Sources/App/Store/ScheduledJobFiles.swift, Sources/App/Services/ScheduledJobRunner.swift,
//             Sources/App/Supporting/ScheduledJobStore.swift, Sources/App/Services/MCP/MCPJobTools.swift,
//             Sources/App/Views/ScheduledJobsView.swift and its editor and run views
// Notes: A job is identified by its slug, the file name of jobs/<slug>.md in its workspace, so a
//        title change never moves its runs. `activeSince` is reset whenever the schedule changes
//        or the job is switched on, so the scheduler never fires for a slot that passed before.

import Foundation

struct ScheduledJob: Equatable, Identifiable, Sendable {
    enum Access: String, CaseIterable, Sendable {
        /// Reads files, MinuteMind, the user's claude.ai connectors and the web; changes nothing.
        case readOnly = "read-only"
        /// Also writes files in the workspace, uses MinuteMind's tools except deleting, and every connector tool.
        case standard
        /// Everything, including shell commands and deleting in MinuteMind.
        case full

        var label: String {
            switch self {
            case .readOnly: return "Read only"
            case .standard: return "Standard"
            case .full: return "Full"
            }
        }

        var explanation: String {
            switch self {
            case .readOnly: return "Reads workspace files, MinuteMind, your Claude connectors (such as Outlook or Slack) and the web. Changes nothing."
            case .standard: return "Also writes files in this workspace, creates or updates tasks, notes and events, and can send through your Claude connectors. Cannot delete in MinuteMind or run commands."
            case .full: return "Everything, including shell commands and deleting in MinuteMind. Nobody confirms anything during a run."
            }
        }
    }

    enum Notify: String, CaseIterable, Sendable {
        case always, failures, never

        var label: String {
            switch self {
            case .always: return "Every run"
            case .failures: return "Only failures"
            case .never: return "Never"
            }
        }
    }

    /// The Claude model aliases a job can pick; nil on the job means the app setting.
    static let models = ["sonnet", "opus", "haiku"]

    /// The slug: jobs/<id>.md.
    var id: String
    var title: String
    var prompt: String
    var schedule = JobSchedule()
    var enabled = true
    var access: Access = .standard
    /// "sonnet", "opus" or "haiku"; nil uses Settings, AI.
    var model: String?
    var notify: Notify = .always
    var created: Date
    /// Slots before this moment never fire.
    var activeSince: Date

    init(id: String, title: String, prompt: String, created: Date = Date()) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.created = created
        self.activeSince = created
    }
}

struct ScheduledJobRun: Equatable, Identifiable, Sendable {
    enum Status: String, Sendable {
        case succeeded, failed, cancelled
    }

    enum Trigger: String, Sendable {
        /// On time.
        case schedule
        /// For a slot that passed while the Mac slept or MinuteMind was closed.
        case catchUp = "catch-up"
        /// Run Now, in the app or over MCP.
        case manual
    }

    /// File name without extension: jobs/<job>/runs/<id>.md.
    var id: String
    var jobID: String
    var status: Status
    var trigger: Trigger
    /// The slot the run was for (schedule and catch-up runs).
    var scheduled: Date?
    var started: Date
    var finished: Date
    var model: String
    var access: ScheduledJob.Access
    /// Claude's final reply, or what went wrong.
    var output: String

    var duration: TimeInterval { finished.timeIntervalSince(started) }

    /// The first non-empty line, without Markdown heading marks, for lists.
    var headline: String {
        let line = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "#* ")).trimmingCharacters(in: .whitespaces)
    }
}
