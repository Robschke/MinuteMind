// Purpose: Puts the microphone and the system-audio channel of one recording on a common timeline:
//          how much later the system file starts than the microphone file, and which microphone
//          passages are only the loudspeaker playing the system channel back (echo).
// Dependencies: Sources/App/Transcription/TranscriptFormatting.swift (TimedWord).
// Used by: Sources/App/ViewModels/AppViewModel.swift (offset stored at stop, passed to the engines),
//          Sources/App/Services/ParakeetTranscriptionService.swift (echo removal before labelling).
// Notes: Pure value logic, unit-tested in isolation.
//        The system file starts later than the microphone file because ScreenCaptureKit needs
//        0.2 to 2 s to deliver its first buffer; unaligned, turns interleave in the wrong order.
//        Echo is judged on the recognized words, not on the audio: a loudspeaker copy reaches the
//        microphone reverberant and is recognized with different errors, but mostly the same words
//        at the same time. Fewer than three matching words in a row are never dropped: "Ja, genau"
//        said by both sides at once is ordinary agreement, not echo.

import Foundation

enum ChannelAlignment {

    /// Offsets beyond this are treated as a measuring error and ignored.
    static let maximumOffset: TimeInterval = 10

    /// Seconds the system channel starts after the microphone channel, from the moments their
    /// first samples were captured (same clock). Nil when either is unknown or the value is
    /// implausible.
    static func offset(microphoneStart: TimeInterval?, systemStart: TimeInterval?) -> TimeInterval? {
        guard let microphoneStart, let systemStart else { return nil }
        let offset = systemStart - microphoneStart
        guard abs(offset) <= maximumOffset else { return nil }
        return offset
    }

    /// Estimate for recordings without a measured offset: both channels stop together, so a
    /// shorter system file started that much later. Zero when the lengths give no sane answer.
    static func estimatedOffset(microphoneDuration: TimeInterval?, systemDuration: TimeInterval?)
        -> TimeInterval
    {
        guard let microphoneDuration, let systemDuration, microphoneDuration > 0, systemDuration > 0
        else { return 0 }
        let difference = microphoneDuration - systemDuration
        return (0...maximumOffset).contains(difference) ? difference : 0
    }
}

enum EchoSuppression {

    /// How far apart in time the same words may sit on both channels and still count as echo.
    static let window: TimeInterval = 2.0
    /// Share of a microphone run's words that must reappear, in order, on the system channel.
    static let matchThreshold = 0.7
    /// Runs of this many words or more are judged by `matchThreshold`.
    static let minimumWords = 4

    /// Unmatched words tolerated inside an echoed stretch (misheard words of the copy).
    static let maximumGap = 2
    /// Longer runs are judged in pieces of this many words, to bound the comparison's cost.
    private static let maximumRunWords = 300

    /// Removes microphone speech that repeats what the system channel says at the same time.
    /// A run between pauses that is mostly a copy goes as a whole (its misheard words too);
    /// otherwise only its copied stretches go, so a remark made right after the echo stays.
    /// - Parameters:
    ///   - microphone: microphone words in order.
    ///   - system: system words in order, already on the microphone's timeline.
    ///   - pauseThreshold: gap that ends a run (the same value utterance grouping uses).
    /// - Returns: the remaining microphone words and how many were removed.
    static func removingEcho(
        microphone: [TimedWord],
        system: [TimedWord],
        pauseThreshold: TimeInterval = 0.8
    ) -> (words: [TimedWord], removed: Int) {
        guard !microphone.isEmpty, !system.isEmpty else { return (microphone, 0) }
        let systemKeys = system.map { normalized($0.text) }

        var kept: [TimedWord] = []
        var lowerBound = 0  // first system word that can still fall into a run's window

        for run in runs(of: microphone, pauseThreshold: pauseThreshold) {
            let words = Array(microphone[run])
            let from = words[0].start - window
            let to = words[words.count - 1].end + window
            while lowerBound < system.count, system[lowerBound].end < from { lowerBound += 1 }
            var upperBound = lowerBound
            while upperBound < system.count, system[upperBound].start <= to { upperBound += 1 }

            let matched = matches(
                run: words, system: Array(system[lowerBound..<upperBound]),
                systemKeys: Array(systemKeys[lowerBound..<upperBound]))
            let matchCount = matched.filter { $0 }.count

            if words.count >= 3, candidatesSuffice(matchCount, of: words.count) {
                continue  // the whole run is a copy
            }
            let echoed = echoedStretches(in: matched)
            for (index, word) in words.enumerated() where !echoed.contains(where: { $0.contains(index) }) {
                kept.append(word)
            }
        }
        return (kept, microphone.count - kept.count)
    }

