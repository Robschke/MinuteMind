// Purpose: Engine-independent speaker diarization model + the logic that maps diarization turns
//          onto transcribed utterances, labeling them "Speaker 1", "Speaker 2", … in
//          first-appearance order. The concrete diarizer (see FluidAudioDiarizer) plugs in behind
//          the `SpeakerDiarizer` protocol; this file stays engine-agnostic so it compiles and is
//          unit-tested on its own.
// Dependencies: none.
// Used by: Sources/App/Transcription/TranscriptionService.swift (SpeechAnalyzer path, labels whole
//          utterances), Sources/App/Services/ParakeetTranscriptionService.swift (labels word by
//          word, see SpeakerLabeler.utterances).
// Notes: The remote/system-audio channel is one mixed stream, so diarization runs on it to split
//        multiple remote participants. The microphone channel is the known local speaker ("You")
//        and is only diarized for in-person meetings (DiarizationOptions.includeMicrophone).
//        Engines with word timings label per word; engines that only return utterances label
//        each utterance by the turn it overlaps most.

import Foundation

/// A contiguous stretch of audio attributed to one clustered speaker (0-based index).
struct SpeakerTurn: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Int
}

/// What a diarizer produces for one audio file: the turns, plus a voice embedding per cluster when
/// the engine can supply one. Embeddings are what makes a speaker recognisable in *later*
/// recordings; engines without them still work, they just cannot be matched across meetings.
struct DiarizationResult: Sendable {
    let turns: [SpeakerTurn]
    /// Voice embedding keyed by the cluster index used in `turns`.
    let embeddings: [Int: [Float]]

    init(turns: [SpeakerTurn], embeddings: [Int: [Float]] = [:]) {
        self.turns = turns
        self.embeddings = embeddings
    }

    static let empty = DiarizationResult(turns: [])
}

/// A short, representative audio excerpt for one diarized speaker — what the naming UI plays back.
struct SpeakerSample: Sendable, Equatable {
    let label: String
    let channel: RecordingSession.Channel
    let start: TimeInterval
    let end: TimeInterval
    /// Voice embedding for this speaker, when the diarizer produced one.
    let embedding: [Float]?
    /// How long this speaker talked in total — shown in the naming UI and used to weight the voice.
    let spokenSeconds: TimeInterval

    init(
        label: String,
        channel: RecordingSession.Channel,
        start: TimeInterval,
        end: TimeInterval,
        embedding: [Float]? = nil,
        spokenSeconds: TimeInterval = 0
    ) {
        self.label = label
        self.channel = channel
        self.start = start
        self.end = end
        self.embedding = embedding
        self.spokenSeconds = spokenSeconds
    }
}

/// A finished transcript plus the speakers that were detected while producing it.
struct LabeledTranscript: Sendable {
    let text: String
    let speakers: [SpeakerSample]

    init(text: String, speakers: [SpeakerSample] = []) {
        self.text = text
        self.speakers = speakers
    }
}

enum SpeakerSampling {
    /// Shortest excerpt worth offering for playback.
    static let minimumSampleSeconds: TimeInterval = 1.0
    /// Excerpts are capped so playback stays snappy.
    static let maximumSampleSeconds: TimeInterval = 6.0

