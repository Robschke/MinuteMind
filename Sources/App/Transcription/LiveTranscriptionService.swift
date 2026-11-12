import AVFoundation
import Foundation
import Speech

/// Wrapper for non-Sendable SFSpeechAudioBufferRecognitionRequest
struct SendableRecognitionRequest: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
}

/// Service that performs real-time transcription of two audio streams simultaneously
/// using Apple's Speech Recognition framework.
actor LiveTranscriptionService {

    // MARK: - Types

    struct TranscriptUpdate: Sendable {
        let speaker: String  // "You" or "Other"
        let text: String
        let timestamp: TimeInterval
        let isFinal: Bool
    }

    enum ServiceError: Error, LocalizedError {
        case recognizerUnavailable
        case unauthorized
        case noBundleForAppleSpeech
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognizer is not available"
            case .unauthorized:
                return "Speech recognition not authorized"
            case .noBundleForAppleSpeech:
                return "Apple Speech Recognition requires the packaged app"
            case .alreadyRunning:
                return "Live transcription is already running"
            }
        }
    }

    // MARK: - Properties

    private var micRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var systemRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var micRecognitionTask: SFSpeechRecognitionTask?
    private var systemRecognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    private var isRunning = false
    private var startTime: Date?

    // Accumulated transcript segments
    private var micSegments: [(timestamp: TimeInterval, text: String)] = []
    private var systemSegments: [(timestamp: TimeInterval, text: String)] = []
    private var lastMicText: String = ""
    private var lastSystemText: String = ""

    // Callback for transcript updates
    private var onUpdate: (@Sendable (TranscriptUpdate) -> Void)?

    // MARK: - Public Interface

    /// Start live transcription for both audio sources
    /// - Parameters:
    ///   - localeIdentifier: Language locale (e.g., "en-US", "de-DE")
    ///   - onUpdate: Callback invoked with transcript updates
    /// - Returns: A tuple containing the microphone and system audio recognition requests
    func start(localeIdentifier: String, onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void)
        async throws -> (SendableRecognitionRequest, SendableRecognitionRequest)
    {
        guard !isRunning else {
            throw ServiceError.alreadyRunning
        }

        // Check bundle
        guard Bundle.main.bundleIdentifier != nil else {
            throw ServiceError.noBundleForAppleSpeech
        }

        // Check authorization
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus == .authorized)
                }
            }
            guard granted else {
                throw ServiceError.unauthorized
            }
        } else if status != .authorized {
            throw ServiceError.unauthorized
        }

        // Create recognizer
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw ServiceError.recognizerUnavailable
        }

        self.speechRecognizer = recognizer
        self.onUpdate = onUpdate
        self.startTime = Date()
        self.isRunning = true
        self.micSegments = []
        self.systemSegments = []
        self.lastMicText = ""
        self.lastSystemText = ""

        // Create recognition requests for both sources
        micRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        systemRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        micRecognitionRequest?.shouldReportPartialResults = true
        systemRecognitionRequest?.shouldReportPartialResults = true
        
        NSLog("LiveTranscriptionService: Created recognition requests, setting up tasks")

        // Start mic recognition task
        if let request = micRecognitionRequest {
            NSLog("LiveTranscriptionService: Starting mic recognition task")
            micRecognitionTask = recognizer.recognitionTask(with: request) {
                [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let hasError = error != nil
                let errorDesc = error?.localizedDescription
                
                NSLog("LiveTranscriptionService: Mic result received - text: \(text?.prefix(30) ?? "nil"), isFinal: \(isFinal), error: \(errorDesc ?? "none")")

                Task.detached { [weak self] in
                    await self?.handleMicResult(
                        text: text,
                        isFinal: isFinal,
                        hasError: hasError,
                        errorDesc: errorDesc
                    )
                }
            }
        }

        // Start system recognition task
        if let request = systemRecognitionRequest {
            NSLog("LiveTranscriptionService: Starting system recognition task")
            systemRecognitionTask = recognizer.recognitionTask(with: request) {
                [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let hasError = error != nil
                let errorDesc = error?.localizedDescription
                
                NSLog("LiveTranscriptionService: System result received - text: \(text?.prefix(30) ?? "nil"), isFinal: \(isFinal), error: \(errorDesc ?? "none")")

                Task.detached { [weak self] in
                    await self?.handleSystemResult(
                        text: text,
                        isFinal: isFinal,
                        hasError: hasError,
                        errorDesc: errorDesc
                    )
                }
            }
        }

        NSLog("LiveTranscriptionService: Started with locale \(localeIdentifier)")

        return (
            SendableRecognitionRequest(request: micRecognitionRequest!),
            SendableRecognitionRequest(request: systemRecognitionRequest!)
        )
    }

    /// Stop live transcription and return the final combined transcript
    func stop() async -> String {
        guard isRunning else { return "" }

        isRunning = false

        // End the recognition requests
        micRecognitionRequest?.endAudio()
        systemRecognitionRequest?.endAudio()

        // Cancel tasks
        micRecognitionTask?.cancel()
        systemRecognitionTask?.cancel()

        // Clean up
        micRecognitionRequest = nil
        systemRecognitionRequest = nil
        micRecognitionTask = nil
        systemRecognitionTask = nil

        // Build final transcript
        let finalTranscript = buildFinalTranscript()

        NSLog("LiveTranscriptionService: Stopped. Generated \(finalTranscript.count) characters")

        return finalTranscript
    }

    /// Check if live transcription is currently running
    var running: Bool {
        isRunning
    }

    // MARK: - Private Methods

    private func handleMicResult(
        text: String?,
        isFinal: Bool,
        hasError: Bool,
        errorDesc: String?
    ) {
        NSLog("LiveTranscriptionService: handleMicResult called, isRunning=\(isRunning)")
        guard isRunning else { return }

        if hasError {
            if let desc = errorDesc, !desc.contains("216") {
                NSLog("LiveTranscriptionService: Mic recognition error: \(desc)")
            }
            return
        }

        guard let text = text else { return }

        // Only emit if text changed
        if text != lastMicText {
            let elapsed = Date().timeIntervalSince(startTime ?? Date())
            lastMicText = text
            NSLog("LiveTranscriptionService: Mic text changed, calling onUpdate callback")

            // Store for final transcript
            if isFinal {
                micSegments.append((timestamp: elapsed, text: text))
            }

            let update = TranscriptUpdate(
                speaker: "You",
                text: text,
                timestamp: elapsed,
                isFinal: isFinal
            )

            onUpdate?(update)
            NSLog("LiveTranscriptionService: onUpdate called for mic")
        }
    }

    private func handleSystemResult(
        text: String?,
        isFinal: Bool,
        hasError: Bool,
        errorDesc: String?
    ) {
        guard isRunning else { return }

        if hasError {
            if let desc = errorDesc, !desc.contains("216") {
                NSLog("LiveTranscriptionService: System recognition error: \(desc)")
            }
            return
        }

        guard let text = text else { return }

        // Only emit if text changed
        if text != lastSystemText {
            let elapsed = Date().timeIntervalSince(startTime ?? Date())
            lastSystemText = text

            // Store for final transcript
            if isFinal {
                systemSegments.append((timestamp: elapsed, text: text))
            }

            let update = TranscriptUpdate(
                speaker: "Other",
                text: text,
                timestamp: elapsed,
                isFinal: isFinal
            )

            onUpdate?(update)
        }
    }

    private func buildFinalTranscript() -> String {
        // Combine mic and system segments, sorted by timestamp
        var allSegments: [(timestamp: TimeInterval, speaker: String, text: String)] = []

        // Use the last accumulated text if we have partial results
        if !lastMicText.isEmpty {
            allSegments.append((timestamp: 0, speaker: "You", text: lastMicText))
        }

        if !lastSystemText.isEmpty {
            allSegments.append((timestamp: 0, speaker: "Other", text: lastSystemText))
        }

        // If no segments, just return what we have
        if allSegments.isEmpty {
            return ""
        }

        // Format as conversation
        let formatted = allSegments.map { segment -> String in
            let minutes = Int(segment.timestamp) / 60
            let seconds = Int(segment.timestamp) % 60
            return
                "[\(String(format: "%02d:%02d", minutes, seconds))] \(segment.speaker): \(segment.text)"
        }

        return formatted.joined(separator: "\n\n")
    }
}
