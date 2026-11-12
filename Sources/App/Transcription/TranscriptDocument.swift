// Purpose: Parses a rendered transcript ("[MM:SS] Speaker: text") back into structured lines, so the
//          reader can lay out timestamps, speaker names and text as separate elements instead of
//          showing one wall of pre-formatted text.
// Dependencies: none (pure string processing, unit-tested in isolation).
// Used by: Sources/App/Views/TranscriptDetailView.swift
// Notes: The transcript file stays the source of truth — this is a view over it, not a second
//        representation. Anything that does not parse (blank lines, notes a user typed by hand) is
//        preserved as a `plain` line rather than dropped, so reading a transcript can never hide
//        content that editing would still show.

import Foundation

/// One line of a rendered transcript.
struct TranscriptLine: Identifiable, Equatable {
    let id: Int
    /// "[01:04]" without brackets, e.g. "01:04". Nil for lines that carry no timestamp.
    let timestamp: String?
    /// Seconds derived from `timestamp`, for seeking audio.
    let startSeconds: TimeInterval?
    /// Speaker as shown, e.g. "Anna" or "Speaker 2". Nil for unparsed lines.
    let speaker: String?
    /// Optional language flag that sits between speaker and colon, e.g. "🇩🇪".
    let languageFlag: String?
    let text: String

    var isSpoken: Bool { speaker != nil }
}

enum TranscriptDocument {

    /// Splits a rendered transcript into lines. Empty lines are dropped; unparseable ones are kept
    /// as plain text.
    static func parse(_ transcript: String) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        for raw in transcript.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let parsed = parseSpokenLine(line, id: result.count) {
                result.append(parsed)
            } else {
                result.append(
                    TranscriptLine(
                        id: result.count, timestamp: nil, startSeconds: nil, speaker: nil,
                        languageFlag: nil, text: line))
            }
        }
        return result
    }

    /// Distinct speakers in order of first appearance — drives the colour assignment and the
    /// participant summary in the reader's header.
    static func speakers(in lines: [TranscriptLine]) -> [String] {
        var seen = Set<String>()
        return lines.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }

    /// Rough word count, for the reader's header.
    static func wordCount(_ lines: [TranscriptLine]) -> Int {
        lines.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    // MARK: - Line parsing

    /// Splits "[00:05] Speaker 1 (🇩🇪): text" into its parts. Returns nil when the line has no
    /// "[timestamp] speaker:" prefix.
    private static func parseSpokenLine(_ line: String, id: Int) -> TranscriptLine? {
        guard line.hasPrefix("["), let bracketEnd = line.firstIndex(of: "]") else { return nil }

        let timestamp = String(line[line.index(after: line.startIndex)..<bracketEnd])

        let afterBracket = line.index(after: bracketEnd)
        guard afterBracket < line.endIndex else { return nil }

        let speakerStart =
            line[afterBracket] == " " ? line.index(after: afterBracket) : afterBracket
        guard speakerStart < line.endIndex,
            let colon = line[speakerStart...].firstIndex(of: ":")
        else { return nil }

        // An optional " (flag)" sits between the speaker name and the colon.
        var speakerEnd = colon
        var flag: String?
        let segment = line[speakerStart..<colon]
        if let flagStart = segment.range(of: " (", options: .backwards)?.lowerBound {
            speakerEnd = flagStart
            flag = String(segment[flagStart...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        }

        let speaker = String(line[speakerStart..<speakerEnd]).trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty else { return nil }

        let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

        return TranscriptLine(
            id: id,
            timestamp: timestamp,
            startSeconds: seconds(from: timestamp),
            speaker: speaker,
            languageFlag: flag,
            text: text)
    }

    /// "01:04" or "1:02:03" → seconds. Nil when the timestamp is not numeric.
    static func seconds(from timestamp: String) -> TimeInterval? {
        let parts = timestamp.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }

        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
