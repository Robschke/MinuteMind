// Purpose: MicRecorder, records the microphone side of a meeting into a .caf file, keeps the
//          current level for silence detection, and keeps recording across device changes.
// Dependencies: Sources/App/Audio/MicrophoneCapture.swift (input-only capture of one device),
//               Sources/App/Audio/MicrophonePreference.swift (the chosen microphone)
// Used by: Sources/App/ViewModels/AppViewModel.swift (startRecording, switchInputDevice)
// Notes: Capture runs through MicrophoneCapture rather than AVAudioEngine, whose I/O unit falls
//        back to the default input/output pair when it starts and so ignored the chosen
//        microphone while Bluetooth headphones were the output (see MicrophoneCapture).
//        The file keeps the format of the device it started on; buffers from a device with
//        another rate after a change are converted, so the file stays one readable stream.
//        A device change restarts capture only when the target (chosen microphone if
//        connected, else the default input) moved, died or changed its rate; other device
//        list changes leave the running capture alone.

import Accelerate
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

final class MicRecorder: @unchecked Sendable {
    private var capture: MicrophoneCapture?
    private var audioFile: AVAudioFile?
    private var currentURL: URL?
    private let queue = DispatchQueue(label: "MicRecorderQueue")
    /// Converts buffers from a device whose rate differs from the file's (after a device change).
    private var converter: AVAudioConverter?
    /// Latest RMS audio level from the mic; 0.0 when not recording.
    private var _currentLevel: Float = 0
    /// Consecutive write error counter; stops logging after a threshold to avoid log spam.
    private var consecutiveWriteErrors: Int = 0
    /// Callback fired on the first write error so callers can surface it to the user.
    var onWriteError: ((Error) -> Void)?
    /// Callback fired when recording continues on another microphone after a device change.
    var onDeviceRecovery: ((String) -> Void)?
    /// Watchdog: last known audio file size, checked periodically.
    private var lastKnownFileSize: UInt64 = 0
    /// Watchdog: consecutive stall checks with no growth.
    private var stallCheckCount: Int = 0
    /// Callback when the watchdog detects the file has stopped growing.
    var onFileStall: (() -> Void)?
    /// Watchdog timer (fires every 15 seconds).
    private var watchdogTimer: DispatchSourceTimer?

    var isRecording: Bool {
        queue.sync { capture != nil }
    }

    /// Latest RMS audio level (0.0–1.0). Used by AutomationCoordinator for silence detection.
    var currentLevel: Float {
        queue.sync { _currentLevel }
    }

    func startRecording(to url: URL, deviceID: AudioDeviceID? = nil) throws {
        try queue.sync {
            stopUnsafe()
            let capture = try openCapture(deviceID)
            // A new file in the device's format.
            audioFile = try AVAudioFile(forWriting: url, settings: capture.format.settings)
            currentURL = url
            self.capture = capture
            NSLog("MicRecorder: Started recording to \(url.lastPathComponent) at \(capture.format.sampleRate)Hz on \(Self.deviceName(capture.deviceID) ?? "device \(capture.deviceID)")")
            startWatchdog(url: url)
        }
    }

    func stopRecording() {
        queue.sync {
            stopUnsafe()
        }
    }

    func switchInputDevice(_ deviceID: AudioDeviceID) throws {
        try queue.sync {
            guard currentURL != nil, let old = capture else { return }
            NSLog("MicRecorder: Switching input device to \(deviceID)")
            old.stop()
            capture = nil
            capture = try openCapture(deviceID)
        }
    }

    /// Starts capture from `deviceID` (nil: the chosen microphone, else the default input),
    /// writing into the open file. Runs on `queue`.
    private func openCapture(_ deviceID: AudioDeviceID?) throws -> MicrophoneCapture {
        let capture = try MicrophoneCapture(deviceID: deviceID, queue: queue) { [weak self] buffer in
            self?.write(buffer)
        }
        capture.onConfigurationChange = { [weak self] in self?.handleConfigurationChange() }
        converter = nil
        return capture
    }

