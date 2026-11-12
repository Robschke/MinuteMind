// Purpose: Tests for the voice assistant's pure parts: reading Claude's marker line, the prompt
//          with selection and app, and the command line (tools, terminal switch, blocked deletes,
//          resume).
// Dependencies: Sources/App/Services/ClaudeAssistantService.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("ClaudeAssistantService Tests")
struct ClaudeAssistantServiceTests {
    @Test("Marker lines decide: PASTE text, DONE summary with details, ASK question")
    func parsing() {
        #expect(ClaudeAssistantOutcome.parse("Sure.\nPASTE: Hallo Anna,\nbis morgen!") == .paste("Hallo Anna,\nbis morgen!"))
        #expect(ClaudeAssistantOutcome.parse("DONE: Added todo \"Call Bob\"\nProject: Acme, due Friday")
            == .done(summary: "Added todo \"Call Bob\"", details: "Project: Acme, due Friday"))
        #expect(ClaudeAssistantOutcome.parse("ASK: Which project should it go to?") == .ask("Which project should it go to?"))
        #expect(ClaudeAssistantOutcome.parse("  done: archived  ") == .done(summary: "archived", details: ""))
    }

    @Test("Without a marker the whole text comes back; the last marker wins")
    func parsingFallbacks() {
        #expect(ClaudeAssistantOutcome.parse("  Just some text  ") == .paste("Just some text"))
        #expect(ClaudeAssistantOutcome.parse("PASTE: draft\nDONE: saved it") == .done(summary: "saved it", details: ""))
    }

    @Test("The prompt carries the app, the window and the selection, clearly delimited")
    func prompt() {
        let context = ClaudeAssistantContext(selection: "Lorem ipsum", appName: "Mail", windowTitle: "Re: Offer")
        let prompt = ClaudeAssistantService.prompt(request: "translate this", context: context)
        #expect(prompt.contains("Mail (window \"Re: Offer\")"))
        #expect(prompt.contains("<selection>\nLorem ipsum\n</selection>"))
        #expect(prompt.hasSuffix("Their request:\ntranslate this"))
        let bare = ClaudeAssistantService.prompt(request: "hi", context: ClaudeAssistantContext())
        #expect(bare == "Their request:\nhi")
    }

    @Test("Command line: MinuteMind and web always, terminal only when allowed, deletes blocked")
    func arguments() {
        let config = URL(fileURLWithPath: "/tmp/claude-mcp.json")
        let full = ClaudeAssistantService.arguments(
            model: "sonnet", systemPrompt: "rules", mcpConfig: config, allowsTerminal: true, resume: nil)
        func value(after flag: String, in arguments: [String]) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        #expect(value(after: "--tools", in: full) == "WebSearch,WebFetch,Bash,Read")
        #expect(value(after: "--allowedTools", in: full)?.contains("mcp__minutemind") == true)
        #expect(value(after: "--disallowedTools", in: full)?.contains("mcp__minutemind__delete_project_task") == true)
        #expect(value(after: "--mcp-config", in: full) == "/tmp/claude-mcp.json")
        #expect(!full.contains("--resume"))

        let restricted = ClaudeAssistantService.arguments(
            model: "haiku", systemPrompt: "rules", mcpConfig: nil, allowsTerminal: false, resume: "abc")
        #expect(value(after: "--tools", in: restricted) == "WebSearch,WebFetch")
        #expect(value(after: "--allowedTools", in: restricted) == "WebSearch,WebFetch")
        #expect(!restricted.contains("--mcp-config"))
        #expect(value(after: "--resume", in: restricted) == "abc")
    }

    @Test("Without the terminal the rules say so")
    func terminalRules() {
        let off = ClaudeAssistantService.systemPrompt(userInstructions: "", allowsTerminal: false)
        #expect(off.contains("cannot run terminal commands"))
        #expect(!off.contains("run something in the terminal"))
        let on = ClaudeAssistantService.systemPrompt(userInstructions: "Sign as Robin", allowsTerminal: true)
        #expect(on.contains("run something in the terminal"))
        #expect(on.hasSuffix("Sign as Robin"))
    }
}
