// Purpose: The meeting summary prompts (SystemPrompt) and their store, summary-prompts.json: the
//          user's own instructions for the summary, one of them selected.
// Dependencies: Foundation. Reads the old openai-profiles.json once, to carry its prompts and its
//               Claude Code model over.
// Used by: Sources/App/ViewModels/AppViewModel.swift (summaryPrompts, prompt CRUD, generateMeetingMinutes),
//          Sources/App/Views/AISettingsView.swift (prompt list)
// Notes: Prompts used to live inside each AI profile. When summary-prompts.json does not exist yet,
//        the prompts of the active profile (or the first profile that has any) are taken over; the
//        old file is left on disk untouched. Without any, the default prompt is seeded.

import Foundation

struct SystemPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var isEnabled: Bool
    var isSelected: Bool

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        isEnabled: Bool = true,
        isSelected: Bool = false
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.isEnabled = isEnabled
        self.isSelected = isSelected
    }

    static func defaultPrompt() -> SystemPrompt {
        SystemPrompt(
            title: "Structured meeting minutes",
            content: """
You are an AI assistant that produces clear, concise, and structured meeting minutes from imperfect meeting transcripts.

GENERAL INSTRUCTIONS
- Transcripts may contain errors, omissions, or unclear wording. Infer the intended meaning where reasonable, but do not invent facts.
- Use only information that can be reasonably derived from the transcript.
- If a section has no relevant information, explicitly state: “No information available.”
- Be neutral, factual, and concise.
- Do not add commentary or assumptions beyond the transcript.
- Respond strictly in Markdown.

OUTPUT STRUCTURE  
Always return the following sections in this exact order and format:

## Summary
A brief, high-level overview of the main topics discussed in the meeting.

## Decisions Made
List explicit decisions that were agreed upon during the meeting.
- Only include finalized decisions, not proposals or ideas still under discussion.
- Phrase decisions clearly and unambiguously.
- If no decisions were made, state: “No decisions were made.”

## Action Items
List concrete follow-up tasks resulting from the meeting.
- Include the task, owner (if mentioned), and deadline (if mentioned).
- If ownership or deadlines are unclear, state this explicitly.
- Do not restate decisions unless they require follow-up action.

## Open Questions
List unresolved questions, pending decisions, or topics requiring follow-up.

## Detailed Summary
A comprehensive bullet-point summary of all relevant discussion points, organized logically.

## Project Knowledge
Capture durable, project-relevant information suitable for inclusion in a knowledge base.
- Only include information that is broadly reusable beyond this meeting.
- Organize content into clearly labeled subsections using Markdown headers  
  (e.g. `## Architecture`, `## Staffing`, `## Technical Implementation`, `## Dependencies`, `## Risks`, etc.).
- Create subsections only if relevant information exists.

CONTENT RULES
- Do not duplicate content unnecessarily across sections.
- Prefer clarity over verbatim transcription.
- Preserve important terminology, decisions, and relationships accurately.
""",
            isEnabled: true,
            isSelected: true
        )
    }
}

final class SummaryPromptStore {
    private let baseDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    private var fileURL: URL { baseDirectory.appendingPathComponent("summary-prompts.json") }
    private var legacyProfilesURL: URL { baseDirectory.appendingPathComponent("openai-profiles.json") }

    /// The stored prompts; on first use the old profiles' prompts, else the default prompt.
    func load() -> [SystemPrompt] {
        if let data = try? Data(contentsOf: fileURL),
           let prompts = try? JSONDecoder().decode([SystemPrompt].self, from: data) {
            return prompts
        }
        let profiles = legacyProfiles()
        let source = profiles.first { $0.isActive == true && !($0.prompts ?? []).isEmpty }
            ?? profiles.first { !($0.prompts ?? []).isEmpty }
        let prompts = source?.prompts ?? [SystemPrompt.defaultPrompt()]
        try? save(prompts)
        return prompts
    }

    func save(_ prompts: [SystemPrompt]) throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prompts).write(to: fileURL, options: .atomic)
    }

    /// The model of the old active Claude Code profile, if there was one.
    func legacyClaudeModel() -> String? {
        guard let active = legacyProfiles().first(where: { $0.isActive == true }),
              active.provider == "claudeCode", let model = active.model,
              AIClient.models.contains(model) else { return nil }
        return model
    }

    /// Only the fields the takeover needs; everything else in the old file is ignored.
    private struct LegacyProfile: Decodable {
        let provider: String?
        let model: String?
        let isActive: Bool?
        let prompts: [SystemPrompt]?
    }

    private struct LegacyFile: Decodable {
        let profiles: [LegacyProfile]
    }

    private func legacyProfiles() -> [LegacyProfile] {
        guard let data = try? Data(contentsOf: legacyProfilesURL),
              let file = try? JSONDecoder().decode(LegacyFile.self, from: data) else { return [] }
        return file.profiles
    }
}
