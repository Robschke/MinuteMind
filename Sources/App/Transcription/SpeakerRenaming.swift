// Purpose: Rewrites speaker labels in a rendered transcript when the user puts a name to a voice.
//          Only the speaker position of each "[MM:SS] Speaker: text" line is touched — timestamps
//          and the spoken text are never modified.
// Dependencies: none (pure string processing, unit-tested in isolation).
// Used by: Sources/App/ViewModels/AppViewModel.swift (renameSpeakers),
//          Sources/App/Views/SpeakerNamingSheet.swift (indirectly),
//          Sources/App/Views/TranscriptDetailView.swift, Sources/App/Components/SessionActions.swift
//          (isGenerated, for the "unnamed" count).
// Notes: Renaming is driven by an explicit label→name map rather than search-and-replace, so a
//        speaker name appearing inside the spoken text can never be rewritten by accident. Because
//        the transcript keeps the label in a fixed position, renaming stays reversible: re-applying
//        a map that points back to the original labels restores them.

import Foundation

enum SpeakerRenaming {

    /// Replaces the speaker label of each transcript line according to `nameByLabel`.
    /// Lines whose label has no entry — and lines without a speaker prefix — are left as-is.
    /// - Returns: the rewritten transcript and the number of lines changed.
    static func apply(_ nameByLabel: [String: String], to transcript: String) -> (
        text: String, changedLines: Int
    ) {
        let usable = nameByLabel.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty, !transcript.isEmpty else { return (transcript, 0) }

        var changed = 0
        let lines = transcript.components(separatedBy: "\n").map { line -> String in
            guard let parsed = parse(line) else { return line }
            guard let newName = usable[parsed.speaker], newName != parsed.speaker else { return line }
            changed += 1
            return "\(parsed.timestampPrefix)\(newName)\(parsed.suffix)"
        }

        return (lines.joined(separator: "\n"), changed)
    }

    /// Every distinct speaker label present in a rendered transcript, in order of first appearance.
    static func labels(in transcript: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in transcript.components(separatedBy: "\n") {
            guard let parsed = parse(line), seen.insert(parsed.speaker).inserted else { continue }
            result.append(parsed.speaker)
        }
        return result
    }

    /// True for labels the transcriber generated ("Speaker 2", "Other") rather than a real name:
    /// the speakers still worth naming.
    static func isGenerated(_ label: String) -> Bool {
        label.hasPrefix("Speaker ") || label == "Other"
    }

    // MARK: - Line parsing

    private struct ParsedLine {
        /// Everything up to and including "] ".
        let timestampPrefix: String
        let speaker: String
        /// Everything from the ":" onwards, including any language flag before it.
        let suffix: String
    }

    /// Splits "[00:05] Speaker 1 (🇩🇪): text" into prefix "[00:05] ", speaker "Speaker 1"
    /// and suffix " (🇩🇪): text". Returns nil for lines that are not transcript lines.
    private static func parse(_ line: String) -> ParsedLine? {
        guard line.hasPrefix("["), let bracketEnd = line.firstIndex(of: "]") else { return nil }

        let afterBracket = line.index(after: bracketEnd)
        guard afterBracket < line.endIndex, line[afterBracket] == " " else { return nil }

        let speakerStart = line.index(after: afterBracket)
        guard speakerStart < line.endIndex,
            let colon = line[speakerStart...].firstIndex(of: ":")
        else { return nil }

        // An optional " (flag)" sits between the speaker name and the colon.
        var speakerEnd = colon
        let segment = line[speakerStart..<colon]
        if let flagStart = segment.range(of: " (", options: .backwards)?.lowerBound {
            speakerEnd = flagStart
        }

        let speaker = String(line[speakerStart..<speakerEnd])
        guard !speaker.isEmpty else { return nil }

        return ParsedLine(
            timestampPrefix: String(line[...afterBracket]),
            speaker: speaker,
            suffix: String(line[speakerEnd...]))
    }
}
