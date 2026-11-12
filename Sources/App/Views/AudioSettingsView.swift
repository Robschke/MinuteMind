// Purpose: AudioSettingsView, the "Audio" tab in Settings: which microphone meeting and quick
//          recordings use. It replaces the device pickers that used to sit on the recording card.
// Dependencies: Sources/App/Audio/AudioDeviceManager.swift (device list, system default),
//               Sources/App/ViewModels/AppViewModel.swift (selectMicrophone, switches a running recording),
//               Sources/App/Config/AutomationSettings.swift (ownSpeakerName)
// Used by: Sources/App/Views/MeetingMinutesSettingsView.swift (Audio tab)
// Notes: The choice is remembered across launches and applies to recordings and quick dictation,
//        bound to MinuteMind's own audio engines without changing the Mac's default input
//        (MicrophonePreference; user report 2026-10-27: with headphones on, the Mac's microphone
//        should record and the headphones should keep their sound). The speaker picker is gone
//        without replacement: system audio is always captured from all apps via ScreenCaptureKit,
//        the old picker did nothing. The list refreshes when the tab appears.
//        "Your name" replaces the "You" label of the microphone speaker: in new transcripts right
//        away, in older meetings when they are processed or their summary is updated (user decision
//        2026-10-05); existing transcripts are not rewritten in bulk.

import CoreAudio
import SwiftUI

struct AudioSettingsView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        AudioSettingsContent(
            deviceManager: viewModel.audioDeviceManager, settings: viewModel.automationSettings
        ) { deviceID in
            viewModel.selectMicrophone(deviceID)
        }
    }
}

/// Observes the device manager directly: it is an ObservableObject inside the @Observable view model,
/// so its @Published changes would not redraw a view that only reads it through AppViewModel.
private struct AudioSettingsContent: View {
    @ObservedObject var deviceManager: AudioDeviceManager
    @ObservedObject var settings: AutomationSettings
    let select: (AudioDeviceID?) -> Void

    private var systemDefaultLabel: String {
        guard let id = deviceManager.getDefaultInputDevice(),
              let device = deviceManager.inputDevices.first(where: { $0.id == id })
        else { return "System Default" }
        return "System Default (\(device.name))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio")
                    .font(.title3.weight(.semibold))
                Text("The microphone MinuteMind records from. System audio is always captured from all apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Picker(
                    "Microphone",
                    selection: Binding(get: { deviceManager.selectedInputDeviceID }, set: { select($0) })
                ) {
                    Text(systemDefaultLabel).tag(nil as AudioDeviceID?)
                    ForEach(deviceManager.inputDevices) { device in
                        Text(device.name).tag(device.id as AudioDeviceID?)
                    }
                }
                .frame(maxWidth: 420)

                Text("Used for recordings and dictation, and remembered. MinuteMind stays on it when headphones connect, so pick your Mac's microphone to keep Bluetooth headphones sounding clear. A change during a recording switches it right away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)

                TextField("Your name", text: $settings.ownSpeakerName, prompt: Text("You"))
                    .frame(maxWidth: 420)
                    .padding(.top, 12)

                Text("Your microphone is labelled with this name instead of \u{201C}You\u{201D}: in new transcripts, and in older meetings when you update their summary. Summaries use it too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            .formStyle(.columns)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { deviceManager.refreshDevices() }
    }
}
