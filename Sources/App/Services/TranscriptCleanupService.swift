// Purpose: Polishes a finished transcript with Claude: punctuation, capitalization, filler-word
//          removal and obvious recognition slips, without changing what was said.
// Dependencies: Sources/App/Services/ClaudeCodeService.swift (complete).
// Used by: Sources/App/ViewModels/AppViewModel.swift (cleanUpTranscript).
// Notes: An LLM can silently drop or invent lines, so output is verified structurally: the cleaned
//        chunk must keep the same number of lines and the same "[MM:SS] Speaker:" prefixes, or the
//        original chunk is kept unchanged. The caller preserves the raw transcript separately, so a
//        cleanup can always be compared against, or reverted to, the original.
//        Blank lines (one between every turn) never reach the model and are put back afterwards:
//        models return their answer trimmed, so a chunk starting or ending on a blank line always
//        failed the line count and its cleanup was thrown away.
//        Cleanup always runs on Sonnet, whatever model the other jobs use: it is the best balance
//        of speed and accuracy for 120-line chunks.

import Foundation

struct TranscriptCleanupService {

    private static let instructions = """
        You clean up meeting transcripts. Apply ONLY these changes:
        - Fix punctuation, capitalization and obvious speech-recognition errors.
        - Remove filler words (uh, um, äh, ähm) and stuttered repetitions.
        - Keep every line, in the same order.
        - Keep each line's "[MM:SS] Speaker:" prefix EXACTLY as given.
        - Keep the original language. Never translate.
        Never add, remove or reinterpret content. Never summarize. Never add commentary.
        Return only the cleaned transcript.
        """

    /// Cleans `transcript` and returns the polished text. Chunks that Claude altered
    /// structurally are kept in their original form. The meeting `context` (title, attendees,
    /// project terms) helps fix names the recognizer misheard.
    func cleanUp(_ transcript: String, claude: ClaudeCodeService, context: String? = nil) async throws -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcript }
        // Only lines with text go to the model; the blank lines between turns are restored after.
        let cleaned = try await cleanWithClaude(Self.textLines(of: transcript), claude: claude, context: context)
        return Self.restoringBlankLines(of: transcript, in: cleaned)
    }

    private static func systemPrompt(context: String?) -> String {
        guard let context, !context.isEmpty else { return instructions }
        return instructions + "\n\nMeeting context (use it only to spell names and terms correctly):\n\(context)"
    }

    // MARK: - Claude backend

    /// Lines per Claude request and how many requests run at once. Each request is a CLI process,
    /// so chunks are large.
    private let claudeChunkLines = 120
    private let claudeParallelism = 3

    private func cleanWithClaude(_ lines: [String], claude: ClaudeCodeService, context: String?) async throws -> String {
        let chunks = stride(from: 0, to: lines.count, by: claudeChunkLines).map {
            Array(lines[$0..<min($0 + claudeChunkLines, lines.count)])
        }
        let systemPrompt = Self.systemPrompt(context: context)

        var cleaned = [String?](repeating: nil, count: chunks.count)
        var next = 0
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            func enqueue() {
                guard next < chunks.count else { return }
                let index = next, chunk = chunks[index]
                next += 1
                group.addTask {
                    let original = chunk.joined(separator: "\n")
                    guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (index, original) }
                    do {
                        let candidate = try await claude.complete(prompt: original, systemPrompt: systemPrompt, model: "sonnet")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        return (index, Self.preservesStructure(original: chunk, cleaned: candidate) ? candidate : original)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        NSLog("TranscriptCleanupService: Claude chunk failed (%@), keeping original", error.localizedDescription)
                        return (index, original)
                    }
                }
            }
            for _ in 0..<claudeParallelism { enqueue() }
            for try await (index, text) in group {
                cleaned[index] = text
                enqueue()
            }
        }
        return cleaned.map { $0 ?? "" }.joined(separator: "\n")
    }

    // MARK: - Blank lines

    /// The lines that carry text, in order (what the models see).
    static func textLines(of transcript: String) -> [String] {
        transcript.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Puts the cleaned text lines back into `original`'s layout, blank lines included. Returns
    /// `original` unchanged when the line counts do not match.
    static func restoringBlankLines(of original: String, in cleaned: String) -> String {
        var result = original.components(separatedBy: "\n")
        let textIndices = result.indices.filter { !result[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let cleanedLines = cleaned.components(separatedBy: "\n")
        guard cleanedLines.count == textIndices.count else { return original }
        for (position, index) in textIndices.enumerated() { result[index] = cleanedLines[position] }
        return result.joined(separator: "\n")
    }

    // MARK: - Structural verification

    /// True when the cleaned text still has the same line count and identical
    /// "[MM:SS] Speaker:" prefixes — our guard against the model dropping or inventing lines.
    static func preservesStructure(original: [String], cleaned: String) -> Bool {
        let cleanedLines = cleaned.components(separatedBy: "\n")
        guard cleanedLines.count == original.count else { return false }

        for (originalLine, cleanedLine) in zip(original, cleanedLines) {
            let originalPrefix = speakerPrefix(of: originalLine)
            guard originalPrefix == speakerPrefix(of: cleanedLine) else { return false }
        }
        return true
    }

    /// The "[MM:SS] Speaker: " prefix of a rendered transcript line, or nil when it has none.
    private static func speakerPrefix(of line: String) -> String? {
        guard line.hasPrefix("["),
            let bracketEnd = line.firstIndex(of: "]"),
            let colon = line[bracketEnd...].firstIndex(of: ":")
        else { return nil }
        return String(line[...colon])
    }
}
