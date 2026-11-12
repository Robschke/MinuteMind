// Purpose: Cleans audio before transcription to improve accuracy on quiet/noisy recordings —
//          a high-pass filter (removes low-frequency rumble/hum), peak normalization (lifts quiet
//          recordings to a consistent level), and a gentle noise gate (attenuates, never mutes,
//          low-level background between speech). Output length is unchanged, so timestamps and the
//          system-audio offset stay valid.
// Dependencies: AVFoundation (AVAudioFile streaming I/O).
// Used by: Sources/App/ViewModels/AppViewModel.swift (transcribe /
//          transcribeWithParakeet) via preprocessedAudioURL(...).
// Notes: Streams in chunks (memory is O(chunk), not O(file)) so multi-hour recordings are safe.
//        Two passes: pass 1 measures the post-filter peak, pass 2 applies filter+gain+gate and
//        writes a temp 16-bit WAV. The gate floor is -6 dB (0.5) so speech onsets are never cut.
//        CPU work runs off the main actor on a utility queue.

import AVFoundation

enum AudioPreprocessor {

    private static let queue = DispatchQueue(label: "AudioPreprocessor.dsp", qos: .userInitiated)

    // Tunables (all relative to normalized full-scale 1.0).
    private static let highPassCutoffHz: Double = 80
    private static let targetPeak: Float = 0.97
    private static let maxGain: Float = 8.0        // don't blow up near-silent recordings into noise
    private static let gateOpenThreshold: Float = 0.06
    private static let gateCloseThreshold: Float = 0.02
    private static let gateFloorGain: Float = 0.5  // -6 dB: gentle, never fully mutes
    private static let chunkFrames: AVAudioFrameCount = 65_536

    /// Produces a cleaned copy of `sourceURL` at a temporary WAV path. Returns nil on any
    /// failure so the caller can fall back to the original audio.
    static func process(url sourceURL: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let out = try processSync(sourceURL: sourceURL)
                    continuation.resume(returning: out)
                } catch {
                    NSLog("AudioPreprocessor: skipped (\(error.localizedDescription)) — using original audio")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func processSync(sourceURL: URL) throws -> URL {
        // ---- Pass 1: measure the peak of the high-passed signal ----
        let peak = try measurePeak(sourceURL: sourceURL)
        guard peak > 1e-5 else {
            throw NSError(domain: "AudioPreprocessor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "audio is effectively silent"])
        }
        let gain = min(targetPeak / peak, maxGain)

        // ---- Pass 2: apply filter + gain + gate, write output ----
        let inFile = try AVAudioFile(forReading: sourceURL)
        let format = inFile.processingFormat
        let channelCount = Int(format.channelCount)
        let sampleRate = format.sampleRate

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-preproc-\(UUID().uuidString).wav")
        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: outSettings)

        // Per-channel filter + gate state.
        let hp = HighPass(cutoffHz: highPassCutoffHz, sampleRate: sampleRate)
        var filterState = [FilterState](repeating: FilterState(), count: channelCount)
        var gateState = [GateState](repeating: GateState(), count: channelCount)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw NSError(domain: "AudioPreprocessor", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }

        while true {
            try inFile.read(into: buffer)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { break }

            for ch in 0..<channelCount {
                let samples = channels[ch]
                for i in 0..<n {
                    let filtered = hp.step(samples[i], state: &filterState[ch])
                    let amplified = filtered * gain
                    let g = gateState[ch].gain(for: amplified)
                    samples[i] = amplified * g
                }
            }
            try outFile.write(from: buffer)
        }

        return outURL
    }

    private static func measurePeak(sourceURL: URL) throws -> Float {
        let inFile = try AVAudioFile(forReading: sourceURL)
        let format = inFile.processingFormat
        let channelCount = Int(format.channelCount)
        let hp = HighPass(cutoffHz: highPassCutoffHz, sampleRate: format.sampleRate)
        var filterState = [FilterState](repeating: FilterState(), count: channelCount)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw NSError(domain: "AudioPreprocessor", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }

        var peak: Float = 0
        while true {
            try inFile.read(into: buffer)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            for ch in 0..<channelCount {
                let samples = channels[ch]
                for i in 0..<n {
                    let filtered = abs(hp.step(samples[i], state: &filterState[ch]))
                    if filtered > peak { peak = filtered }
                }
            }
        }
        return peak
    }

    // MARK: - DSP primitives

    /// First-order high-pass (DC/rumble blocker): y[n] = a*(y[n-1] + x[n] - x[n-1]).
    private struct HighPass {
        let a: Float
        init(cutoffHz: Double, sampleRate: Double) {
            let rc = 1.0 / (2.0 * Double.pi * cutoffHz)
            let dt = 1.0 / sampleRate
            self.a = Float(rc / (rc + dt))
        }
        func step(_ x: Float, state: inout FilterState) -> Float {
            let y = a * (state.prevY + x - state.prevX)
            state.prevX = x
            state.prevY = y
            return y
        }
    }

    private struct FilterState {
        var prevX: Float = 0
        var prevY: Float = 0
    }

    /// Envelope-following soft noise gate. Attenuates low-level content toward a -6 dB floor,
    /// with smoothed gain to avoid zipper artifacts. Never fully mutes.
    private struct GateState {
        var envelope: Float = 0
        var appliedGain: Float = 1

        mutating func gain(for sample: Float) -> Float {
            let mag = abs(sample)
            // Fast attack, slow release envelope.
            envelope = mag > envelope ? mag : (envelope * 0.9995 + mag * 0.0005)

            let target: Float
            if envelope >= gateOpenThreshold {
                target = 1
            } else if envelope <= gateCloseThreshold {
                target = gateFloorGain
            } else {
                let t = (envelope - gateCloseThreshold) / (gateOpenThreshold - gateCloseThreshold)
                target = gateFloorGain + t * (1 - gateFloorGain)
            }
            // Smooth the applied gain to prevent zipper noise.
            appliedGain = appliedGain * 0.99 + target * 0.01
            return appliedGain
        }
    }
}
