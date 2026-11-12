// Purpose: MicrophonePreference, the microphone the user picked for recordings and dictation,
//          remembered across launches by its stable device UID, without touching the Mac's
//          system-wide default input.
// Dependencies: CoreAudio
// Used by: Sources/App/Audio/AudioDeviceManager.swift (stores the choice),
//          Sources/App/Audio/MicrophoneCapture.swift (records from it: recordings and dictation),
//          Sources/App/Audio/MicRecorder.swift, Sources/App/ViewModels/AppViewModel.swift (startRecording)
// Notes: The app used to pick a microphone by setting the system default input. macOS moves that
//        default to headphones when they connect, so a recording followed them onto the headset
//        microphone, which also drops Bluetooth headphones into their low-quality call profile
//        (user report 2026-10-27: "it should just use my Mac microphone and have the sound clear
//        on the headphones"). Recording from the chosen device directly
//        (MicrophoneCapture) keeps the recording on it whatever the default does. Device IDs change between boots and
//        reconnects, the UID does not, so the UID is what is stored. Nil means System Default.

import CoreAudio
import Foundation

enum MicrophonePreference {
    static let key = "mm.inputDeviceUID"

    /// The chosen microphone's UID, nil for System Default.
    static var uid: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The chosen microphone while it is connected; nil for System Default or when it is gone.
    static func resolvedDeviceID() -> AudioDeviceID? {
        uid.flatMap(deviceID(forUID:))
    }

    static func uid(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let uid = value?.takeRetainedValue() else { return nil }
        return uid as String
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
