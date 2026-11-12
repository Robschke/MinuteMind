// Purpose: On-device speaker diarization backed by FluidAudio's CoreML diarizer (pyannote-style
//          segmentation + speaker-embedding clustering, runs on the Neural Engine). Conforms to the
//          engine-independent SpeakerDiarizer protocol.
// Dependencies: FluidAudio (already a dependency for Parakeet transcription),
//               Sources/App/Transcription/SpeakerDiarization.swift (SpeakerDiarizer, SpeakerTurn).
// Used by: Sources/App/ViewModels/AppViewModel.swift (transcription paths that label speakers).
// Notes: Replaces the earlier vendored sherpa-onnx backend — FluidAudio ships the same capability
//        with no vendored binaries, no fetch prerequisite, and ANE acceleration.
//        Models download once via DiarizerModels.downloadIfNeeded() (cached by ModelHub on disk).
//        FluidAudio identifies speakers by String id; we map those to the Int cluster indices the
//        SpeakerAssignment logic expects, deterministically by first appearance. The clustered voice
//        embeddings come back alongside the turns and feed the cross-meeting voice library
//        (see Sources/App/Store/VoiceDirectoryStore.swift).

@preconcurrency import FluidAudio
import Foundation

struct FluidAudioDiarizer: SpeakerDiarizer {
    /// Clustering distance threshold (0.5–0.9). Lower yields more distinct speakers.
    var clusteringThreshold: Float = 0.7
    /// Segments shorter than this (seconds) are discarded.
    var minSpeechDuration: Float = 1.0
    /// Minimum silence gap (seconds) before splitting the same speaker's segments.
    var minSilenceGap: Float = 0.5

    func diarize(fileURL: URL, expectedSpeakers: Int?) async throws -> DiarizationResult {
        var config = DiarizerConfig()
        config.clusteringThreshold = clusteringThreshold
        config.minSpeechDuration = minSpeechDuration
        config.minSilenceGap = minSilenceGap
        config.numClusters = expectedSpeakers ?? -1  // -1 = auto-detect

        let models = try await DiarizerModels.downloadIfNeeded()

        try Task.checkCancellation()

        // Diarization is synchronous and CPU/ANE bound — keep it off the main actor.
        let output = try await Task.detached(priority: .userInitiated) {
            let samples = try AudioConverter().resampleAudioFile(fileURL)
            let manager = DiarizerManager(config: config)
            manager.initialize(models: models)
            defer { manager.cleanup() }
            let result = try manager.performCompleteDiarization(samples)
            // Reduce to Sendable primitives before crossing back. The speaker manager holds the
            // clustered voice embeddings that `performCompleteDiarization` just built up.
            let embeddings = manager.speakerManager.getAllSpeakers().mapValues(\.currentEmbedding)
            let segments = result.segments.map {
                (id: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            }
            return (segments: segments, embeddings: embeddings)
        }.value

        // Map FluidAudio's String speaker ids onto stable Int indices by first appearance.
        var indexBySpeakerId: [String: Int] = [:]
        var nextIndex = 0
        let turns = output.segments.map { segment in
            let index: Int
            if let existing = indexBySpeakerId[segment.id] {
                index = existing
            } else {
                index = nextIndex
                indexBySpeakerId[segment.id] = index
                nextIndex += 1
            }
            return SpeakerTurn(start: segment.start, end: segment.end, speaker: index)
        }

        // Carry the embeddings over onto the same indices, dropping any speaker that never made it
        // into a turn (and any vector too weak to identify anyone by).
        var embeddingsByIndex: [Int: [Float]] = [:]
        for (speakerId, embedding) in output.embeddings {
            guard let index = indexBySpeakerId[speakerId],
                VoiceEmbedding.isUsable(embedding)
            else { continue }
            embeddingsByIndex[index] = embedding
        }

        return DiarizationResult(turns: turns, embeddings: embeddingsByIndex)
    }
}
