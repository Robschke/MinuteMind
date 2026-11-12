// Purpose: Tests for reading what a Claude session asks from its hook payloads, and the keys
//          that answer it.
// Dependencies: Sources/App/Supporting/ClaudeSessionRequest.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("ClaudeSessionRequest Tests")
struct ClaudeSessionRequestTests {
    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("A permission request names the tool and what it would do")
    func permission() {
        let request = json(["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                            "tool_input": ["command": "git push", "description": "Push"]])
        let notification = json(["hook_event_name": "Notification", "notification_type": "permission_prompt",
                                 "message": "Claude needs your permission to use Bash"])
        #expect(ClaudeSessionRequest.from(request: request, latest: notification, status: .waiting)
            == .permission(tool: "Bash", detail: "git push"))
        #expect(ClaudeSessionRequest.isRequestPayload(request))
        #expect(!ClaudeSessionRequest.isRequestPayload(notification))
    }

    @Test("One single-choice question offers its options; others only show")
    func questions() {
        let single = json(["hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "tool_input": [
            "questions": [["question": "Which colour?", "multiSelect": false,
                           "options": [["label": "Red"], ["label": "Green"]]]]]])
        #expect(ClaudeSessionRequest.from(request: single, latest: single, status: .waiting)
            == .question(text: "Which colour?", options: ["Red", "Green"]))
        let multi = json(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": [
            "questions": [["question": "A?", "options": [["label": "x"]]], ["question": "B?", "options": [["label": "y"]]]]]])
        #expect(ClaudeSessionRequest.from(request: multi, latest: multi, status: .waiting)
            == .question(text: "A? (+1 more)", options: []))
        #expect(ClaudeSessionRequest.isRequestPayload(multi))
    }

    @Test("Done shows Claude's last message; idle and working ask nothing")
    func finished() {
        let stop = json(["hook_event_name": "Stop", "last_assistant_message": " All set. \n"])
        #expect(ClaudeSessionRequest.from(request: nil, latest: stop, status: .done) == .finished("All set."))
        #expect(ClaudeSessionRequest.from(request: nil, latest: stop, status: .working) == nil)
        #expect(ClaudeSessionRequest.endsRequest(stop))
    }

    @Test("Waiting without a known request falls back to the notification's message")
    func unknownWaiting() {
        let note = json(["hook_event_name": "Notification", "message": "Claude is waiting"])
        #expect(ClaudeSessionRequest.from(request: nil, latest: note, status: .waiting) == .waiting("Claude is waiting"))
    }

    @Test("Answers become Claude Code's keys")
    func keys() {
        #expect(ClaudeSessionRequest.keys(for: .allow) == ["\r"])
        #expect(ClaudeSessionRequest.keys(for: .deny) == ["\u{1b}"])
        #expect(ClaudeSessionRequest.keys(for: .option(1)) == ["2"])
        #expect(ClaudeSessionRequest.keys(for: .option(9)) == [])
        #expect(ClaudeSessionRequest.keys(for: .reply("  hi\nthere ")) == ["\u{1b}[200~hi\nthere\u{1b}[201~", "\r"])
        #expect(ClaudeSessionRequest.keys(for: .denyWith("no")) == ["\u{1b}", "\u{1b}[200~no\u{1b}[201~", "\r"])
        #expect(ClaudeSessionRequest.keys(for: .reply("   ")) == [])
    }
}
