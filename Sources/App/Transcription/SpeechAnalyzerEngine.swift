// Purpose: macOS 26+ on-device speech-to-text via Apple's modern SpeechAnalyzer / SpeechTranscriber
//          API. Transcribes a whole audio file into time-ranged utterances — higher quality,
//          proper punctuation, and no 5-minute/25-MB chunking limits (unlike SFSpeechRecognizer).
// Dependencies: Speech.framework (SpeechAnalyzer, SpeechTranscriber, AssetInventory), AVFoundation.
// Used by: Sources/App/Transcription/TranscriptionService.swift (preferred Apple engine on macOS 26,
//          with automatic fallback to SFSpeechRecognizer when a locale model is unavailable).
// Notes: The language model is an on-device asset downloaded on first use per locale. `prepare`
//        installs it if missing and throws `.localeNotSupported` so the caller can fall back.
//        File transcription only emits final results, so we collect them all into ordered utterances.

import Foundation
import AVFoundation
import Speech

@available(macOS 26.0, *)
enum SpeechAnalyzerEngine {

    /// A single transcribed utterance with audio timing, source-agnostic and Sendable.
    struct Utterance: Sendable {
        let text: String
        let start: TimeInterval
        let duration: TimeInterval
    }

    enum EngineError: Error, LocalizedError {
        case localeNotSupported(String)

        var errorDescription: String? {
            switch self {
            case .localeNotSupported(let id):
                return "SpeechAnalyzer has no on-device model for locale \(id)."
            }
        }
    }

    /// Best locale for the requested identifier: the exact locale if supported, otherwise a
    /// language-family match (e.g. "de" → "de-DE"), otherwise nil.
    static func resolveSupportedLocale(for identifier: String) async -> Locale? {
        let requested = Locale(identifier: identifier)
        let supported = await SpeechTranscriber.supportedLocales
        let reqBCP47 = requested.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == reqBCP47 }) {
            return exact
        }
        let reqLang = requested.language.languageCode?.identifier
        return supported.first { $0.language.languageCode?.identifier == reqLang }
    }

    /// Ensures the on-device model for `locale` is installed, downloading it if necessary.
    private static func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let target = locale.identifier(.bcp47)
        if installed.contains(where: { $0.identifier(.bcp47) == target }) {
            return
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// Transcribes the entire audio file into ordered, time-ranged utterances.
    /// Throws `EngineError.localeNotSupported` when no model matches the identifier so the
    /// caller can fall back to the legacy recognizer.
    static func transcribe(fileURL: URL, localeIdentifier: String) async throws -> [Utterance] {
        guard let locale = await resolveSupportedLocale(for: localeIdentifier) else {
            throw EngineError.localeNotSupported(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],              // file mode: only final results
            attributeOptions: [.audioTimeRange]
        )

        try await ensureModelInstalled(for: transcriber, locale: locale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Consume results concurrently with the analysis run.
        let collector = Task { () throws -> [Utterance] in
            var utterances: [Utterance] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = result.range
                utterances.append(
                    Utterance(
                        text: text,
                        start: CMTimeGetSeconds(range.start),
                        duration: CMTimeGetSeconds(range.duration)
                    )
                )
            }
            return utterances
        }

        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }

        return try await collector.value
    }
}
