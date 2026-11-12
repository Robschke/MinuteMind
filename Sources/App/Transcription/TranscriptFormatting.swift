// Purpose: Shared transcript assembly — groups timed words into utterances at pauses, interleaves
//          the microphone and system-audio streams chronologically (marking overlaps), and renders
//          the final "[MM:SS] Speaker: text" transcript.
// Dependencies: none (pure value types, unit-tested in isolation).
// Used by: Sources/App/Transcription/TranscriptionService.swift (Apple/SpeechAnalyzer path),
//          Sources/App/Services/ParakeetTranscriptionService.swift (Parakeet timed path).
// Notes: Extracted so both transcription engines produce byte-identical formatting instead of each
//        carrying its own copy. Speaker labels are plain strings so diarized labels ("Speaker 1")
//        flow through unchanged alongside the fixed "You"/"Other" labels.

import Foundation

/// A single spoken utterance with timing, speaker label and detected language.
struct TranscriptUtterance: Sendable, Equatable {
    var speaker: String
    var text: String
    var start: TimeInterval
    var duration: TimeInterval
    var language: String

    var end: TimeInterval { start + duration }
}

/// A word (or sub-word group) with timing, as produced by a recognition engine.
struct TimedWord: Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

enum TranscriptFormatting {

    /// Label used for the local microphone speaker.
    static let localSpeaker = "You"

    /// Groups words into utterances, starting a new utterance whenever the gap since the previous
    /// word exceeds `pauseThreshold`.
    static func groupIntoUtterances(
        _ words: [TimedWord],
        speaker: String,
        language: String,
        pauseThreshold: TimeInterval = 0.8
    ) -> [TranscriptUtterance] {
        guard !words.isEmpty else { return [] }

        var utterances: [TranscriptUtterance] = []
        var current: [String] = []
        var utteranceStart = words[0].start
        var lastEnd = words[0].end

        func flush() {
            guard !current.isEmpty else { return }
            utterances.append(
                TranscriptUtterance(
                    speaker: speaker,
                    text: current.joined(separator: " "),
                    start: utteranceStart,
                    duration: lastEnd - utteranceStart,
                    language: language))
        }

        for word in words {
            if word.start - lastEnd > pauseThreshold && !current.isEmpty {
                flush()
                current = []
                utteranceStart = word.start
            }
            current.append(word.text)
            lastEnd = word.end
        }
        flush()

        return utterances
    }

    /// Merges both streams into one chronological list, prefixing "[overlapping] " when a different
    /// speaker starts before the previous speaker finished.
    static func interleave(
        mic micUtterances: [TranscriptUtterance],
        system systemUtterances: [TranscriptUtterance]
    ) -> [TranscriptUtterance] {
        var all = micUtterances + systemUtterances
        all.sort { $0.start < $1.start }

        var result: [TranscriptUtterance] = []
        var lastEnd: TimeInterval = 0
        var lastSpeaker = ""

        for (index, utterance) in all.enumerated() {
            var entry = utterance
            if index > 0, entry.start < lastEnd, entry.speaker != lastSpeaker {
                entry.text = "[overlapping] " + entry.text
            }
            result.append(entry)

            if utterance.end > lastEnd {
                lastEnd = utterance.end
                lastSpeaker = utterance.speaker
            }
        }
        return result
    }

    /// Renders utterances as "[MM:SS] Speaker: text" blocks separated by blank lines.
    /// When `showLanguage` is true, a flag for the detected language follows the speaker.
    static func render(_ utterances: [TranscriptUtterance], showLanguage: Bool) -> String {
        utterances.map { utterance -> String in
            let minutes = Int(utterance.start) / 60
            let seconds = Int(utterance.start) % 60
            let suffix = showLanguage ? " (\(languageFlag(for: utterance.language)))" : ""
            return
                "[\(String(format: "%02d:%02d", minutes, seconds))] \(utterance.speaker)\(suffix): \(utterance.text)"
        }
        .joined(separator: "\n\n")
    }

    /// Convenience: interleave (splitting local vs remote by speaker label) and render in one step.
    static func assemble(_ utterances: [TranscriptUtterance], showLanguage: Bool) -> String {
        guard !utterances.isEmpty else { return "" }
        // Anything that isn't the local mic label is a remote/system speaker — this covers the
        // generic "Other" label as well as diarized "Speaker N" labels.
        let interleaved = interleave(
            mic: utterances.filter { $0.speaker == localSpeaker },
            system: utterances.filter { $0.speaker != localSpeaker })
        return render(interleaved, showLanguage: showLanguage)
    }

    static func languageFlag(for locale: String) -> String {
        switch locale {
        case "en-US": return "🇺🇸"
        case "de-DE": return "🇩🇪"
        default: return locale
        }
    }
}
