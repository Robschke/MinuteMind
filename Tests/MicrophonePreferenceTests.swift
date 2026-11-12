// Purpose: Tests for MicrophonePreference: a device's UID leads back to the same device, an
//          unknown UID to none, and a capture records from the microphone it was given without
//          changing the system default input.
// Dependencies: Sources/App/Audio/MicrophonePreference.swift, Sources/App/Audio/MicrophoneCapture.swift,
//               Sources/App/Audio/AudioDeviceManager.swift

import CoreAudio
import Foundation
import Testing

@testable import MinuteMindApp

@Suite("MicrophonePreference Tests")
struct MicrophonePreferenceTests {
    @Test func aDeviceUIDLeadsBackToTheDevice() throws {
        // Machines without any input device (some CI hosts) have nothing to check.
        guard let device = AudioDeviceManager().getDefaultInputDevice(), device != kAudioObjectUnknown else { return }
        let uid = try #require(MicrophonePreference.uid(of: device))
        #expect(MicrophonePreference.deviceID(forUID: uid) == device)
    }

    @Test func anUnknownUIDIsNoDevice() {
        #expect(MicrophonePreference.deviceID(forUID: "no-such-device-\(UUID().uuidString)") == nil)
    }

    @Test func aCaptureStaysOnItsMicrophoneAndLeavesTheSystemDefaultAlone() {
        let manager = AudioDeviceManager()
        guard let defaultInput = manager.getDefaultInputDevice(), defaultInput != kAudioObjectUnknown,
              let other = manager.inputDevices.first(where: { $0.id != defaultInput }),
              let capture = try? MicrophoneCapture(deviceID: other.id, queue: DispatchQueue(label: "test"), onBuffer: { _ in })
        else { return }
        defer { capture.stop() }
        #expect(capture.deviceID == other.id)
        #expect(capture.format.channelCount == 1)
        #expect(manager.getDefaultInputDevice() == defaultInput)
    }
}