    /// Writes one buffer (on `queue`) and updates the level.
    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file = audioFile else { return }
        var writeError: Error?
        do {
            try file.write(from: try fileBuffer(buffer, for: file))
        } catch {
            writeError = error
        }

        var rms: Float = 0
        if let channelData = buffer.floatChannelData {
            var meanSquare: Float = 0
            vDSP_measqv(channelData[0], 1, &meanSquare, vDSP_Length(buffer.frameLength))
            rms = sqrtf(meanSquare)
        }
        _currentLevel = rms

        if let writeError {
            consecutiveWriteErrors += 1
            if consecutiveWriteErrors <= 3 {
                NSLog("MicRecorder write error (\(consecutiveWriteErrors)): \(writeError.localizedDescription)")
            }
            if consecutiveWriteErrors == 1 { onWriteError?(writeError) }
        } else {
            consecutiveWriteErrors = 0
        }
    }

    /// The buffer in the file's format: as is when they match, else converted.
    private func fileBuffer(_ buffer: AVAudioPCMBuffer, for file: AVAudioFile) throws -> AVAudioPCMBuffer {
        let target = file.processingFormat
        guard buffer.format != target else { return buffer }
        if converter?.inputFormat != buffer.format || converter?.outputFormat != target {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else {
            throw NSError(domain: "MicRecorder", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "The new microphone's audio format cannot be converted"])
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(domain: "MicRecorder", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "No memory for the converted audio"])
        }
        nonisolated(unsafe) var consumed = false  // convert(to:) calls the block synchronously
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return output
    }

    private func stopUnsafe() {
        if capture != nil {
            NSLog("MicRecorder: Stopping recording")
        }
        stopWatchdog()
        capture?.stop()
        capture = nil
        converter = nil
        audioFile = nil
        currentURL = nil
        _currentLevel = 0
        consecutiveWriteErrors = 0
        stallCheckCount = 0
        lastKnownFileSize = 0
    }

    // MARK: - Device changes

    /// Restarts capture when the target microphone moved, disappeared or changed its rate
    /// (Bluetooth profile switch); otherwise the running capture keeps going. Runs on `queue`.
    private func handleConfigurationChange() {
        guard currentURL != nil, let running = capture else { return }
        let target = MicrophoneCapture.target()
        if target == running.deviceID, running.isCurrent { return }

        NSLog("MicRecorder: Audio configuration changed, restarting capture")
        running.stop()
        capture = nil
        do {
            let restarted = try openCapture(target)
            capture = restarted
            if restarted.deviceID != running.deviceID {
                let name = Self.deviceName(restarted.deviceID) ?? "another microphone"
                onDeviceRecovery?("Recording continues with \(name)")
            }
            NSLog("MicRecorder: Recording continues at \(restarted.format.sampleRate)Hz on device \(restarted.deviceID)")
        } catch {
            NSLog("MicRecorder: Restart failed: \(error.localizedDescription)")
            onWriteError?(NSError(domain: "MicRecorder", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Microphone disconnected and no replacement found"]))
        }
    }

    // MARK: - Watchdog (file-growth monitor)

    /// Starts a low-overhead timer that checks whether the audio file is still growing.
    /// Fires every 15 seconds. If the file hasn't grown for 3 consecutive checks (45 s),
    /// the `onFileStall` callback fires. Cost: one GCD timer, one stat() call per tick.
    private func startWatchdog(url: URL) {
        stopWatchdog()
        lastKnownFileSize = fileSize(at: url)
        stallCheckCount = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, self.capture != nil else { return }
            let currentSize = self.fileSize(at: url)
            if currentSize <= self.lastKnownFileSize {
                self.stallCheckCount += 1
                if self.stallCheckCount >= 3 {
                    NSLog("MicRecorder: Watchdog — file hasn't grown for \(self.stallCheckCount * 15)s")
                    self.onFileStall?()
                    self.stallCheckCount = 0 // Reset so it doesn't fire every 15 s
                }
            } else {
                self.stallCheckCount = 0
                self.lastKnownFileSize = currentSize
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func fileSize(at url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    // MARK: - Input Device

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let name = value?.takeRetainedValue() else { return nil }
        return name as String
    }
}