    /// Picks one representative excerpt per speaker: their longest utterance, capped in length.
    /// The local speaker ("You") is skipped — there is no point naming yourself.
    ///
    /// - Parameter embeddings: voice embeddings keyed by speaker label, as recorded by
    ///   `SpeakerLabeler`. Attached to the samples so the caller can match them against the
    ///   voice library.
    static func samples(
        from utterances: [TranscriptUtterance],
        channel: RecordingSession.Channel,
        embeddings: [String: [Float]] = [:]
    ) -> [SpeakerSample] {
        var longestByLabel: [String: TranscriptUtterance] = [:]
        var spokenByLabel: [String: TimeInterval] = [:]
        for utterance in utterances {
            guard utterance.speaker != TranscriptFormatting.localSpeaker else { continue }
            spokenByLabel[utterance.speaker, default: 0] += max(0, utterance.duration)
            if let current = longestByLabel[utterance.speaker],
                current.duration >= utterance.duration
            {
                continue
            }
            longestByLabel[utterance.speaker] = utterance
        }

        return longestByLabel.values
            .filter { $0.duration >= minimumSampleSeconds }
            .map { utterance in
                SpeakerSample(
                    label: utterance.speaker,
                    channel: channel,
                    start: utterance.start,
                    end: utterance.start + min(utterance.duration, maximumSampleSeconds),
                    embedding: embeddings[utterance.speaker],
                    spokenSeconds: spokenByLabel[utterance.speaker] ?? 0)
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

/// How a transcription should label speakers.
struct DiarizationOptions: Sendable {
    let diarizer: SpeakerDiarizer
    /// Diarize the microphone channel as well — for in-person meetings where several people share
    /// one microphone. When false the microphone is always the local speaker ("You").
    let includeMicrophone: Bool
}

/// Produces speaker turns for an audio file. Implemented by `FluidAudioDiarizer`.
protocol SpeakerDiarizer: Sendable {
    /// - Parameter expectedSpeakers: optional hint for the number of speakers (nil = auto-detect).
    func diarize(fileURL: URL, expectedSpeakers: Int?) async throws -> DiarizationResult
}

/// Labels speakers across several audio channels with one shared numbering, so that a speaker on
/// the microphone and a speaker on the system channel never end up sharing a number. Clusters are
/// namespaced per channel because each channel is diarized independently — cluster 0 on the mic is
/// a different person from cluster 0 on the system audio.
struct SpeakerLabeler {
    private var numberByKey: [String: Int] = [:]
    private var nextNumber = 1

    /// Voice embedding per assigned label, collected as clusters are numbered. This is what lets
    /// the caller recognise "Speaker 2" as someone already in the voice library.
    private(set) var embeddingByLabel: [String: [Float]] = [:]

    /// Number of distinct speakers labeled so far.
    var speakerCount: Int { numberByKey.count }

    /// Assigns "Speaker N" labels to one channel's utterances, continuing the shared numbering.
    /// Utterances that overlap no turn get `fallbackLabel`.
    mutating func labels(
        forUtteranceRanges ranges: [(start: TimeInterval, duration: TimeInterval)],
        result: DiarizationResult,
        channel: String,
        fallbackLabel: String
    ) -> [String] {
        ranges.map { range in
            guard
                let cluster = SpeakerAssignment.speakerIndex(
                    utteranceStart: range.start, duration: range.duration, turns: result.turns)
            else { return fallbackLabel }
            return label(forCluster: cluster, result: result, channel: channel)
        }
    }

    /// Turns one channel's words into labelled utterances, deciding the speaker word by word:
    /// an utterance ends at a pause or where the speaker changes, so two people answering each
    /// other without a pause no longer share one block. Words no turn covers get `fallbackLabel`.
    mutating func utterances(
        from words: [TimedWord],
        result: DiarizationResult,
        channel: String,
        fallbackLabel: String,
        language: String,
        pauseThreshold: TimeInterval = 0.8
    ) -> [TranscriptUtterance] {
        guard !words.isEmpty else { return [] }
        let clusters = SpeakerAssignment.wordSpeakers(
            words: words, turns: result.turns, pauseThreshold: pauseThreshold)

        var utterances: [TranscriptUtterance] = []
        var start = 0
        for index in 1...words.count {
            let ends =
                index == words.count
                || clusters[index] != clusters[index - 1]
                || words[index].start - words[index - 1].end > pauseThreshold
            guard ends else { continue }
            let speaker =
                clusters[start].map { label(forCluster: $0, result: result, channel: channel) }
                ?? fallbackLabel
            utterances.append(
                TranscriptUtterance(
                    speaker: speaker,
                    text: words[start..<index].map(\.text).joined(separator: " "),
                    start: words[start].start,
                    duration: words[index - 1].end - words[start].start,
                    language: language))
            start = index
        }
        return utterances
    }

    /// "Speaker N" for a cluster of `channel`, numbered by first use.
    private mutating func label(forCluster cluster: Int, result: DiarizationResult, channel: String)
        -> String
    {
        let key = "\(channel)#\(cluster)"
        if let existing = numberByKey[key] { return "Speaker \(existing)" }

        let number = nextNumber
        numberByKey[key] = number
        nextNumber += 1

        let label = "Speaker \(number)"
        if let embedding = result.embeddings[cluster] {
            embeddingByLabel[label] = embedding
        }
        return label
    }
}

enum SpeakerAssignment {

    /// Picks the speaker whose turns overlap the utterance's time range the most.
    /// Returns nil when no turn overlaps (caller falls back to a generic label).
    static func speakerIndex(
        utteranceStart start: TimeInterval,
        duration: TimeInterval,
        turns: [SpeakerTurn]
    ) -> Int? {
        let end = start + max(duration, 0)
        var overlapBySpeaker: [Int: TimeInterval] = [:]
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 {
                overlapBySpeaker[turn.speaker, default: 0] += overlap
            }
        }
        // Tie-break deterministically on the lower speaker index.
        return overlapBySpeaker
            .max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?
            .key
    }

    /// The speaker of every word. Passes over the raw per-word overlap:
    /// words no turn covers take their neighbour's speaker inside the same run of speech; a single
    /// word that disagrees with both neighbours follows them (diarizer blips); a change of
    /// speaker that falls mid-sentence moves up to two words to the nearest sentence end or
    /// audible gap, because turn boundaries are only accurate to a few hundred milliseconds; and
    /// fragments of one or two words join a neighbour (see mergeFragments).
    static func wordSpeakers(
        words: [TimedWord],
        turns: [SpeakerTurn],
        pauseThreshold: TimeInterval = 0.8
    ) -> [Int?] {
        guard !words.isEmpty else { return [] }
        var speakers: [Int?] = words.map {
            speakerIndex(utteranceStart: $0.start, duration: max($0.end - $0.start, 0.02), turns: turns)
        }
        let count = words.count
        /// Silence before word `index`.
        func gap(_ index: Int) -> TimeInterval { words[index].start - words[index - 1].end }

        for index in 1..<count where speakers[index] == nil && gap(index) <= pauseThreshold {
            speakers[index] = speakers[index - 1]
        }
        for index in stride(from: count - 2, through: 0, by: -1)
        where speakers[index] == nil && gap(index + 1) <= pauseThreshold {
            speakers[index] = speakers[index + 1]
        }

        if count >= 3 {
            for index in 1..<(count - 1)
            where speakers[index] != speakers[index - 1] && speakers[index - 1] != nil
                && speakers[index - 1] == speakers[index + 1]
                && gap(index) <= pauseThreshold && gap(index + 1) <= pauseThreshold
                // "Genau." between two sentences is a remark of its own, not a blip.
                && !(endsSentence(words[index - 1].text) && endsSentence(words[index].text))
            {
                speakers[index] = speakers[index - 1]
            }
        }

        var index = 1
        while index < count {
            defer { index += 1 }
            guard let before = speakers[index - 1], let after = speakers[index], before != after,
                gap(index) <= pauseThreshold
            else { continue }

            var runStart = index - 1
            while runStart > 0, speakers[runStart - 1] == before, gap(runStart) <= pauseThreshold {
                runStart -= 1
            }
            var runEnd = index + 1
            while runEnd < count, speakers[runEnd] == after, gap(runEnd) <= pauseThreshold {
                runEnd += 1
            }
            let candidates = max(runStart + 1, index - 2)...min(runEnd - 1, index + 2)

            let sentenceEnds = candidates.filter { endsSentence(words[$0 - 1].text) }
            let target: Int
            if let nearest = sentenceEnds.min(by: { abs($0 - index) < abs($1 - index) }) {
                target = nearest
            } else if let widest = candidates.max(by: { gap($0) < gap($1) }),
                gap(widest) >= 0.25, gap(widest) > gap(index)
            {
                target = widest
            } else {
                target = index
            }

            if target < index {
                for moved in target..<index { speakers[moved] = after }
            } else if target > index {
                for moved in index..<target { speakers[moved] = before }
                index = target
            }
        }
        mergeFragments(&speakers, words: words, pauseThreshold: pauseThreshold)
        return speakers
    }

    /// One or two words attributed to a speaker in the middle of someone else's flow are almost
    /// always a diarizer slip ("Ich | meine, man könnte …"), unless they are a remark of their own
    /// ("Ja." between two sentences). Such fragments join the neighbour they belong to: the next
    /// speaker when the previous word ended a sentence, else the previous one.
    private static func mergeFragments(
        _ speakers: inout [Int?], words: [TimedWord], pauseThreshold: TimeInterval
    ) {
        let count = words.count
        func joined(_ index: Int) -> Bool {
            index > 0 && index < count && words[index].start - words[index - 1].end <= pauseThreshold
        }
        var start = 0
        while start < count {
            var end = start + 1
            while end < count, speakers[end] == speakers[start], joined(end) { end += 1 }
            defer { start = end }

            let hasPrevious = joined(start) && speakers[start - 1] != nil
            let hasNext = joined(end) && speakers[end] != nil
            guard end - start <= 2, hasPrevious || hasNext else { continue }
            let startsSentence = !hasPrevious || endsSentence(words[start - 1].text)
            let finishesSentence = endsSentence(words[end - 1].text)
            if startsSentence && (finishesSentence || !hasNext) { continue }  // a remark of its own

            let target = startsSentence || !hasPrevious ? speakers[end] : speakers[start - 1]
            for index in start..<end { speakers[index] = target }
        }
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    /// Assigns a sequential, first-appearance-ordered "Speaker N" label to each utterance based on
    /// which diarization turn it overlaps. Utterances must be supplied in chronological order so
    /// numbering follows the order speakers first appear. Utterances overlapping no turn get
    /// `fallbackLabel`.
    ///
    /// - Returns: labels parallel to `utteranceRanges`.
    static func labelUtterances(
        utteranceRanges: [(start: TimeInterval, duration: TimeInterval)],
        turns: [SpeakerTurn],
        fallbackLabel: String = "Speaker ?"
    ) -> [String] {
        var displayNumberByCluster: [Int: Int] = [:]
        var nextNumber = 1
        return utteranceRanges.map { range in
            guard let cluster = speakerIndex(
                utteranceStart: range.start, duration: range.duration, turns: turns)
            else { return fallbackLabel }

            let number: Int
            if let existing = displayNumberByCluster[cluster] {
                number = existing
            } else {
                number = nextNumber
                displayNumberByCluster[cluster] = number
                nextNumber += 1
            }
            return "Speaker \(number)"
        }
    }
}
