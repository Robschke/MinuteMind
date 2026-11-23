// Purpose: Measures transcription accuracy on a folder of reference clips: word error rate and
//          recall of important terms, for the installed Parakeet model with and without audio
//          preprocessing. The yardstick for every change to the transcription pipeline.
// Dependencies: Sources/App/Services/ParakeetTranscriptionService.swift,
//               Sources/App/Services/AudioPreprocessor.swift
// Notes: The scorer tests always run. The measurement is skipped unless MM_ASR_EVAL_DIR points at
//        a folder; it loads the speech model and uses the Neural Engine, far too heavy for the
//        regular suite.
//        Folder layout: one audio file per clip (.m4a, .wav or .caf) and beside it a text file of
//        the same name with what was really said ("clip1.m4a" + "clip1.txt"). A reference may be
//        a corrected transcript export: "[MM:SS] Speaker:" prefixes and "[overlapping]" marks are
//        ignored. An optional "terms.txt" (one term per line: names, products, jargon) adds the
//        share of those terms the engine got right.
//        Scores are corpus level (all errors over all reference words), so long clips weigh more.
//        Run: MM_ASR_EVAL_DIR=/path/to/clips swift test --filter TranscriptionEval
//        A second opt-in test runs the whole two-channel path on one real recording (see
//        twoChannelPipeline).

import AVFoundation
import Foundation
import Testing

@testable import MinuteMindApp

/// Word error rate between a reference and a recognized text.
enum WordErrorRate {

