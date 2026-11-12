// Purpose: TerminalSessionStatus, what a workspace Claude session is doing (working, waiting for
//          the user, done, error, idle), derived from Claude Code hook events plus terminal
//          activity, so tabs and pane frames can show it.
// Dependencies: Foundation only (pure logic, unit tested in Tests/TerminalSessionStatusTests.swift)
// Used by: Sources/App/Supporting/WorkspaceTerminalStore.swift (reads each session's hook file
//          once a second), Sources/App/Services/ProjectRepositoryService.swift (writes the hook
//          settings whose command produces the payloads parsed here)
// Notes: User request 2026-10-13: orange = Claude needs feedback, green = done, blue = working,
//        red = error. Hooks are the source of truth because terminal output alone cannot tell a
//        finished turn from a permission prompt. Every Claude started in a workspace gets
//        `--settings claude-hooks.json`; each hook copies its JSON payload into the file named
//        by the session's MM_TERMINAL_STATUS variable, and the launch command writes a
//        `ClaudeExited` payload with the exit code when Claude quits.
//        Gaps the hooks leave, closed with terminal activity (`TerminalStatusTracker`):
//        - Esc interrupts a turn without a Stop hook: "working" with 4 s of silence (Claude's
//          spinner redraws constantly while it works) falls back to idle.
//        - Answering a prompt: "waiting" turns to working once output keeps coming 1.5 s after
//          the user typed (key echoes come back at once; Claude's spinner keeps printing).
//        - Claude versions without these hooks: printing = working, silence after printing =
//          done, the bell = waiting (the pre-hook heuristic).

import Foundation

enum TerminalSessionStatus: Equatable, Sendable {
    /// Started or reset, no turn yet (or Claude exited cleanly): no colour.
    case idle
    case working
    /// A permission prompt, a question or a plan to approve: Claude needs the user.
    case waiting
    /// The turn finished; stays until the next prompt.
    case done
    /// The turn ended with an API error, or Claude exited with a non-zero code.
    case error

    /// Maps one hook payload (the JSON Claude Code hands every hook on stdin, or the launch
    /// command's `ClaudeExited` payload) to a status; nil leaves the status as it is.
    static func fromHookPayload(_ data: Data) -> TerminalSessionStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["hook_event_name"] as? String
        else { return nil }
        switch event {
        case "SessionStart", "SessionEnd":
            return .idle
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PreCompact":
            return .working
        case "PreToolUse":
            let tool = object["tool_name"] as? String ?? ""
            return ["AskUserQuestion", "ExitPlanMode"].contains(tool) ? .waiting : .working
        case "PermissionRequest":
            return .waiting
        case "Notification":
            // idle_prompt only says Claude has been waiting for a new prompt for a while.
            let type = object["notification_type"] as? String ?? ""
            return ["permission_prompt", "elicitation_dialog"].contains(type) ? .waiting : nil
        case "Stop":
            return .done
        case "StopFailure":
            return .error
        case "ClaudeExited":
            let code = (object["exit_code"] as? NSNumber)?.intValue ?? 0
            return code == 0 ? .idle : .error
        default:
            return nil
        }
    }
}

/// Folds hook events and terminal activity into one status per session; `update` runs about
/// once a second.
struct TerminalStatusTracker: Equatable {
    struct Sample {
        /// The latest hook payload's status and when it was written (nil: no hook event yet).
        var hook: (status: TerminalSessionStatus?, date: Date)?
        var lastOutput: Date?
        var lastInput: Date?
        /// The terminal rang its bell since the last sample.
        var bell = false
        var now = Date()
    }

    /// Silence after which a "working" session counts as interrupted.
    static let interruptSilence: TimeInterval = 4
    /// Output this long after the user's last keystroke means Claude is running again.
    static let resumeDelay: TimeInterval = 1.5

    private(set) var status: TerminalSessionStatus = .idle
    private var since = Date.distantPast
    private var appliedHookDate: Date?

    @discardableResult
    mutating func update(_ sample: Sample) -> TerminalSessionStatus {
        if let hook = sample.hook, hook.date != appliedHookDate {
            appliedHookDate = hook.date
            if let status = hook.status { set(status, at: hook.date) }
        }
        if appliedHookDate != nil {
            applyHookGaps(sample)
        } else {
            applyFallback(sample)
        }
        return status
    }

    /// Back to idle with the hook history forgotten (a restarted session).
    mutating func reset(at date: Date = Date()) {
        self = TerminalStatusTracker()
        since = date
    }

    private mutating func set(_ status: TerminalSessionStatus, at date: Date) {
        self.status = status
        since = date
    }

    private mutating func applyHookGaps(_ sample: Sample) {
        switch status {
        case .working:
            let quietSince = max(since, sample.lastOutput ?? .distantPast)
            if sample.now.timeIntervalSince(quietSince) >= Self.interruptSilence {
                set(.idle, at: sample.now)
            }
        case .waiting:
            if let input = sample.lastInput, input > since, let output = sample.lastOutput,
               output.timeIntervalSince(input) >= Self.resumeDelay {
                set(.working, at: output)
            }
        case .idle, .done, .error:
            break
        }
    }

    private mutating func applyFallback(_ sample: Sample) {
        let printing = sample.lastOutput.map { sample.now.timeIntervalSince($0) < 2 } ?? false
        if sample.bell {
            set(.waiting, at: sample.now)
        } else if printing {
            if status != .working { set(.working, at: sample.now) }
        } else if status == .working {
            set(.done, at: sample.now)
        }
    }
}
