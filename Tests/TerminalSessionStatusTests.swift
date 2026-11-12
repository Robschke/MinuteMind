// Purpose: Tests for the Claude session status shown on workspace tabs and pane frames: hook
//          payloads to statuses, and the gaps filled from terminal activity (interrupts,
//          answered prompts, Claude versions without hooks).
// Dependencies: Sources/App/Supporting/TerminalSessionStatus.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("TerminalSessionStatus Tests")
struct TerminalSessionStatusTests {
    private func payload(_ fields: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
    }

    private func status(_ fields: [String: Any]) -> TerminalSessionStatus? {
        TerminalSessionStatus.fromHookPayload(payload(fields))
    }

    @Test func mapsHookEvents() {
        #expect(status(["hook_event_name": "UserPromptSubmit", "prompt": "hi"]) == .working)
        #expect(status(["hook_event_name": "PreToolUse", "tool_name": "Bash"]) == .working)
        #expect(status(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"]) == .waiting)
        #expect(status(["hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode"]) == .waiting)
        #expect(status(["hook_event_name": "PostToolUse", "tool_name": "Bash"]) == .working)
        #expect(status(["hook_event_name": "PermissionRequest", "tool_name": "Bash"]) == .waiting)
        #expect(status(["hook_event_name": "Notification", "notification_type": "permission_prompt"]) == .waiting)
        #expect(status(["hook_event_name": "Notification", "notification_type": "idle_prompt"]) == nil)
        #expect(status(["hook_event_name": "Stop"]) == .done)
        #expect(status(["hook_event_name": "StopFailure", "error": "rate_limit"]) == .error)
        #expect(status(["hook_event_name": "SessionStart", "source": "startup"]) == .idle)
        #expect(status(["hook_event_name": "ClaudeExited", "exit_code": 0]) == .idle)
        #expect(status(["hook_event_name": "ClaudeExited", "exit_code": 1]) == .error)
        #expect(status(["hook_event_name": "SubagentStop"]) == nil)
        #expect(TerminalSessionStatus.fromHookPayload(Data("not json".utf8)) == nil)
    }

    @Test func hookStatusWinsAndStaysUntilTheNextEvent() {
        var tracker = TerminalStatusTracker()
        let start = Date()
        tracker.update(.init(hook: (.working, start), lastOutput: start, now: start))
        #expect(tracker.status == .working)
        let stop = start.addingTimeInterval(10)
        tracker.update(.init(hook: (.done, stop), lastOutput: stop, now: stop))
        #expect(tracker.status == .done)
        // Silence and typing do not end "done".
        let later = stop.addingTimeInterval(60)
        tracker.update(.init(hook: (.done, stop), lastOutput: stop, lastInput: later, now: later))
        #expect(tracker.status == .done)
    }

    @Test func anInterruptedTurnFallsBackToIdle() {
        var tracker = TerminalStatusTracker()
        let start = Date()
        tracker.update(.init(hook: (.working, start), lastOutput: start, now: start))
        let spinning = start.addingTimeInterval(30)
        tracker.update(.init(hook: (.working, start), lastOutput: spinning, now: spinning.addingTimeInterval(1)))
        #expect(tracker.status == .working)
        tracker.update(.init(hook: (.working, start), lastOutput: spinning, now: spinning.addingTimeInterval(5)))
        #expect(tracker.status == .idle)
    }

    @Test func answeringAPromptResumesWorkingOnlyWhenOutputKeepsComing() {
        var tracker = TerminalStatusTracker()
        let asked = Date()
        tracker.update(.init(hook: (.waiting, asked), lastOutput: asked, now: asked))
        // Arrow keys in a question: the echo comes back at once, still waiting.
        let typed = asked.addingTimeInterval(5)
        tracker.update(.init(hook: (.waiting, asked), lastOutput: typed.addingTimeInterval(0.05), lastInput: typed, now: typed.addingTimeInterval(1)))
        #expect(tracker.status == .waiting)
        // Approved: Claude's spinner keeps printing.
        let running = typed.addingTimeInterval(2)
        tracker.update(.init(hook: (.waiting, asked), lastOutput: running, lastInput: typed, now: running))
        #expect(tracker.status == .working)
    }

    @Test func withoutHooksActivityAndBellDecide() {
        var tracker = TerminalStatusTracker()
        let start = Date()
        tracker.update(.init(lastOutput: start, now: start))
        #expect(tracker.status == .working)
        tracker.update(.init(lastOutput: start, now: start.addingTimeInterval(3)))
        #expect(tracker.status == .done)
        tracker.update(.init(lastOutput: start, bell: true, now: start.addingTimeInterval(4)))
        #expect(tracker.status == .waiting)
    }

    @Test func resetForgetsTheHookHistory() {
        var tracker = TerminalStatusTracker()
        let start = Date()
        tracker.update(.init(hook: (.error, start), now: start))
        tracker.reset()
        #expect(tracker.status == .idle)
    }
}
