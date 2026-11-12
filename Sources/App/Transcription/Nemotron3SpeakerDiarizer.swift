// Purpose: Speaker diarization backed by NVIDIA Nemotron 3 Diarization (streaming Sortformer,
//          up to 8 speakers) through FluidAudio's CoreML port. Conforms to SpeakerDiarizer so it
//          is a drop-in alternative to FluidAudioDiarizer.
// Dependencies: FluidAudio >= 0.17.4 (Nemotron3Diarizer / Nemotron3Models, DiarizerManager for
//               voice embeddings), Sources/App/Transcription/SpeakerDiarization.swift
//               (SpeakerDiarizer, SpeakerTurn, DiarizationResult), KnownVoice.swift (VoiceEmbedding).
// Used by: Sources/App/ViewModels/AppViewModel.swift (activeDiarization, engine picked in settings)
// Notes: Nemotron 3 only outputs per-frame speaker activity, no voice embeddings. The voice library
//        needs one embedding per speaker, so each speaker's clean (non-overlapping) speech is fed to
//        the same WeSpeaker extractor FluidAudioDiarizer uses. The vectors therefore live in the
//        same space and voices.json keeps matching across engines.
//        The WeSpeaker model takes exactly 10 s; shorter speech is tiled to fill the window rather
//        than zero-padded, because the all-ones mask would otherwise average in silence.
//        Weights are the general-access checkpoint (OpenMDW 1.1) that FluidAudio ships, never the
//        evaluation-only preview repo. The whole file is processed at once: memory grows with the
//        recording length (roughly 1.2 GB at the 3 h maximum, estimated).
//        `expectedSpeakers` is ignored: the model detects up to 8 speakers on its own.

@preconcurrency import CoreML
@preconcurrency import FluidAudio
import Foundation

struct Nemotron3SpeakerDiarizer: SpeakerDiarizer {
    /// `fast128` is the best-quality preset that still compiles for the Neural Engine.
    static let config = Nemotron3Config.fast128

    /// Probability above which a frame counts as the speaker talking.
    var activityThreshold: Float = 0.5
    /// Turns shorter than this are dropped as blips.
    var minTurnSeconds: Float = 0.3

    private static let sampleRate = 16_000
    private static let embeddingWindowSamples = 160_000

    func diarize(fileURL: URL, expectedSpeakers: Int?) async throws -> DiarizationResult {
        let threshold = activityThreshold
        let minTurn = minTurnSeconds
        let embeddingModels = try await DiarizerModels.downloadIfNeeded()
        try Task.checkCancellation()

        let output = try await Task.detached(priority: .userInitiated) {
            let samples = try AudioConverter().resampleAudioFile(fileURL)
            let models = try await Nemotron3Models.loadFromHuggingFace(
                config: Self.config, computeUnits: .cpuAndNeuralEngine)
            let diarizer = Nemotron3Diarizer(config: Self.config, models: models)
            let (probabilities, frameCount) = try diarizer.processComplete(samples)
            let segments = Nemotron3Diarizer.segments(
                probabilities: probabilities,
                frameCount: frameCount,
                numSpeakers: Self.config.numSpeakers,
                threshold: threshold,
                frameSeconds: Self.config.outputFrameSeconds,
                minDurationSeconds: minTurn)
                .map { (speaker: $0.speakerIndex, start: Double($0.startSeconds), end: Double($0.endSeconds)) }

            let manager = DiarizerManager(config: DiarizerConfig())
            manager.initialize(models: embeddingModels)
            defer { manager.cleanup() }
            let embeddings = Self.embeddings(for: segments, samples: samples, manager: manager)
            return (segments: segments, embeddings: embeddings)
        }.value

        // Renumber by first appearance so Speaker 1 is whoever talked first.
        var indexBySpeaker: [Int: Int] = [:]
        let turns = output.segments
            .sorted { $0.start < $1.start }
            .map { segment -> SpeakerTurn in
                let index = indexBySpeaker[segment.speaker] ?? {
                    let next = indexBySpeaker.count
                    indexBySpeaker[segment.speaker] = next
                    return next
                }()
                return SpeakerTurn(start: segment.start, end: segment.end, speaker: index)
            }

        var embeddingsByIndex: [Int: [Float]] = [:]
        for (speaker, embedding) in output.embeddings {
            guard let index = indexBySpeaker[speaker], VoiceEmbedding.isUsable(embedding) else { continue }
            embeddingsByIndex[index] = embedding
        }
        return DiarizationResult(turns: turns, embeddings: embeddingsByIndex)
    }

    /// One voice embedding per speaker from up to 10 s of speech where nobody else talks.
    private static func embeddings(
        for segments: [(speaker: Int, start: Double, end: Double)],
        samples: [Float],
        manager: DiarizerManager
    ) -> [Int: [Float]] {
        var result: [Int: [Float]] = [:]
        let speakers = Set(segments.map(\.speaker))
        for speaker in speakers {
            let others = segments.filter { $0.speaker != speaker }
            var clip: [Float] = []
            // Longest turns first: they carry the most stable voice.
            for turn in segments.filter({ $0.speaker == speaker }).sorted(by: { ($0.end - $0.start) > ($1.end - $1.start) }) {
                for range in exclusiveRanges(of: (turn.start, turn.end), excluding: others) {
                    let lower = max(0, Int(range.start * Double(sampleRate)))
                    let upper = min(samples.count, Int(range.end * Double(sampleRate)))
                    guard upper > lower else { continue }
                    clip.append(contentsOf: samples[lower..<upper])
                    if clip.count >= embeddingWindowSamples { break }
                }
                if clip.count >= embeddingWindowSamples { break }
            }
            // Below ~1.5 s of clean speech the vector is too noisy to identify anyone by.
            guard clip.count >= sampleRate * 3 / 2 else { continue }
            var window = [Float]()
            window.reserveCapacity(embeddingWindowSamples)
            while window.count < embeddingWindowSamples {
                window.append(contentsOf: clip.prefix(embeddingWindowSamples - window.count))
            }
            if let embedding = try? manager.extractSpeakerEmbedding(from: window) {
                result[speaker] = embedding
            }
        }
        return result
    }

    /// The parts of `turn` that no other speaker's segment overlaps.
    private static func exclusiveRanges(
        of turn: (start: Double, end: Double),
        excluding others: [(speaker: Int, start: Double, end: Double)]
    ) -> [(start: Double, end: Double)] {
        var ranges = [turn]
        for other in others where other.end > turn.start && other.start < turn.end {
            ranges = ranges.flatMap { range -> [(start: Double, end: Double)] in
                guard other.end > range.start, other.start < range.end else { return [range] }
                var pieces: [(start: Double, end: Double)] = []
                if other.start > range.start { pieces.append((range.start, other.start)) }
                if other.end < range.end { pieces.append((other.end, range.end)) }
                return pieces
            }
        }
        return ranges
    }
}
