// Purpose: Self-contained live dictation for the global quick-dictation hotkey — taps the
//          microphone, streams it to a recognition engine, reports partial text as you speak, and
//          returns the final text on stop.
// Dependencies: Sources/App/Audio/MicrophoneCapture.swift (mic capture), FluidAudio (Parakeet streaming),
//               Speech (SFSpeechRecognizer fallback),
//               Sources/App/Services/ParakeetTranscriptionService.swift (installed models).
// Used by: Sources/App/Supporting/QuickDictationController.swift
// Notes: Deliberately independent of the recording/session machinery — quick dictation must not
//        create a RecordingSession, write audio files, or require a project. It returns plain text
//        with no timestamps or speaker labels, because the result is pasted into another app.
//        Engine choice: Parakeet when its model is installed (same quality as file transcription),
//        otherwise Apple's SFSpeechRecognizer. Server-based recognition is allowed in the fallback —
//        forcing on-device there costs noticeably more accuracy than it gains in latency.
//        Everything touching the audio render thread lives in `nonisolated` helpers with explicitly
//        Sendable carriers; a closure formed inside this @MainActor type would inherit main-actor
//        isolation and trap when the first buffer arrives.
//        The microphone is captured through MicrophoneCapture (an input-only Core Audio unit), so
//        the microphone chosen in Settings holds even with Bluetooth headphones as the output;
//        AVAudioEngine fell back to the headphones' microphone and their call profile.
//        With the headphones' own microphone (System Default) they still switch profile when it
//        opens, which changes the device's rate; capture then restarts at once, a few times at
//        most per dictation (same recovery idea as MicRecorder), also while start() is still
//        loading the model. Words spoken before the first audio are lost, so `isMicLive` tells
//        the pill when sound really arrives and it shows "listening" only from then on.
//        Start latency: the Parakeet models are loaded once (preloaded at launch when quick
//        dictation is on) and kept in memory, instead of being read from disk on every press,
//        which made the start take a noticeable and varying while. The microphone opens before
//        the stream is ready and its audio is queued, so the first words are never lost; the
//        queue also keeps buffers in capture order (one task per buffer did not).

@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Speech

@MainActor
final class QuickDictationService {

    enum Engine: String {
        case parakeet
        case appleSpeech
    }

