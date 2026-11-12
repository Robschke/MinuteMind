// Purpose: MicrophoneCapture, records from exactly one input device through an input-only Core
//          Audio unit (AUHAL) and hands out mono Float32 buffers, and reports when the device
//          setup changes so its owner can restart it.
// Dependencies: AudioToolbox / CoreAudio (AUHAL, property listeners), AVFoundation (AVAudioPCMBuffer)
// Used by: Sources/App/Audio/MicRecorder.swift (recordings), Sources/App/Services/QuickDictationService.swift
//          (quick dictation)
// Notes: AVAudioEngine cannot hold a chosen microphone while Bluetooth headphones are the output:
//        on start it rebuilds its I/O unit as a default-device aggregate (measured: bound to the
//        MacBook microphone, it started on "CADefaultDeviceAggregate" = AirPods Max input +
//        output), so recordings took the AirPods microphone (24 kHz) and pushed the AirPods into
//        their call profile. An AUHAL with output disabled is tied to no output at all and stays
//        on the device it was given (measured: MacBook microphone, 48 kHz, while the AirPods
//        kept playing).
//        Buffers are copied out of the render thread and delivered on a serial queue, so
//        consumers may write files or block briefly without touching the realtime thread.
//        Only the first channel is taken: speech needs one, and a stereo webcam microphone
//        would only double the file.
//        The owner gets `onConfigurationChange` for a new device list, a new default input, the
//        device dying or changing its sample rate (AirPods switching profile); it decides
//        whether a restart is needed (`MicrophoneCapture.target`).

import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

final class MicrophoneCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInputDevice
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone is available."
            case .coreAudio(let step, let status): return "The microphone could not be opened (\(step), \(status))."
            }
        }
    }

    /// The device recorded from.
    let deviceID: AudioDeviceID
    /// Mono Float32 at the device's own rate.
    let format: AVAudioFormat
    /// Device list, default input, device alive or sample rate changed. Called on the delivery queue.
    var onConfigurationChange: (() -> Void)?

    private let unit: AudioUnit
    private let delivery: DispatchQueue
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var isRunning = false

    /// The chosen microphone while it is connected, else the system default input.
    static func target() -> AudioDeviceID? {
        MicrophonePreference.resolvedDeviceID() ?? defaultInputDevice()
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Opens `deviceID` (nil: the chosen microphone or the default input) and starts delivering
    /// buffers to `onBuffer` on `queue`.
    init(deviceID requested: AudioDeviceID?, queue: DispatchQueue, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let device = requested ?? Self.target() else { throw CaptureError.noInputDevice }
        deviceID = device
        delivery = queue
        self.onBuffer = onBuffer

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.coreAudio("component", -1)
        }
        var instance: AudioUnit?
        try Self.check("instance", AudioComponentInstanceNew(component, &instance))
        guard let instance else { throw CaptureError.coreAudio("instance", -1) }
        unit = instance

        do {
            var on: UInt32 = 1
            var off: UInt32 = 0
            try Self.check("enable input", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4))
            try Self.check("disable output", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4))
            var current = device
            try Self.check("device", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &current, UInt32(MemoryLayout<AudioDeviceID>.size)))

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check("device format", AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size))
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate, channels: 1)
            else { throw CaptureError.noInputDevice }
            self.format = format
            var client = format.streamDescription.pointee
            try Self.check("client format", AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size))

            var maxFrames: UInt32 = 0
            var maxSize = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &maxSize)
            scratchCapacity = max(Int(maxFrames), 8192)
            scratch = .allocate(capacity: scratchCapacity)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, _, frames, _ in
                Unmanaged<MicrophoneCapture>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        do {
            try Self.check("callback", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try Self.check("initialize", AudioUnitInitialize(unit))
            try Self.check("start", AudioOutputUnitStart(unit))
        } catch {
            // Fully initialised by now, so deinit runs and frees the scratch buffer.
            AudioComponentInstanceDispose(unit)
            throw error
        }
        isRunning = true
        installListeners()
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    /// Stops the device; no buffer or change is delivered afterwards. Safe to call twice.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeListeners()
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    // MARK: - Render thread

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>, frames: UInt32
    ) -> OSStatus {
        guard Int(frames) <= scratchCapacity else { return noErr }
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(scratch)))
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames, &list)
        guard status == noErr,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0]
        else { return status }
        channel.update(from: scratch, count: Int(frames))
        buffer.frameLength = frames
        delivery.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.onBuffer(buffer)
        }
        return noErr
    }

    // MARK: - Device changes

    private func installListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let watched: [(AudioObjectID, AudioObjectPropertySelector)] = [
            (system, kAudioHardwarePropertyDevices),
            (system, kAudioHardwarePropertyDefaultInputDevice),
            (deviceID, kAudioDevicePropertyDeviceIsAlive),
            (deviceID, kAudioDevicePropertyNominalSampleRate),
        ]
        for (object, selector) in watched {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.isRunning else { return }
                self.onConfigurationChange?()
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, delivery, block) == noErr {
                listeners.append((object, address, block))
            }
        }
    }

    private func removeListeners() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, delivery, block)
        }
        listeners.removeAll()
    }

    /// Whether the device still exists and runs at the rate this capture was opened with.
    var isCurrent: Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr, alive != 0 else { return false }
        var rate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else { return false }
        return rate == format.sampleRate
    }

    private static func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.coreAudio(step, status) }
    }
}
