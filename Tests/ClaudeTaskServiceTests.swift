// Purpose: Tests for ClaudeTaskService prompt assembly and chat links (no Claude call is made).
// Dependencies: Sources/App/Services/ClaudeTaskService.swift

import Foundation
import Testing
@testable import MinuteMindApp

struct ClaudeTaskServiceTests {
    @Test func basePromptAloneWhenNoInstructions() {
        #expect(ClaudeTaskService.systemPrompt(userInstructions: "  \n") == ClaudeTaskService.basePrompt)
    }

    @Test func instructionsAreAppended() {
        let prompt = ClaudeTaskService.systemPrompt(userInstructions: "Sign emails with Robin.")
        #expect(prompt.hasPrefix(ClaudeTaskService.basePrompt))
        #expect(prompt.hasSuffix("Sign emails with Robin."))
    }

    @Test func basePromptForbidsChatBehaviour() {
        #expect(ClaudeTaskService.basePrompt.contains("not a conversation"))
        #expect(ClaudeTaskService.basePrompt.contains("never ask questions"))
    }

    @Test func chatLinkOpensClaudeAppWithText() throws {
        let url = try #require(ClaudeTaskService.chatURL(for: "Write a mail & thanks", claudeAppInstalled: true))
        #expect(url.scheme == "claude")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "q" }?.value == "Write a mail & thanks")
        #expect(url.path == "/new")
    }

    @Test func chatLinkFallsBackToWeb() throws {
        let url = try #require(ClaudeTaskService.chatURL(for: "Hi", claudeAppInstalled: false))
        #expect(url.absoluteString.hasPrefix("https://claude.ai/new?q="))
    }
}
