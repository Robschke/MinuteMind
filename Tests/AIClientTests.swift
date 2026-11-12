// Purpose: Tests for the AI plumbing without calling Claude: JSON extraction from CLI replies and
//          the takeover of summary prompts and the Claude model from the old AI profiles file.
// Dependencies: Sources/App/Services/ClaudeCodeService.swift (jsonObject),
//               Sources/App/Store/SummaryPromptStore.swift

import Foundation
import Testing
@testable import MinuteMindApp

struct AIClientTests {
    @Test func extractsJSONFromFencedReply() {
        let reply = "Here you go:\n```json\n{\"todos\": [{\"title\": \"Send slides\"}]}\n```"
        #expect(ClaudeCodeService.jsonObject(in: reply) == "{\"todos\": [{\"title\": \"Send slides\"}]}")
    }

    @Test func plainJSONIsUnchanged() {
        #expect(ClaudeCodeService.jsonObject(in: " {\"a\": 1} ") == "{\"a\": 1}")
    }

    @Test func textWithoutJSONIsReturnedTrimmed() {
        #expect(ClaudeCodeService.jsonObject(in: "  no json  ") == "no json")
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func seedsTheDefaultPromptWithoutOldProfiles() throws {
        let store = SummaryPromptStore(baseDirectory: try makeDirectory())
        let prompts = store.load()
        #expect(prompts.count == 1)
        #expect(prompts.first?.title == SystemPrompt.defaultPrompt().title)
        #expect(store.legacyClaudeModel() == nil)
    }

    @Test func takesOverTheActiveProfilesPromptsAndModel() throws {
        let dir = try makeDirectory()
        let json = #"""
        {"profiles":[
          {"id":"7C7EB925-F097-43AE-80D7-905762DDCC18","name":"Old","provider":"openAI","apiKey":"sk-x","baseURL":"","model":"gpt-4o","azureDeployment":"","azureAPIVersion":"","isActive":false,"isModelDownloaded":false,
           "prompts":[{"id":"1C7EB925-F097-43AE-80D7-905762DDCC18","title":"Other","content":"x","isEnabled":true,"isSelected":true}]},
          {"id":"8C7EB925-F097-43AE-80D7-905762DDCC18","name":"Claude","provider":"claudeCode","apiKey":"","baseURL":"","model":"opus","azureDeployment":"","azureAPIVersion":"","isActive":true,"isModelDownloaded":false,
           "prompts":[{"id":"2C7EB925-F097-43AE-80D7-905762DDCC18","title":"Mine","content":"Write short minutes.","isEnabled":true,"isSelected":true}]}
        ]}
        """#
        try Data(json.utf8).write(to: dir.appendingPathComponent("openai-profiles.json"))

        let store = SummaryPromptStore(baseDirectory: dir)
        #expect(store.load().map(\.title) == ["Mine"])
        #expect(store.legacyClaudeModel() == "opus")

        // Saved once, read back from its own file afterwards.
        try store.save([SystemPrompt(title: "Edited", content: "y", isSelected: true)])
        #expect(SummaryPromptStore(baseDirectory: dir).load().map(\.title) == ["Edited"])
    }
}