    /// True when `matches` of `count` words make a run a copy: all of a three-word run, else
    /// `matchThreshold`.
    private static func candidatesSuffice(_ matches: Int, of count: Int) -> Bool {
        count < minimumWords ? matches == count : Double(matches) / Double(count) >= matchThreshold
    }

    /// True when `run` is, word for word, mostly contained in `candidates` (timing ignored).
    static func isEcho(_ run: [String], of candidates: [String]) -> Bool {
        guard run.count >= 3, candidates.count >= 3 else { return false }
        let words = run.map { TimedWord(text: $0, start: 0, end: 0) }
        let others = candidates.map { TimedWord(text: $0, start: 0, end: 0) }
        let matched = matches(run: words, system: others, systemKeys: candidates.map(normalized))
        return candidatesSuffice(matched.filter { $0 }.count, of: run.count)
    }

    /// For every word of `run`, whether it takes part in the longest in-order sequence of words
    /// that the system channel also has within `window` of the same moment.
    private static func matches(run: [TimedWord], system: [TimedWord], systemKeys: [String]) -> [Bool] {
        let n = run.count, m = system.count
        var matched = [Bool](repeating: false, count: n)
        guard n > 0, m > 0 else { return matched }
        let runKeys = run.map { normalized($0.text) }
        func same(_ i: Int, _ j: Int) -> Bool {
            !runKeys[i].isEmpty && runKeys[i] == systemKeys[j] && abs(run[i].start - system[j].start) <= window
        }

        // Longest common subsequence, table kept for the walk back.
        var table = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
        for i in 1...n {
            for j in 1...m {
                table[i * (m + 1) + j] =
                    same(i - 1, j - 1)
                    ? table[(i - 1) * (m + 1) + j - 1] + 1
                    : max(table[(i - 1) * (m + 1) + j], table[i * (m + 1) + j - 1])
            }
        }
        var i = n, j = m
        while i > 0, j > 0 {
            if same(i - 1, j - 1), table[i * (m + 1) + j] == table[(i - 1) * (m + 1) + j - 1] + 1 {
                matched[i - 1] = true
                i -= 1
                j -= 1
            } else if table[(i - 1) * (m + 1) + j] >= table[i * (m + 1) + j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matched
    }

    /// Stretches that begin and end on a matched word, hold at least `minimumWords` matches, never
    /// more than `maximumGap` unmatched words in a row, and reach `matchThreshold` overall.
    private static func echoedStretches(in matched: [Bool]) -> [ClosedRange<Int>] {
        var stretches: [ClosedRange<Int>] = []
        var start: Int?
        var last = 0
        var count = 0
        func close() {
            guard let first = start else { return }
            if count >= minimumWords, Double(count) / Double(last - first + 1) >= matchThreshold {
                stretches.append(first...last)
            }
        }
        for (index, isMatch) in matched.enumerated() where isMatch {
            if start != nil, index - last - 1 > maximumGap {
                close()
                start = nil
            }
            if start == nil {
                start = index
                count = 0
            }
            last = index
            count += 1
        }
        close()
        return stretches
    }

    /// Index ranges of the words between pauses longer than `pauseThreshold`, long runs cut into
    /// pieces of `maximumRunWords`.
    private static func runs(of words: [TimedWord], pauseThreshold: TimeInterval) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        for index in 1...words.count {
            let ends =
                index == words.count
                || words[index].start - words[index - 1].end > pauseThreshold
                || index - start >= maximumRunWords
            if ends {
                result.append(start..<index)
                start = index
            }
        }
        return result
    }

    /// Lowercased letters and digits only, so punctuation and casing never hide a match.
    static func normalized(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
