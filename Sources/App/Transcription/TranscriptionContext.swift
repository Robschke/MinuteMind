// Purpose: Assembles biasing context (proper nouns, meeting metadata) for a transcription so
//          engines recognize participant names, the meeting title, and project-specific jargon
//          instead of guessing. Improves accuracy on exactly the words that matter for minutes.
// Dependencies: none (pure value type built from plain session/project data — testable in isolation).
// Used by: Sources/App/ViewModels/AppViewModel.swift (transcribe*/enqueue paths),
//          Sources/App/Transcription/TranscriptionService.swift (contextualStrings).
// Notes: `terms` feed SFSpeechRecognizer.contextualStrings (phrase list) and the fuzzy
//        ProperNounCorrection. Attendee entries that look like emails are turned into names.

import Foundation

struct TranscriptionContext: Sendable {
    /// Proper nouns / phrases for SFSpeechRecognizer.contextualStrings.
    let terms: [String]

    var isEmpty: Bool { terms.isEmpty }

    static let empty = TranscriptionContext(terms: [])

    static func build(
        meetingTitle: String?,
        calendarEventTitle: String?,
        attendees: [String]?,
        projectName: String?,
        extraTerms: [String] = []
    ) -> TranscriptionContext {
        let names = (attendees ?? [])
            .map(displayName(from:))
            .filter { !$0.isEmpty }

        let titles = [meetingTitle, calendarEventTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != "untitled" && $0.lowercased() != "new recording" }

        // Unique, order-preserving term list for contextualStrings.
        var seen = Set<String>()
        var terms: [String] = []
        for term in names + titles + (projectName.map { [$0] } ?? []) + extraTerms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            terms.append(trimmed)
        }

        return TranscriptionContext(terms: terms)
    }

    /// Turns an attendee entry into a human name. Emails like "jane.doe@acme.co" become "Jane Doe";
    /// entries that already look like names are passed through trimmed.
    private static func displayName(from attendee: String) -> String {
        let trimmed = attendee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else { return trimmed }
        let local = String(trimmed.prefix { $0 != "@" })
        let words = local
            .components(separatedBy: CharacterSet(charactersIn: "._-+"))
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.joined(separator: " ")
    }
}