    /// Lowercased words without punctuation; transcript line prefixes and overlap marks removed.
    static func words(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { line -> String in
                var body = Substring(line)
                if body.hasPrefix("["), let close = body.firstIndex(of: "]"),
                    let colon = body[close...].firstIndex(of: ":")
                {
                    body = body[body.index(after: colon)...]
                }
                return body.replacingOccurrences(of: "[overlapping]", with: " ")
            }
            .joined(separator: " ")
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { String($0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
            .filter { !$0.isEmpty }
    }

    /// Substitutions, deletions and insertions needed to turn `hypothesis` into `reference`.
    static func errors(reference: [String], hypothesis: [String]) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }
        var previous = Array(0...hypothesis.count)
        var current = [Int](repeating: 0, count: hypothesis.count + 1)
        for i in 1...reference.count {
            current[0] = i
            for j in 1...hypothesis.count {
                let cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[hypothesis.count]
    }

    /// How many occurrences of `terms` in the reference also appear in the hypothesis.
    static func termHits(terms: [String], reference: [String], hypothesis: [String]) -> (found: Int, expected: Int) {
        func count(_ term: [String], in words: [String]) -> Int {
            guard !term.isEmpty, words.count >= term.count else { return 0 }
            return (0...(words.count - term.count)).filter { Array(words[$0..<($0 + term.count)]) == term }.count
        }
        var found = 0
        var expected = 0
        for term in terms.map(words) where !term.isEmpty {
            let inReference = count(term, in: reference)
            expected += inReference
            found += min(inReference, count(term, in: hypothesis))
        }
        return (found, expected)
    }
}

@Suite("TranscriptionEval")
struct TranscriptionEvalTests {
    static let folder = ProcessInfo.processInfo.environment["MM_ASR_EVAL_DIR"].map(URL.init(fileURLWithPath:))

    // MARK: - Scorer

    @Test("Punctuation, case and transcript prefixes do not count as errors")
    func normalization() {
        let reference = WordErrorRate.words("[00:12] Anna: [overlapping] Ja, das passt.\n\n[00:15] You: Gut!")
        #expect(reference == ["ja", "das", "passt", "gut"])
    }

    @Test("Substitutions, deletions and insertions each count once")
    func errorCount() {
        let reference = WordErrorRate.words("wir treffen uns am Donnerstag um zehn")
        #expect(WordErrorRate.errors(reference: reference, hypothesis: reference) == 0)
        #expect(WordErrorRate.errors(reference: reference, hypothesis: WordErrorRate.words("wir treffen uns am Dienstag um zehn")) == 1)
        #expect(WordErrorRate.errors(reference: reference, hypothesis: WordErrorRate.words("wir treffen uns Donnerstag um zehn")) == 1)
        #expect(WordErrorRate.errors(reference: reference, hypothesis: WordErrorRate.words("wir treffen uns dann am Donnerstag um zehn")) == 1)
        #expect(WordErrorRate.errors(reference: reference, hypothesis: []) == reference.count)
    }

    @Test("Term recall counts each reference occurrence at most once")
    func termRecall() {
        let reference = WordErrorRate.words("Lumen baut das mit Kubernetes und Lumen testet es")
        let hypothesis = WordErrorRate.words("Lumen baut das mit Kuba und Lumina testet es")
        let hits = WordErrorRate.termHits(terms: ["Lumen", "Kubernetes"], reference: reference, hypothesis: hypothesis)
        #expect(hits.expected == 3)
        #expect(hits.found == 1)
    }

    // MARK: - Measurement

    @Test("Word error rate on the reference clips", .enabled(if: folder != nil))
    func measure() async throws {
        let folder = try #require(Self.folder)
        let parakeet = ParakeetTranscriptionService()
        try #require(parakeet.isModelInstalled, "Install the Parakeet model in MinuteMind first")

        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let clips = files
            .filter { ["m4a", "wav", "caf"].contains($0.pathExtension.lowercased()) }
            .filter { FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("txt").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!clips.isEmpty, "No audio file with a reference .txt beside it in \(folder.path)")
        let terms = ((try? String(contentsOf: folder.appendingPathComponent("terms.txt"), encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        struct Total { var errors = 0, words = 0, found = 0, expected = 0 }
        var totals: [String: Total] = [:]
        let variants = ["plain", "preprocessed"]

        for clip in clips {
            let referenceText = try String(
                contentsOf: clip.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
            let reference = WordErrorRate.words(referenceText)
            for variant in variants {
                var audio = clip
                var temporary: URL?
                if variant == "preprocessed" {
                    guard let cleaned = await AudioPreprocessor.process(url: clip) else { continue }
                    audio = cleaned
                    temporary = cleaned
                }
                defer { temporary.map { try? FileManager.default.removeItem(at: $0) } }

                let hypothesis = WordErrorRate.words(
                    try await parakeet.transcribe(microphoneURL: nil, systemURL: audio).text)
                let errors = WordErrorRate.errors(reference: reference, hypothesis: hypothesis)
                let hits = WordErrorRate.termHits(terms: terms, reference: reference, hypothesis: hypothesis)
                var total = totals[variant] ?? Total()
                total.errors += errors
                total.words += reference.count
                total.found += hits.found
                total.expected += hits.expected
                totals[variant] = total
                print("[eval] \(clip.lastPathComponent) \(variant): \(Self.percent(errors, of: reference.count)) WER (\(errors) of \(reference.count) words)")
            }
        }

        for variant in variants {
            guard let total = totals[variant] else { continue }
            let termLine = total.expected > 0
                ? ", terms \(total.found) of \(total.expected) (\(Self.percent(total.found, of: total.expected)))" : ""
            print("[eval] TOTAL \(variant): \(Self.percent(total.errors, of: total.words)) WER over \(total.words) words\(termLine)")
        }
        #expect(totals["plain"] != nil)
    }

    /// Runs the whole two-channel path (alignment, echo removal, word-level speakers) on one real
    /// recording and writes the transcript beside a summary line, for comparing pipeline versions.
    /// Run: MM_ASR_PAIR_MIC=<mic file> MM_ASR_PAIR_SYSTEM=<system file> [MM_ASR_PAIR_DIARIZE_MIC=1]
    ///      swift test --filter TranscriptionEval
    @Test("Two-channel pipeline on a real recording", .enabled(if: pair != nil))
    func twoChannelPipeline() async throws {
        let pair = try #require(Self.pair)
        let parakeet = ParakeetTranscriptionService()
        try #require(parakeet.isModelInstalled, "Install the Parakeet model in MinuteMind first")

        func seconds(_ url: URL) async -> TimeInterval? {
            (try? await AVURLAsset(url: url).load(.duration))?.seconds
        }
        let offset = ChannelAlignment.estimatedOffset(
            microphoneDuration: await seconds(pair.mic), systemDuration: await seconds(pair.system))
        let transcript = try await parakeet.transcribe(
            microphoneURL: pair.mic, systemURL: pair.system, systemAudioOffset: offset,
            diarization: DiarizationOptions(
                diarizer: Nemotron3SpeakerDiarizer(),
                includeMicrophone: ProcessInfo.processInfo.environment["MM_ASR_PAIR_DIARIZE_MIC"] == "1"))

        let lines = transcript.text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let overlapping = lines.filter { $0.contains("[overlapping]") }.count
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("mm-pair-transcript.txt")
        try transcript.text.write(to: output, atomically: true, encoding: .utf8)
        print("[eval] pair: offset \(String(format: "%.2f", offset)) s, \(lines.count) lines, \(overlapping) overlapping, \(transcript.speakers.count) speakers, written to \(output.path)")
        #expect(!lines.isEmpty)
    }

    static let pair: (mic: URL, system: URL)? = {
        let environment = ProcessInfo.processInfo.environment
        guard let mic = environment["MM_ASR_PAIR_MIC"], let system = environment["MM_ASR_PAIR_SYSTEM"] else { return nil }
        return (URL(fileURLWithPath: mic), URL(fileURLWithPath: system))
    }()

    private static func percent(_ part: Int, of whole: Int) -> String {
        whole == 0 ? "n/a" : String(format: "%.1f %%", Double(part) / Double(whole) * 100)
    }
}
