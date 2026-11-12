// Purpose: Tests for the cross-recording voice library — embedding distance, learning/merging, and
//          the matching threshold that decides whether a speaker is recognised as someone known.
// Dependencies: Sources/App/Models/KnownVoice.swift, Sources/App/Store/VoiceDirectoryStore.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("VoiceEmbedding Tests")
struct VoiceEmbeddingTests {

    /// A deterministic pseudo-voice: reproducible across runs, unlike random vectors.
    private func vector(seed: Int, dimensions: Int = 256) -> [Float] {
        (0..<dimensions).map { index in
            Float((index &* 31 &+ seed &* 17) % 97) / 97.0 - 0.5
        }
    }

    @Test("Identical vectors have zero distance")
    func testIdenticalDistance() {
        let a = vector(seed: 1)
        #expect(VoiceEmbedding.distance(a, a) < 0.0001)
    }

    @Test("Distance is scale-invariant — magnitude must not decide identity")
    func testScaleInvariance() {
        let a = vector(seed: 3)
        let scaled = a.map { $0 * 7.5 }
        #expect(VoiceEmbedding.distance(a, scaled) < 0.0001)
    }

    @Test("Mismatched or empty vectors never look like a match")
    func testIncomparableVectors() {
        #expect(VoiceEmbedding.distance([1, 2, 3], [1, 2]) > VoiceEmbedding.matchThreshold)
        #expect(VoiceEmbedding.distance([], []) > VoiceEmbedding.matchThreshold)
    }

    @Test("All-zero and too-short embeddings are rejected as unusable")
    func testUsability() {
        #expect(!VoiceEmbedding.isUsable([Float](repeating: 0, count: 256)))
        #expect(!VoiceEmbedding.isUsable([1, 0, 0]))
        #expect(VoiceEmbedding.isUsable(vector(seed: 5)))
    }

    @Test("Normalizing yields unit length")
    func testNormalized() {
        let normalized = VoiceEmbedding.normalized(vector(seed: 9).map { $0 * 12 })
        let magnitude = normalized.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(magnitude - 1) < 0.0001)
    }
}

@Suite("KnownVoice Tests")
struct KnownVoiceTests {

    private func vector(seed: Int, dimensions: Int = 256) -> [Float] {
        (0..<dimensions).map { index in
            Float((index &* 31 &+ seed &* 17) % 97) / 97.0 - 0.5
        }
    }

    @Test("Merging moves the embedding toward the new sample but keeps it unit length")
    func testMergeStaysNormalized() {
        var voice = KnownVoice(name: "Anna", embedding: vector(seed: 1))
        let before = voice.embedding

        voice.merge(vector(seed: 2), spokenSeconds: 30)

        let magnitude = voice.embedding.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(magnitude - 1) < 0.0001)
        #expect(voice.embedding != before)
        #expect(voice.sampleCount == 2)
        #expect(voice.totalSpokenSeconds == 30)
    }

    @Test("A well-established voice is not derailed by one differing sample")
    func testMergeIsConservativeOnceEstablished() {
        var voice = KnownVoice(name: "Anna", embedding: vector(seed: 1))
        let original = voice.embedding
        for _ in 0..<9 { voice.merge(vector(seed: 1), spokenSeconds: 10) }

        voice.merge(vector(seed: 40), spokenSeconds: 10)

        // Still far closer to the original voice than to the outlier.
        let toOriginal = VoiceEmbedding.distance(voice.embedding, original)
        let toOutlier = VoiceEmbedding.distance(voice.embedding, vector(seed: 40))
        #expect(toOriginal < toOutlier)
    }

    @Test("A mismatched embedding is ignored rather than corrupting the voice")
    func testMergeRejectsWrongDimensions() {
        var voice = KnownVoice(name: "Anna", embedding: vector(seed: 1))
        let before = voice.embedding

        voice.merge([0.1, 0.2, 0.3], spokenSeconds: 5)

        #expect(voice.embedding == before)
        #expect(voice.sampleCount == 1)
    }
}

@Suite("VoiceDirectoryStore Tests")
struct VoiceDirectoryStoreTests {

    private func vector(seed: Int, dimensions: Int = 256) -> [Float] {
        (0..<dimensions).map { index in
            Float((index &* 31 &+ seed &* 17) % 97) / 97.0 - 0.5
        }
    }

    private func makeStore() -> (store: VoiceDirectoryStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-directory-tests-\(UUID().uuidString)", isDirectory: true)
        return (VoiceDirectoryStore(baseDirectory: directory), directory)
    }

    @Test("A learned voice is matched again by its own embedding")
    func testLearnThenMatch() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let embedding = vector(seed: 11)
        store.learn(name: "Anna", embedding: embedding, spokenSeconds: 42)

        let match = try #require(store.match(embedding))
        #expect(match.voice.name == "Anna")
        #expect(match.distance < VoiceEmbedding.matchThreshold)
    }

    @Test("An unrelated voice is not matched")
    func testNoFalseMatch() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.learn(name: "Anna", embedding: vector(seed: 11))
        // Inverted vector — maximally unlike Anna.
        #expect(store.match(vector(seed: 11).map { -$0 }) == nil)
    }

    @Test("Learning the same name twice merges instead of duplicating the person")
    func testLearnSameNameMerges() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.learn(name: "Anna", embedding: vector(seed: 11), spokenSeconds: 10)
        store.learn(name: "anna", embedding: vector(seed: 12), spokenSeconds: 20)

        #expect(store.voices.count == 1)
        #expect(store.voices[0].sampleCount == 2)
        #expect(store.voices[0].totalSpokenSeconds == 30)
    }

    @Test("Unusable embeddings and blank names are never stored")
    func testRejectsUnusableInput() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.learn(name: "Anna", embedding: [Float](repeating: 0, count: 256)) == nil)
        #expect(store.learn(name: "   ", embedding: vector(seed: 11)) == nil)
        #expect(store.voices.isEmpty)
    }

    @Test("Voices survive a reload from disk")
    func testPersistence() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.learn(name: "Anna", embedding: vector(seed: 11), spokenSeconds: 60)

        let reloaded = VoiceDirectoryStore(baseDirectory: directory)
        #expect(reloaded.names == ["Anna"])
        #expect(reloaded.match(vector(seed: 11)) != nil)
    }

    @Test("Renaming and deleting take effect and persist")
    func testRenameAndDelete() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let voice = try #require(store.learn(name: "Ana", embedding: vector(seed: 11)))
        store.rename(voice.id, to: "Anna Müller")
        #expect(store.names == ["Anna Müller"])

        store.delete(voice.id)
        #expect(store.voices.isEmpty)
        #expect(VoiceDirectoryStore(baseDirectory: directory).voices.isEmpty)
    }
}
