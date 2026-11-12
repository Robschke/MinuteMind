// Purpose: TranscriptSpeakerSummary, what a recording card shows about a transcript's speakers:
//          the first few turns for the preview and each speaker's approximate talk time.
// Dependencies: Sources/App/Transcription/TranscriptDocument.swift (parse)
// Used by: Sources/App/Components/RecordingCardParts.swift (RecordingCardSummary)
// Notes: Pure and unit-tested. The preview parses only the first lines of the transcript, never a
//        whole hour-long meeting per render. Talk time is derived from the line timestamps (a
//        line lasts until the next one starts, capped at two minutes; the last line counts about
//        0.4 s per word) instead of the diarizer's numbers, because the user's own microphone is
//        not diarized and would otherwise be missing from the bar.

import Foundation

enum TranscriptSpeakerSummary {

    /// Consecutive lines of one speaker, shown as one entry in the preview.
    struct Turn: Equatable {
        let speaker: String
        /// "00:11" as written in the transcript.
        let timestamp: String?
        let startSeconds: TimeInterval?
        let text: String
    }

    struct TalkTime: Equatable {
        let speaker: String
        let seconds: TimeInterval
    }

    /// The first `maxTurns` turns, merging consecutive lines of the same speaker and keeping the
    /// first timestamp. Only the first `scanLines` lines are parsed.
    static func previewTurns(_ transcript: String, maxTurns: Int = 3, scanLines: Int = 25) -> [Turn] {
        let head = transcript.split(separator: "\n", maxSplits: scanLines, omittingEmptySubsequences: true)
            .prefix(scanLines)
            .joined(separator: "\n")
        var turns: [Turn] = []
        for line in TranscriptDocument.parse(head) where line.isSpoken {
            guard let speaker = line.speaker, !line.text.isEmpty else { continue }
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1] = Turn(
                    speaker: speaker, timestamp: last.timestamp, startSeconds: last.startSeconds,
                    text: last.text + " " + line.text)
            } else {
                if turns.count == maxTurns { break }
                turns.append(Turn(
                    speaker: speaker, timestamp: line.timestamp, startSeconds: line.startSeconds,
                    text: line.text))
            }
        }
        return turns
    }

    /// Talk time per speaker, in order of first appearance.
    static func talkTimes(_ transcript: String) -> [TalkTime] {
        let lines = TranscriptDocument.parse(transcript).filter { $0.isSpoken && $0.speaker != nil }
        var order: [String] = []
        var seconds: [String: TimeInterval] = [:]
        for (index, line) in lines.enumerated() {
            guard let speaker = line.speaker else { continue }
            if seconds[speaker] == nil { order.append(speaker) }
            let words = Double(line.text.split(whereSeparator: \.isWhitespace).count)
            var duration = words * 0.4
            if let start = line.startSeconds,
               let next = lines[(index + 1)...].first(where: { $0.startSeconds != nil })?.startSeconds,
               next > start {
                duration = min(next - start, 120)
            }
            seconds[speaker, default: 0] += duration
        }
        return order.map { TalkTime(speaker: $0, seconds: seconds[$0] ?? 0) }
    }
}
