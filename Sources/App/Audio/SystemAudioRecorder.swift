import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

final class SystemAudioRecorder: NSObject {
    private let sampleQueue = DispatchQueue(label: "SystemAudioRecorderSampleQueue")
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var hasStartedSession = false
    /// Fired when the ScreenCaptureKit stream drops or the asset writer enters a failed state.
    var onStreamError: ((Error) -> Void)?
    /// True once a writer failure has been reported for the current recording (avoids repeat callbacks).
    private var hasReportedWriterFailure = false
    /// Latest RMS level of the captured system audio (the other participants), 0 when idle.
    /// Written on the sample queue, read from the main actor, hence the lock.
    private var levelLock = os_unfair_lock()
    private var _currentLevel: Float = 0

    /// RMS level (0 to 1) of what the other side is saying. Used with the mic level for silence
    /// detection, so listening quietly is not mistaken for the meeting being over.
    var currentLevel: Float {
        os_unfair_lock_lock(&levelLock)
        defer { os_unfair_lock_unlock(&levelLock) }
        return _currentLevel
    }

    private func setLevel(_ value: Float) {
        os_unfair_lock_lock(&levelLock)
        _currentLevel = value
        os_unfair_lock_unlock(&levelLock)
    }

    @MainActor
    func startRecording(to url: URL) async throws {
        await stopRecording()

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(
                domain: "SystemAudioRecorder", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No active display to capture"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 16_000  // 16kHz works best with SFSpeechRecognizer
        configuration.channelCount = 1  // Mono for speech recognition

        let writer = try AVAssetWriter(outputURL: url, fileType: .caf)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: configuration.sampleRate,
            AVNumberOfChannelsKey: configuration.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        writerInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(writerInput) else {
            throw NSError(
                domain: "SystemAudioRecorder", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to add audio input to writer"])
        }
        writer.add(writerInput)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        assetWriter = writer
        assetWriterInput = writerInput
        self.stream = stream
        hasStartedSession = false
        hasReportedWriterFailure = false

        try await stream.startCapture()
    }

    @MainActor
    func stopRecording() async {
        setLevel(0)
        guard stream != nil || assetWriter != nil else { return }

        if let stream {
            try? stream.removeStreamOutput(self, type: .audio)
            try? await stream.stopCapture()
        }
        stream = nil

        guard let writer = assetWriter else {
            assetWriterInput = nil
            hasStartedSession = false
            assetWriter = nil
            return
        }

        assetWriterInput?.markAsFinished()
        assetWriterInput = nil
        hasStartedSession = false
        assetWriter = nil

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                if let error = writer.error {
                    NSLog("SystemAudioRecorder: finishWriting failed — \(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }
}

extension SystemAudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SystemAudioRecorder: stream stopped with error — \(error.localizedDescription)")
        onStreamError?(error)
    }
}

extension SystemAudioRecorder {
    /// RMS of the first channel; ScreenCaptureKit delivers Float32 PCM.
    fileprivate static func rms(of sampleBuffer: CMSampleBuffer) -> Float {
        var result: Float = 0
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let buffer = list.first, let data = buffer.mData else { return }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return }
            let samples = data.bindMemory(to: Float.self, capacity: count)
            var sum: Float = 0
            for index in 0..<count { sum += samples[index] * samples[index] }
            result = (sum / Float(count)).squareRoot()
        }
        return result
    }
}

extension SystemAudioRecorder: SCStreamOutput {
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
            let writer = assetWriter,
            let input = assetWriterInput
        else {
            return
        }
        setLevel(Self.rms(of: sampleBuffer))

        switch writer.status {
        case .unknown:
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            hasStartedSession = true
            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        case .writing:
            if !hasStartedSession {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                hasStartedSession = true
            }
            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        case .failed:
            if !hasReportedWriterFailure {
                hasReportedWriterFailure = true
                let error = writer.error ?? NSError(
                    domain: "SystemAudioRecorder", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Asset writer entered failed state"])
                NSLog("SystemAudioRecorder: Writer failed — \(error.localizedDescription)")
                onStreamError?(error)
            }
        default:
            break
        }
    }
}
