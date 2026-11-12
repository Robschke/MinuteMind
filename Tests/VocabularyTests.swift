// Purpose: Tests for the dictionary: misheard forms are replaced whole-word and case-insensitively,
//          speaker prefixes stay intact, and the store merges and persists entries.
// Dependencies: Sources/App/Store/VocabularyStore.swift (VocabularyStore, VocabularyCorrection)

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("Vocabulary Tests")
struct VocabularyTests {
    private let entries = [
        VocabularyEntry(term: "Auth0", variants: ["aus SEO", "auth zero"]),
        VocabularyEntry(term: "MinuteMind", variants: ["minute mind"]),
        VocabularyEntry(term: "GMS", variants: ["gms"]),
    ]

    @Test("Misheard forms become the correct term")
    func testReplacesVariants() {
        let input = "[00:05] You: wir nutzen aus SEO für den Login in minute mind"
        let (output, count) = VocabularyCorrection.apply(input, entries: entries)
        #expect(output == "[00:05] You: wir nutzen Auth0 für den Login in MinuteMind")
        #expect(count == 2)
    }

    @Test("Only whole words are replaced")
    func testWholeWordsOnly() {
        let (output, count) = VocabularyCorrection.apply("Programs and gmsx stay, gms changes.", entries: entries)
        #expect(output == "Programs and gmsx stay, GMS changes.")
        #expect(count == 1)
    }

    @Test("Speaker prefixes are never touched")
    func testKeepsPrefix() {
        let speakerEntries = [VocabularyEntry(term: "Robin", variants: ["Speaker 1"])]
        let (output, _) = VocabularyCorrection.apply("[01:00] Speaker 1: hi Speaker 1", entries: speakerEntries)
        #expect(output == "[01:00] Speaker 1: hi Robin")
    }

    @MainActor
    @Test("Adding an existing term merges variants and survives a reload")
    func testStoreMergesAndPersists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = VocabularyStore(baseDirectory: dir)
        store.add(term: "Auth0", variants: ["aus SEO"])
        store.add(term: "auth0", variants: ["auth zero", "AUS SEO", "Auth0"])
        #expect(store.entries.count == 1)
        #expect(store.entries[0].variants == ["aus SEO", "auth zero"])

        let reloaded = VocabularyStore(baseDirectory: dir)
        // Dates round to whole seconds in ISO 8601, so compare what matters.
        #expect(reloaded.entries.map(\.id) == store.entries.map(\.id))
        #expect(reloaded.entries.map(\.variants) == store.entries.map(\.variants))
        #expect(reloaded.promptContext.contains("Auth0 (often misheard as: aus SEO, auth zero)"))
    }
}
