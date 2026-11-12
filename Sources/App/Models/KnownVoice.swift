// Purpose: A person's voice remembered across recordings — a name plus the averaged speaker
//          embedding that identifies them, so naming a speaker once makes every later meeting
//          label them automatically.
// Dependencies: Foundation only. Deliberately free of FluidAudio so the matching logic can be
//               unit-tested without loading CoreML models.
// Used by: Sources/App/Store/VoiceDirectoryStore.swift,
//          Sources/App/ViewModels/AppViewModel.swift (auto-naming after diarization),
//          Sources/App/Views/SpeakerNamingSheet.swift
// Notes: Embeddings are the 256-dimension L2-normalized vectors FluidAudio's diarizer produces.
//        They are merged with an exponential moving average rather than replaced, so a voice gets
//        more robust with every meeting instead of being overwritten by the latest (possibly noisy)
//        sample.

import Foundation

/// One person's voice, learned from recordings the user has named speakers in.
struct KnownVoice: Codable, Identifiable, Equatable {
    let id: UUID
    /// Display name, as the user typed it in the naming sheet.
    var name: String
    /// Averaged, L2-normalized speaker embedding.
    var embedding: [Float]
    /// How many times a sample has been merged in — a rough confidence signal for the UI.
    var sampleCount: Int
    /// Total speech attributed to this voice, across all recordings.
    var totalSpokenSeconds: TimeInterval
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        embedding: [Float],
        sampleCount: Int = 1,
        totalSpokenSeconds: TimeInterval = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.embedding = VoiceEmbedding.normalized(embedding)
        self.sampleCount = sampleCount
        self.totalSpokenSeconds = totalSpokenSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Blends `sample` into the stored embedding. Early samples move the average a lot, later ones
    /// only refine it — a voice learned from ten meetings should not be derailed by one bad clip.
    mutating func merge(_ sample: [Float], spokenSeconds: TimeInterval) {
        let incoming = VoiceEmbedding.normalized(sample)
        guard incoming.count == embedding.count else { return }

        // Weight by how much evidence is already stored, floored so old voices stay adaptable.
        let alpha = max(1.0 / Float(sampleCount + 1), 0.1)
        var blended = [Float](repeating: 0, count: embedding.count)
        for index in embedding.indices {
            blended[index] = embedding[index] * (1 - alpha) + incoming[index] * alpha
        }

        embedding = VoiceEmbedding.normalized(blended)
        sampleCount += 1
        totalSpokenSeconds += max(0, spokenSeconds)
        updatedAt = Date()
    }
}

enum VoiceEmbedding {

    /// Cosine distance below which two embeddings are treated as the same person.
    ///
    /// Stricter than FluidAudio's within-recording threshold (0.65) on purpose: matching across
    /// recordings means crossing different microphones, rooms and codecs, and a *wrong* name
    /// silently attached to a transcript is worse than no name at all.
    static let matchThreshold: Float = 0.55

    /// Cosine distance in [0, 2]. 0 means identical direction.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return .greatestFiniteMagnitude }
        return 1 - dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Unit-length copy. Returns the input unchanged when it has no magnitude.
    static func normalized(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for value in vector { sumSquares += value * value }
        let magnitude = sumSquares.squareRoot()
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    /// True when the vector carries enough signal to be worth storing — all-zero or near-silent
    /// embeddings come out of segments that were mostly silence.
    static func isUsable(_ vector: [Float]) -> Bool {
        guard vector.count >= 32 else { return false }
        var sumSquares: Float = 0
        for value in vector { sumSquares += value * value }
        return sumSquares.squareRoot() > 0.1
    }
}