    enum ServiceError: Error, LocalizedError {
        case unauthorized
        case recognizerUnavailable
        case alreadyRunning
        case noBundle
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return
                    "Speech recognition is not authorized. Allow it in System Settings → Privacy & Security → Speech Recognition."
            case .recognizerUnavailable:
                return "No speech recognizer is available for this language."
            case .alreadyRunning:
                return "Dictation is already running."
            case .noBundle:
                return "Quick dictation requires the packaged app."
            case .noInputDevice:
                return "No usable microphone was found. Check your input device in System Settings → Sound."
            }
        }
    }

    // MARK: - Thread-crossing carriers

    /// Receives audio buffers on the render thread. Implemented by each engine.
    ///
    /// Exists because the tap block runs on a real-time audio thread: a closure formed inside this
    /// `@MainActor` type would inherit main-actor isolation and trap on the isolation check.
    private protocol BufferSink: Sendable {
        func append(_ buffer: AVAudioPCMBuffer)
    }

    private final class SpeechRequestSink: BufferSink, @unchecked Sendable {
        private let request: SFSpeechAudioBufferRecognitionRequest
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
        func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    }

    /// Queues captured audio for Parakeet. The queue exists from the moment the microphone
    /// opens; its reader starts once the stream is ready, so audio spoken while the model starts
    /// is kept, and buffers reach the model in the order they were captured.
    private final class ParakeetStreamSink: BufferSink, @unchecked Sendable {
        private let continuation: AsyncStream<BufferBox>.Continuation
        init(_ continuation: AsyncStream<BufferBox>.Continuation) { self.continuation = continuation }

        func append(_ buffer: AVAudioPCMBuffer) {
            // The engine hands the same buffer back for reuse, so it must be copied before being
            // handed to an async consumer — otherwise the audio is overwritten mid-flight.
            guard let copy = buffer.copyForAsyncUse() else { return }
            continuation.yield(BufferBox(copy))
        }
    }

    /// Microphone level (RMS of the latest buffer), written on the render thread and read by the
    /// pill's level timer on the main actor. Also tells when the microphone really delivers sound:
    /// a device still switching (AirPods) hands out buffers of digital zeros, so the first buffer
    /// with any energy counts as live, or a second of buffers for a mic that gates silence to zero.
    private final class LevelMeter: @unchecked Sendable {
        private static let zeroBufferGrace: UInt64 = 1_000_000_000

        private let lock = NSLock()
        private var value: Float = 0
        private var live = false
        private var firstBufferAt: UInt64?

        var level: Float {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        var isLive: Bool {
            lock.lock(); defer { lock.unlock() }
            return live
        }

        func measure(_ buffer: AVAudioPCMBuffer) {
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for index in 0..<count { sum += samples[index] * samples[index] }
            let rms = (sum / Float(count)).squareRoot()
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            value = rms
            if !live {
                let since = firstBufferAt ?? now
                firstBufferAt = since
                live = sum > 0 || now - since >= Self.zeroBufferGrace
            }
            lock.unlock()
        }

        /// Called for every new engine: after a device change the microphone is not live again
        /// until its first real sound.
        func reset() {
            lock.lock(); value = 0; live = false; firstBufferAt = nil; lock.unlock()
        }
    }

    private final class BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    /// Carries recognition results back to the main actor, for the same isolation reason.
    private final class ResultRelay: @unchecked Sendable {
        private let deliver: @MainActor (String) -> Void
        init(deliver: @escaping @MainActor (String) -> Void) { self.deliver = deliver }

        func send(_ text: String) {
            let deliver = self.deliver
            Task { @MainActor in deliver(text) }
        }
    }

    // MARK: - State

    private var engineKind: Engine = .appleSpeech
    private var capture: MicrophoneCapture?
    /// Where captured buffers go; kept so capture can restart after a device change.
    private var captureSink: (any BufferSink)?
    private var captureRestarts = 0
    private static let maxCaptureRestarts = 5
    /// Capture should be on: from beginCapture until stop or teardown, also while start() is
    /// still loading the model (a device change then must restart capture, not be dropped).
    private var wantsCapture = false

    // Apple Speech
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var relay: ResultRelay?

    // Parakeet
    private var streamManager: SlidingWindowAsrManager?
    private var updatesTask: Task<Void, Never>?
    /// Captured audio on its way to the model, and the task feeding it in.
    private var audioQueue: AsyncStream<BufferBox>.Continuation?
    private var feedTask: Task<Void, Never>?
    /// The Parakeet models, loaded once and kept (see the file header).
    private var models: AsrModels?
    private var modelsDirectory: URL?
    private var modelLoad: Task<AsrModels, Error>?

    /// Best transcript seen so far — kept because tearing a task down drops its last result.
    private var latestTranscript = ""

    private(set) var isRunning = false

    private let meter = LevelMeter()

    /// Current microphone level while the microphone is open (RMS, 0 otherwise), already while
    /// the engine starts. Drives the pill's waveform.
    var currentLevel: Float { capture != nil ? meter.level : 0 }

    /// True once the open microphone delivers real sound. Before that, words spoken are lost
    /// (AirPods take about a second to switch), so the pill only says it listens from here on.
    var isMicLive: Bool { capture != nil && meter.isLive }

    /// Called on the main actor with the transcript as it grows.
    var onPartialText: ((String) -> Void)?

    /// Which engine the last/current run uses, for logging and UI.
    var activeEngine: Engine { engineKind }

    // MARK: - Lifecycle

    /// Starts dictation. `parakeet` provides the installed Parakeet models when available;
    /// pass nil to force the Apple Speech fallback.
    func start(localeIdentifier: String, parakeet: ParakeetTranscriptionService?) async throws {
        guard !isRunning else { throw ServiceError.alreadyRunning }
        guard Bundle.main.bundleIdentifier != nil else { throw ServiceError.noBundle }

        latestTranscript = ""

        if let parakeet, parakeet.isModelInstalled {
            do {
                try await startParakeet(parakeet: parakeet)
                engineKind = .parakeet
                isRunning = true
                NSLog("QuickDictationService: started (Parakeet streaming)")
                return
            } catch {
                NSLog(
                    "QuickDictationService: Parakeet start failed (%@) — falling back to Apple Speech",
                    error.localizedDescription)
                await teardown()
            }
        }

        try await startAppleSpeech(localeIdentifier: localeIdentifier)
        engineKind = .appleSpeech
        isRunning = true
        NSLog("QuickDictationService: started (Apple Speech, \(localeIdentifier))")
    }

    /// Stops capture and returns the dictated text, trimmed. Empty when nothing was recognized.
    @discardableResult
    func stop() async -> String {
        guard isRunning else { return "" }
        isRunning = false
        wantsCapture = false

        detachCapture()

        var finalText = latestTranscript

        switch engineKind {
        case .parakeet:
            // Everything captured goes in before the stream is finished.
            audioQueue?.finish()
            audioQueue = nil
            await feedTask?.value
            feedTask = nil
            if let streamManager {
                // finish() drains the remaining window and returns the complete transcript.
                if let complete = try? await streamManager.finish(), !complete.isEmpty {
                    finalText = complete
                }
                await streamManager.cleanup()
            }
        case .appleSpeech:
            // Let the recognizer flush what it already has before tearing the task down.
            request?.endAudio()
            try? await Task.sleep(for: .milliseconds(350))
            finalText = latestTranscript
        }

        await teardown()

        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("QuickDictationService: stopped (\(engineKind.rawValue)), \(text.count) characters")
        return text
    }

    private func teardown() async {
        wantsCapture = false
        updatesTask?.cancel()
        updatesTask = nil
        audioQueue?.finish()
        audioQueue = nil
        feedTask?.cancel()
        feedTask = nil
        streamManager = nil

        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        relay = nil

        detachCapture()
        captureSink = nil
    }

    // MARK: - Parakeet backend

    /// Loads the Parakeet models in the background so the first dictation starts at once.
    func prewarm(parakeet: ParakeetTranscriptionService) {
        guard parakeet.isModelInstalled else { return }
        Task {
            do {
                _ = try await loadedModels(parakeet)
                NSLog("QuickDictationService: Parakeet models preloaded")
            } catch {
                NSLog("QuickDictationService: Parakeet preload failed (%@)", error.localizedDescription)
            }
        }
    }

    /// The installed models, read from disk only the first time (or after a reinstall elsewhere).
    private func loadedModels(_ parakeet: ParakeetTranscriptionService) async throws -> AsrModels {
        let directory = parakeet.installedModelDirectory
        if let models, modelsDirectory == directory { return models }
        if let modelLoad, modelsDirectory == directory { return try await modelLoad.value }
        modelsDirectory = directory
        let load = Task { try await parakeet.loadInstalledModels() }
        modelLoad = load
        do {
            let loaded = try await load.value
            if modelsDirectory == directory { models = loaded }
            modelLoad = nil
            return loaded
        } catch {
            modelLoad = nil
            modelsDirectory = nil
            throw error
        }
    }

    private func startParakeet(parakeet: ParakeetTranscriptionService) async throws {
        // The microphone opens first: whatever is said while the stream starts is queued.
        let (queue, continuation) = AsyncStream<BufferBox>.makeStream(bufferingPolicy: .unbounded)
        audioQueue = continuation
        try beginCapture(into: ParakeetStreamSink(continuation))

        let models = try await loadedModels(parakeet)
        let manager = SlidingWindowAsrManager()
        try await manager.loadModels(models)
        try await manager.startStreaming()
        streamManager = manager

        // Mirror live updates into the HUD.
        let relay = ResultRelay { [weak self] text in
            self?.latestTranscript = text
            self?.onPartialText?(text)
        }
        self.relay = relay

        updatesTask = Task {
            var confirmed = ""
            for await update in await manager.transcriptionUpdates {
                if update.isConfirmed {
                    confirmed += update.text
                    relay.send(confirmed)
                } else {
                    relay.send(confirmed + update.text)
                }
            }
        }

        feedTask = Task {
            for await box in queue {
                await manager.streamAudio(box.buffer)
            }
        }
    }

    // MARK: - Apple Speech backend

    private func startAppleSpeech(localeIdentifier: String) async throws {
        try await Self.ensureAuthorized()

        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw ServiceError.recognizerUnavailable
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Intentionally NOT forcing on-device: the on-device model is markedly less accurate, and
        // this path is already the fallback.
        self.request = request

        let relay = ResultRelay { [weak self] text in
            self?.latestTranscript = text
            self?.onPartialText?(text)
        }
        self.relay = relay

        try beginCapture(into: SpeechRequestSink(request))
        task = Self.makeRecognitionTask(recognizer: recognizer, request: request, relay: relay)
    }

    /// Creates the recognition task. `nonisolated` for the same reason as `startCapture`.
    nonisolated private static func makeRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        relay: ResultRelay
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                relay.send(result.bestTranscription.formattedString)
            }
            if let error {
                // Usually "no speech detected" when stopping on silence — the transcript collected
                // so far is still valid, so this is logged rather than surfaced.
                NSLog("QuickDictationService: recognition ended (\(error.localizedDescription))")
            }
        }
    }

    // MARK: - Microphone

    private func beginCapture(into sink: any BufferSink) throws {
        captureSink = sink
        captureRestarts = 0
        wantsCapture = true
        try attachCapture()
    }

    /// Starts a fresh capture for `captureSink` and restarts it when its device moves, goes
    /// away or changes its rate underneath it (see the file header).
    private func attachCapture() throws {
        guard let captureSink else { return }
        let capture = try Self.startCapture(into: captureSink, meter: meter)
        self.capture = capture
        let captureID = ObjectIdentifier(capture)
        capture.onConfigurationChange = { [weak self, weak capture] in
            guard let capture, MicrophoneCapture.target() != capture.deviceID || !capture.isCurrent else { return }
            Task { @MainActor in await self?.restartCapture(captureID: captureID) }
        }
    }

    private func detachCapture() {
        capture?.stop()
        capture = nil
    }

    private func restartCapture(captureID: ObjectIdentifier) async {
        guard let capture, ObjectIdentifier(capture) == captureID else { return }
        detachCapture()
        guard captureRestarts < Self.maxCaptureRestarts else {
            NSLog("QuickDictationService: audio configuration keeps changing, capture not restarted")
            return
        }
        // Restart at once: the change arrives when the switch is done. A device not ready yet
        // gets a few quick retries.
        while captureRestarts < Self.maxCaptureRestarts {
            captureRestarts += 1
            // Stopped, or a new dictation started, meanwhile.
            guard wantsCapture, self.capture == nil, captureSink != nil else { return }
            do {
                try attachCapture()
                NSLog("QuickDictationService: audio configuration changed, capture restarted")
                return
            } catch {
                NSLog("QuickDictationService: capture restart failed (\(error.localizedDescription)), retrying")
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Opens the microphone (the one chosen in Settings, else the default input) and streams
    /// buffers into `sink`.
    ///
    /// `nonisolated` on purpose: see `BufferSink`.
    nonisolated private static func startCapture(into sink: any BufferSink, meter: LevelMeter) throws -> MicrophoneCapture {
        meter.reset()
        do {
            return try MicrophoneCapture(deviceID: nil, queue: captureQueue) { buffer in
                meter.measure(buffer)
                sink.append(buffer)
            }
        } catch MicrophoneCapture.CaptureError.noInputDevice {
            throw ServiceError.noInputDevice
        }
    }

    /// Where captured buffers arrive, off the main actor and the render thread.
    nonisolated private static let captureQueue = DispatchQueue(label: "QuickDictationCapture")

    // MARK: - Authorization

    private static func ensureAuthorized() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            guard await SpeechAuthorization.request() == .authorized else { throw ServiceError.unauthorized }
        default:
            throw ServiceError.unauthorized
        }
    }
}

extension AVAudioPCMBuffer {
    /// An independent copy, safe to hand to an async consumer. AVAudioEngine reuses tap buffers, so
    /// the original may be overwritten before the consumer reads it.
    fileprivate func copyForAsyncUse() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength

        let channels = Int(format.channelCount)
        if let source = floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: Int(frameLength))
            }
            return copy
        }
        if let source = int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: Int(frameLength))
            }
            return copy
        }
        return nil
    }
}
