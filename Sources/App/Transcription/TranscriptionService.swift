import Foundation
import Speech
import AVFoundation

actor TranscriptionService {
    private enum TranscriptionError: Error, LocalizedError {
        case recognizerUnavailable
        case unauthorized
        case noBundleForAppleSpeech
        case chunkingFailed(String)

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognizer is not available"
            case .unauthorized:
                return
                    "Speech recognition not authorized. Please grant permission in System Settings > Privacy & Security > Speech Recognition."
            case .noBundleForAppleSpeech:
                return
                    "Apple Speech Recognition requires the packaged app. Use Parakeet instead, or install the app with: ./Scripts/package_app.sh --install"
            case .chunkingFailed(let message):
                return "Audio chunking failed: \(message)"
            }
        }
    }

    struct TimedSegment: Sendable {
        let speaker: String
        let text: String
        let timestamp: TimeInterval
        let duration: TimeInterval
        let detectedLanguage: String
    }

    /// A single word with timing information for fine-grained interleaving
    private struct TimedWord: Sendable {
        let speaker: String
        let word: String
        let timestamp: TimeInterval
        let duration: TimeInterval
        let detectedLanguage: String
    }

    private struct WordSegment: Sendable {
        let substring: String
        let timestamp: TimeInterval
        let duration: TimeInterval
        let confidence: Float
    }

    private struct TranscriptionResult: Sendable {
        let segments: [WordSegment]
        let confidence: Float
        let localeIdentifier: String
    }

    // Supported languages for auto-detection
    private let supportedLanguages = ["en-US", "de-DE"]

    /// On macOS 26+, prefer the modern SpeechAnalyzer engine over SFSpeechRecognizer
    /// (better quality, no chunking limits). Falls back automatically when a locale
    /// model is unavailable or the engine errors.
    private static let preferSpeechAnalyzer = true

    private var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    // Biasing terms (participant names, meeting title, project) applied to every recognition
    // request built during the current transcribeSession call. Set at the top of transcribeSession.
    private var contextualStrings: [String] = []

    // Audio chunking configuration
    private let chunkDuration: TimeInterval = 300 // 5 minutes per chunk

    func ensureAuthorization() async throws {
        if authorizationStatus == .authorized {
            return
        }

        // Check if we're running in a proper app bundle - without it, TCC will crash
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog(
                "TranscriptionService: Running without bundle - Apple Speech Recognition unavailable (use Parakeet or packaged app)"
            )
            throw TranscriptionError.noBundleForAppleSpeech
        }

        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        if authorizationStatus == .notDetermined {
            authorizationStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }

        guard authorizationStatus == .authorized else {
            throw TranscriptionError.unauthorized
        }
    }

    func transcribeAudio(at url: URL, localeIdentifier: String) async throws -> String {
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        return try await withCheckedThrowingContinuation { continuation in
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    task?.cancel()
                    if Self.isNoSpeechDetected(error) {
                        continuation.resume(returning: "")
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let result else {
                    task?.cancel()
                    continuation.resume(returning: "")
                    return
                }

                if result.isFinal {
                    task?.cancel()
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    /// Transcribes with a specific language and returns segments with confidence
    private func transcribeWithLanguage(at url: URL, localeIdentifier: String) async throws
        -> TranscriptionResult
    {
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        return try await withCheckedThrowingContinuation { continuation in
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    task?.cancel()
                    if Self.isNoSpeechDetected(error) {
                        continuation.resume(
                            returning: TranscriptionResult(
                                segments: [], confidence: 0, localeIdentifier: localeIdentifier))
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let result else {
                    task?.cancel()
                    continuation.resume(
                        returning: TranscriptionResult(
                            segments: [], confidence: 0, localeIdentifier: localeIdentifier))
                    return
                }

                if result.isFinal {
                    task?.cancel()
                    let sfSegments = result.bestTranscription.segments
                    // Convert to Sendable WordSegments
                    let wordSegments = sfSegments.map { seg in
                        WordSegment(
                            substring: seg.substring,
                            timestamp: seg.timestamp,
                            duration: seg.duration,
                            confidence: seg.confidence
                        )
                    }
                    // Calculate average confidence across all segments
                    let avgConfidence: Float =
                        wordSegments.isEmpty
                        ? 0
                        : wordSegments.reduce(0) { $0 + $1.confidence } / Float(wordSegments.count)
                    continuation.resume(
                        returning: TranscriptionResult(
                            segments: wordSegments,
                            confidence: avgConfidence,
                            localeIdentifier: localeIdentifier
                        ))
                }
            }
        }
    }

    /// Auto-detects language by transcribing with all supported languages and picking the best result
    private func transcribeAudioWithAutoDetect(at url: URL, speaker: String) async throws
        -> [TimedSegment]
    {
        var bestResult: TranscriptionResult?
        var lastError: Error?

        // Try each supported language
        for language in supportedLanguages {
            do {
                let result = try await transcribeWithLanguage(at: url, localeIdentifier: language)

                // Skip empty results
                guard !result.segments.isEmpty else { continue }

                NSLog(
                    "TranscriptionService: \(language) transcription confidence: \(result.confidence), segments: \(result.segments.count)"
                )

                // Keep the result with highest confidence
                if bestResult == nil || result.confidence > bestResult!.confidence {
                    bestResult = result
                }
            } catch {
                lastError = error
                NSLog(
                    "TranscriptionService: \(language) transcription failed: \(error.localizedDescription)"
                )
            }
        }

        // If we got a result, use it
        if let best = bestResult {
            NSLog(
                "TranscriptionService: Selected \(best.localeIdentifier) with confidence \(best.confidence)"
            )
            return Self.groupSegmentsIntoUtterances(
                best.segments, speaker: speaker, language: best.localeIdentifier)
        }

        // If all failed, throw the last error or return empty
        if let error = lastError {
            throw error
        }
        return []
    }

    private func transcribeAudioWithTimestamps(
        at url: URL, localeIdentifier: String, speaker: String
    ) async throws -> [TimedSegment] {
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        return try await withCheckedThrowingContinuation { continuation in
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    task?.cancel()
                    if Self.isNoSpeechDetected(error) {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let result else {
                    task?.cancel()
                    continuation.resume(returning: [])
                    return
                }

                if result.isFinal {
                    task?.cancel()
                    // Convert to WordSegments for Sendable compatibility
                    let wordSegments = result.bestTranscription.segments.map { seg in
                        WordSegment(
                            substring: seg.substring,
                            timestamp: seg.timestamp,
                            duration: seg.duration,
                            confidence: seg.confidence
                        )
                    }
                    let segments = Self.groupSegmentsIntoUtterances(
                        wordSegments,
                        speaker: speaker,
                        language: localeIdentifier
                    )
                    continuation.resume(returning: segments)
                }
            }
        }
    }

    /// Groups individual word segments into utterances based on pauses
    private static func groupSegmentsIntoUtterances(
        _ segments: [WordSegment], speaker: String, language: String = "en-US"
    ) -> [TimedSegment] {
        guard !segments.isEmpty else { return [] }

        var utterances: [TimedSegment] = []
        var currentWords: [String] = []
        var utteranceStart: TimeInterval = segments[0].timestamp
        var lastEndTime: TimeInterval = segments[0].timestamp + segments[0].duration

        let pauseThreshold: TimeInterval = 0.8  // Reduced from 1.5s for finer granularity

        for segment in segments {
            let pauseSinceLastWord = segment.timestamp - lastEndTime

            if pauseSinceLastWord > pauseThreshold && !currentWords.isEmpty {
                // End current utterance
                let text = currentWords.joined(separator: " ")
                utterances.append(
                    TimedSegment(
                        speaker: speaker,
                        text: text,
                        timestamp: utteranceStart,
                        duration: lastEndTime - utteranceStart,
                        detectedLanguage: language
                    ))
                currentWords = []
                utteranceStart = segment.timestamp
            }

            currentWords.append(segment.substring)
            lastEndTime = segment.timestamp + segment.duration
        }

        // Add final utterance
        if !currentWords.isEmpty {
            let text = currentWords.joined(separator: " ")
            utterances.append(
                TimedSegment(
                    speaker: speaker,
                    text: text,
                    timestamp: utteranceStart,
                    duration: lastEndTime - utteranceStart,
                    detectedLanguage: language
                ))
        }

        return utterances
    }

    /// Transcribes a session using the macOS 26 SpeechAnalyzer engine. The engine handles
    /// arbitrarily long files natively, so no chunking is needed. Reuses the shared
    /// interleaving/formatting so output matches the legacy recognizer.
    @available(macOS 26.0, *)
    private func transcribeSessionViaAnalyzer(
        microphoneURL: URL?,
        systemURL: URL?,
        localeIdentifier: String?,
        autoDetectLanguage: Bool,
        systemAudioOffset: TimeInterval,
        diarization: DiarizationOptions?
    ) async throws -> LabeledTranscript {
        // SpeechAnalyzer picks a single locale per file; for "auto" we use the device locale
        // and let the engine resolve to the closest supported model.
        let localeID =
            autoDetectLanguage
            ? Locale.current.identifier(.bcp47)
            : (localeIdentifier ?? "en-US")

        var micSegments: [TimedSegment] = []
        var systemSegments: [TimedSegment] = []
        var samples: [SpeakerSample] = []
        // Shared numbering so mic "Speaker 1" and system "Speaker 1" are never the same number.
        var labeler = SpeakerLabeler()

        if let url = microphoneURL {
            let utterances = try await SpeechAnalyzerEngine.transcribe(
                fileURL: url, localeIdentifier: localeID)

            // Normally the microphone is the known local speaker. For in-person meetings several
            // people share it, so it can be diarized too — but only split when more than one
            // speaker was actually found, since "You" is the better label for the solo case.
            var labels = [String](
                repeating: TranscriptFormatting.localSpeaker, count: utterances.count)
            if let diarization, diarization.includeMicrophone {
                let result = await Self.diarize(
                    with: diarization.diarizer, fileURL: url, channel: "microphone")
                if Set(result.turns.map(\.speaker)).count > 1 {
                    labels = labeler.labels(
                        forUtteranceRanges: utterances.map { (start: $0.start, duration: $0.duration) },
                        result: result, channel: "mic",
                        fallbackLabel: TranscriptFormatting.localSpeaker)
                }
            }

            micSegments = zip(utterances, labels).map { utterance, label in
                TimedSegment(
                    speaker: label, text: utterance.text, timestamp: utterance.start,
                    duration: utterance.duration, detectedLanguage: localeID)
            }
            NSLog("TranscriptionService[SpeechAnalyzer]: microphone \(micSegments.count) utterances")
        }
        samples += SpeakerSampling.samples(
            from: micSegments.map(Self.utterance(from:)), channel: .microphone,
            embeddings: labeler.embeddingByLabel)

        if let url = systemURL {
            let utterances = try await SpeechAnalyzerEngine.transcribe(
                fileURL: url, localeIdentifier: localeID)

            // The system channel mixes all remote participants. When a diarizer is available,
            // split it into "Speaker 1/2/…"; otherwise everything is the single label "Other".
            var labels = [String](repeating: "Other", count: utterances.count)
            if let diarization {
                let result = await Self.diarize(
                    with: diarization.diarizer, fileURL: url, channel: "system")
                if !result.turns.isEmpty {
                    labels = labeler.labels(
                        forUtteranceRanges: utterances.map { (start: $0.start, duration: $0.duration) },
                        result: result, channel: "system", fallbackLabel: "Other")
                }
            }

            systemSegments = zip(utterances, labels).map { utterance, label in
                TimedSegment(
                    speaker: label, text: utterance.text,
                    timestamp: utterance.start + systemAudioOffset,
                    duration: utterance.duration, detectedLanguage: localeID)
            }
            NSLog("TranscriptionService[SpeechAnalyzer]: system \(systemSegments.count) utterances")
        }
        samples += SpeakerSampling.samples(
            from: systemSegments.map(Self.utterance(from:)), channel: .system,
            embeddings: labeler.embeddingByLabel)

        return LabeledTranscript(
            text: Self.formatSegments(
                micSegments + systemSegments, autoDetectLanguage: autoDetectLanguage),
            speakers: samples)
    }

    /// Bridges this engine's internal segment type to the shared utterance type.
    private static func utterance(from segment: TimedSegment) -> TranscriptUtterance {
        TranscriptUtterance(
            speaker: segment.speaker, text: segment.text, start: segment.timestamp,
            duration: segment.duration, language: segment.detectedLanguage)
    }

    /// Diarizes one channel, returning an empty result when diarization fails — speaker labels are a
    /// nice-to-have, so a diarizer error must never lose the transcript itself.
    private static func diarize(
        with diarizer: SpeakerDiarizer, fileURL: URL, channel: String
    ) async -> DiarizationResult {
        do {
            let result = try await diarizer.diarize(fileURL: fileURL, expectedSpeakers: nil)
            NSLog(
                "TranscriptionService[SpeechAnalyzer]: \(channel) diarization — \(result.turns.count) turns"
            )
            return result
        } catch {
            NSLog(
                "TranscriptionService[SpeechAnalyzer]: \(channel) diarization failed (\(error.localizedDescription))"
            )
            return .empty
        }
    }

    func transcribeSession(
        microphoneURL: URL?,
        systemURL: URL?,
        localeIdentifier: String?,
        autoDetectLanguage: Bool = false,
        systemAudioOffset: TimeInterval = 0,
        contextualStrings: [String] = [],
        diarization: DiarizationOptions? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> LabeledTranscript {
        try await ensureAuthorization()

        self.contextualStrings = contextualStrings

        // Preferred path on macOS 26+: modern SpeechAnalyzer engine. Falls back to the
        // SFSpeechRecognizer flow below if a locale model is missing or the engine errors.
        if #available(macOS 26.0, *), Self.preferSpeechAnalyzer {
            do {
                return try await transcribeSessionViaAnalyzer(
                    microphoneURL: microphoneURL,
                    systemURL: systemURL,
                    localeIdentifier: localeIdentifier,
                    autoDetectLanguage: autoDetectLanguage,
                    systemAudioOffset: systemAudioOffset,
                    diarization: diarization
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NSLog(
                    "TranscriptionService: SpeechAnalyzer path failed (\(error.localizedDescription)) — falling back to SFSpeechRecognizer"
                )
            }
        }

        // Check if we need chunking for long audio files
        let needsChunking = try await shouldUseChunking(microphoneURL: microphoneURL, systemURL: systemURL)
        
        if needsChunking {
            return LabeledTranscript(text: try await transcribeSessionWithChunking(
                microphoneURL: microphoneURL,
                systemURL: systemURL,
                localeIdentifier: localeIdentifier,
                autoDetectLanguage: autoDetectLanguage,
                systemAudioOffset: systemAudioOffset,
                onProgress: onProgress
            ))
        }

        // Transcribe both sources with timestamps
        var micSegments: [TimedSegment] = []
        var systemSegments: [TimedSegment] = []
        var micError: Error?
        var systemError: Error?

        if let url = microphoneURL {
            do {
                NSLog(
                    "TranscriptionService: Starting microphone transcription from \(url.lastPathComponent), autoDetect: \(autoDetectLanguage)"
                )
                if autoDetectLanguage {
                    micSegments = try await transcribeAudioWithAutoDetect(at: url, speaker: "You")
                } else {
                    micSegments = try await transcribeAudioWithTimestamps(
                        at: url, localeIdentifier: localeIdentifier ?? "en-US", speaker: "You")
                }
                NSLog(
                    "TranscriptionService: Microphone transcription got \(micSegments.count) utterances"
                )
            } catch {
                NSLog(
                    "TranscriptionService: Microphone transcription failed: \(error.localizedDescription)"
                )
                if !Self.isNoSpeechDetected(error) {
                    micError = error
                }
            }
        }

        if let url = systemURL {
            do {
                NSLog(
                    "TranscriptionService: Starting system audio transcription from \(url.lastPathComponent), autoDetect: \(autoDetectLanguage)"
                )
                if autoDetectLanguage {
                    systemSegments = try await transcribeAudioWithAutoDetect(
                        at: url, speaker: "Other")
                } else {
                    systemSegments = try await transcribeAudioWithTimestamps(
                        at: url, localeIdentifier: localeIdentifier ?? "en-US", speaker: "Other")
                }
                NSLog(
                    "TranscriptionService: System audio transcription got \(systemSegments.count) utterances"
                )
            } catch {
                NSLog(
                    "TranscriptionService: System audio transcription failed: \(error.localizedDescription)"
                )
                if !Self.isNoSpeechDetected(error) {
                    systemError = error
                }
            }
        }

        // Apply offset to system audio timestamps to align with microphone timing
        // Positive offset means system started later, so we add the offset to system timestamps
        if systemAudioOffset != 0 {
            NSLog(
                "TranscriptionService: Applying offset of \(String(format: "%.3f", systemAudioOffset))s to system audio timestamps"
            )
            systemSegments = systemSegments.map { segment in
                TimedSegment(
                    speaker: segment.speaker,
                    text: segment.text,
                    timestamp: segment.timestamp + systemAudioOffset,
                    duration: segment.duration,
                    detectedLanguage: segment.detectedLanguage
                )
            }
        }

        // If we got no segments at all, throw the first real error we encountered
        if micSegments.isEmpty && systemSegments.isEmpty {
            if let error = micError ?? systemError {
                throw error
            }
            return LabeledTranscript(text: "")
        }

        // Interleave both streams chronologically and format as a labeled conversation.
        // This legacy path does not diarize, so it reports no speakers.
        return LabeledTranscript(
            text: Self.formatSegments(
                micSegments + systemSegments, autoDetectLanguage: autoDetectLanguage))
    }

    private static func isNoSpeechDetected(_ error: Error) -> Bool {
        let nsError = error as NSError
        let speechDomains: Set<String> = [
            "com.apple.SpeechRecognition.ErrorDomain",
            "kAFAssistantErrorDomain",
            "com.apple.SpeechRecognitionService",
        ]
        if speechDomains.contains(nsError.domain), nsError.code == 216 {
            return true
        }
        let lower = nsError.localizedDescription.lowercased()
        return lower.contains("no speech") || lower.contains("no audio")
    }
    
    // MARK: - Audio Chunking for Long Files
    
    /// Check if audio files are long enough to warrant chunking
    private func shouldUseChunking(microphoneURL: URL?, systemURL: URL?) async throws -> Bool {
        var micDuration: TimeInterval = 0
        if let micURL = microphoneURL {
            micDuration = try await audioDuration(for: micURL)
        }
        
        var systemDuration: TimeInterval = 0
        if let sysURL = systemURL {
            systemDuration = try await audioDuration(for: sysURL)
        }
        
        let maxDuration = max(micDuration, systemDuration)
        
        // Use chunking if any file is longer than 5 minutes
        return maxDuration > chunkDuration
    }
    
    /// Get duration of audio file using AVAsset
    private func audioDuration(for url: URL) async throws -> TimeInterval {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }
    
    /// Transcribe session with audio chunking for long files
    private func transcribeSessionWithChunking(
        microphoneURL: URL?,
        systemURL: URL?,
        localeIdentifier: String?,
        autoDetectLanguage: Bool,
        systemAudioOffset: TimeInterval,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> String {
        NSLog("TranscriptionService: Using audio chunking for long recording")
        
        var micChunks: [URL] = []
        var systemChunks: [URL] = []
        var allSegments: [TimedSegment] = []
        
        do {
            // Split audio files into chunks
            if let micURL = microphoneURL {
                NSLog("TranscriptionService: Splitting microphone audio into chunks")
                micChunks = try await splitAudioIntoChunks(url: micURL)
                NSLog("TranscriptionService: Created \(micChunks.count) microphone chunks")
            }
            
            if let sysURL = systemURL {
                NSLog("TranscriptionService: Splitting system audio into chunks")
                systemChunks = try await splitAudioIntoChunks(url: sysURL)
                NSLog("TranscriptionService: Created \(systemChunks.count) system audio chunks")
            }
            
            let totalChunks = max(micChunks.count, systemChunks.count)
            
            // Transcribe chunks sequentially
            for chunkIndex in 0..<totalChunks {
                // Check for cancellation between chunks — return partial results if available
                if Task.isCancelled {
                    NSLog("TranscriptionService: Cancelled after \(chunkIndex) of \(totalChunks) chunks")
                    // Clean up temp files before throwing
                    for chunkURL in micChunks + systemChunks {
                        try? FileManager.default.removeItem(at: chunkURL)
                    }
                    let partialText = Self.formatSegments(allSegments, autoDetectLanguage: autoDetectLanguage)
                    throw TranscriptionInterruptedError(partialText: partialText.isEmpty ? nil : partialText)
                }

                let currentChunk = chunkIndex + 1
                NSLog("TranscriptionService: Processing chunk \(currentChunk) of \(totalChunks)")

                // Notify progress
                onProgress?(currentChunk, totalChunks)
                
                var micSegments: [TimedSegment] = []
                var systemSegments: [TimedSegment] = []
                
                // Transcribe microphone chunk
                if chunkIndex < micChunks.count {
                    let chunkURL = micChunks[chunkIndex]
                    let timeOffset = TimeInterval(chunkIndex) * chunkDuration
                    
                    do {
                        if autoDetectLanguage {
                            micSegments = try await transcribeAudioWithAutoDetect(at: chunkURL, speaker: "You")
                        } else {
                            micSegments = try await transcribeAudioWithTimestamps(
                                at: chunkURL, localeIdentifier: localeIdentifier ?? "en-US", speaker: "You")
                        }
                        
                        // Adjust timestamps to account for chunk offset
                        micSegments = micSegments.map { segment in
                            TimedSegment(
                                speaker: segment.speaker,
                                text: segment.text,
                                timestamp: segment.timestamp + timeOffset,
                                duration: segment.duration,
                                detectedLanguage: segment.detectedLanguage
                            )
                        }
                    } catch {
                        if !Self.isNoSpeechDetected(error) {
                            NSLog("TranscriptionService: Mic chunk \(currentChunk) failed: \(error.localizedDescription)")
                        }
                    }
                }
                
                // Transcribe system audio chunk
                if chunkIndex < systemChunks.count {
                    let chunkURL = systemChunks[chunkIndex]
                    let timeOffset = TimeInterval(chunkIndex) * chunkDuration
                    
                    do {
                        if autoDetectLanguage {
                            systemSegments = try await transcribeAudioWithAutoDetect(at: chunkURL, speaker: "Other")
                        } else {
                            systemSegments = try await transcribeAudioWithTimestamps(
                                at: chunkURL, localeIdentifier: localeIdentifier ?? "en-US", speaker: "Other")
                        }
                        
                        // Adjust timestamps to account for chunk offset and system audio offset
                        systemSegments = systemSegments.map { segment in
                            TimedSegment(
                                speaker: segment.speaker,
                                text: segment.text,
                                timestamp: segment.timestamp + timeOffset + systemAudioOffset,
                                duration: segment.duration,
                                detectedLanguage: segment.detectedLanguage
                            )
                        }
                    } catch {
                        if !Self.isNoSpeechDetected(error) {
                            NSLog("TranscriptionService: System chunk \(currentChunk) failed: \(error.localizedDescription)")
                        }
                    }
                }
                
                allSegments.append(contentsOf: micSegments)
                allSegments.append(contentsOf: systemSegments)
            }
            
            // Clean up temporary chunk files
            for chunkURL in micChunks + systemChunks {
                try? FileManager.default.removeItem(at: chunkURL)
            }
            
            // Clean up temp directory if empty
            if let tempDir = micChunks.first?.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: tempDir)
            }
            if let tempDir = systemChunks.first?.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            return Self.formatSegments(allSegments, autoDetectLanguage: autoDetectLanguage)
            
        } catch {
            // Clean up on error
            for chunkURL in micChunks + systemChunks {
                try? FileManager.default.removeItem(at: chunkURL)
            }
            throw error
        }
    }
    
    /// Interleave and format timed segments into the final transcript string.
    /// Delegates to the shared TranscriptFormatting so this engine and the Parakeet engine
    /// produce identical output.
    private static func formatSegments(_ segments: [TimedSegment], autoDetectLanguage: Bool) -> String {
        TranscriptFormatting.assemble(
            segments.map {
                TranscriptUtterance(
                    speaker: $0.speaker, text: $0.text, start: $0.timestamp,
                    duration: $0.duration, language: $0.detectedLanguage)
            },
            showLanguage: autoDetectLanguage)
    }

    /// Split audio file into chunks of specified duration
    private func splitAudioIntoChunks(url: URL) async throws -> [URL] {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        
        // If file is short enough, no chunking needed
        if totalSeconds <= chunkDuration {
            return [url]
        }
        
        let numberOfChunks = Int(ceil(totalSeconds / chunkDuration))
        
        // Create temporary directory for chunks
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-speech-chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        var chunkURLs: [URL] = []
        
        for chunkIndex in 0..<numberOfChunks {
            let startTime = TimeInterval(chunkIndex) * chunkDuration
            let endTime = min(startTime + chunkDuration, totalSeconds)
            let chunkURL = tempDir.appendingPathComponent("chunk-\(chunkIndex).m4a")
            
            let startCMTime = CMTime(seconds: startTime, preferredTimescale: 600)
            let endCMTime = CMTime(seconds: endTime, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startCMTime, end: endCMTime)
            
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw TranscriptionError.chunkingFailed("Failed to create export session for chunk \(chunkIndex)")
            }
            
            exportSession.outputURL = chunkURL
            exportSession.outputFileType = .m4a
            exportSession.timeRange = timeRange
            
            await exportSession.export()
            
            if exportSession.status == .failed {
                let errorMsg = exportSession.error?.localizedDescription ?? "Unknown error"
                throw TranscriptionError.chunkingFailed("Export failed for chunk \(chunkIndex): \(errorMsg)")
            }
            
            chunkURLs.append(chunkURL)
        }
        
        return chunkURLs
    }
}
