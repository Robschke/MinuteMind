// Purpose: Opt-in smoke test that runs both diarization engines and Parakeet on a real recording,
//          to check the FluidAudio upgrade and the Nemotron 3 engine end to end.
// Dependencies: Sources/App/Transcription/Nemotron3SpeakerDiarizer.swift,
//               Sources/App/Transcription/FluidAudioDiarizer.swift,
//               Sources/App/Services/ParakeetTranscriptionService.swift
// Notes: Skipped unless MM_DIARIZATION_SMOKE_FILE points at an audio file. Downloads models on the
//        first run and uses the Neural Engine, so it is far too heavy for the regular suite.
//        Run: MM_DIARIZATION_SMOKE_FILE=/path/to/file.m4a swift test --filter DiarizationEngineSmoke

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("DiarizationEngineSmoke")
struct DiarizationEngineSmokeTests {
    static let fileURL = ProcessInfo.processInfo.environment["MM_DIARIZATION_SMOKE_FILE"].map(URL.init(fileURLWithPath:))

    @Test("Both engines and Parakeet produce output", .enabled(if: fileURL != nil))
    func enginesProduceOutput() async throws {
        let url = try #require(Self.fileURL)

        for (name, engine) in [("fluidAudio", FluidAudioDiarizer() as SpeakerDiarizer), ("nemotron3", Nemotron3SpeakerDiarizer())] {
            let start = Date()
            let result = try await engine.diarize(fileURL: url, expectedSpeakers: nil)
            let speakers = Set(result.turns.map(\.speaker))
            let talk = result.turns.reduce(0) { $0 + ($1.end - $1.start) }
            print("[smoke] \(name): \(speakers.count) speakers, \(result.turns.count) turns, \(Int(talk)) s speech, \(result.embeddings.count) embeddings, \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
            #expect(!result.turns.isEmpty)
        }

        let parakeet = ParakeetTranscriptionService()
        if parakeet.isModelInstalled {
            let start = Date()
            let transcript = try await parakeet.transcribe(microphoneURL: nil, systemURL: url)
            print("[smoke] parakeet: \(String(format: "%.1f", Date().timeIntervalSince(start))) s, preview: \(String(describing: transcript).prefix(200))")
        }
    }
}
