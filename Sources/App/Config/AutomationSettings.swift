// Purpose: AutomationSettings — @AppStorage-backed settings model for all automation preferences.
// Dependencies: SwiftUI (@AppStorage), Foundation
// Used by: Sources/App/ViewModels/AppViewModel.swift (automationSettings property),
//          Sources/App/Views/Settings views (Plan 04)
// Notes: Intentionally NOT @MainActor so tests can instantiate it synchronously without await.
//        All @AppStorage accesses are safe to call from any context in practice since they
//        ultimately write to UserDefaults which is thread-safe.
//        Accepts a UserDefaults parameter in init for test isolation (pass UUID-suiteName instance).
//        reviewReminderTimes is stored as Data (JSON [[String:Int]]) because @AppStorage does not
//        support [DateComponents] natively.

import Foundation
import SwiftUI

final class AutomationSettings: ObservableObject {

    // MARK: - Storage

    // MARK: - Published Settings

    @AppStorage("mm.autoStartEnabled") var autoStartEnabled: Bool = true
    @AppStorage("mm.autoStopSilenceThreshold") var autoStopSilenceThreshold: Double = 30.0
    @AppStorage("mm.manualRecordingSilenceEnabled") var manualRecordingSilenceEnabled: Bool = false
    @AppStorage("mm.teamsDetectionEnabled") var teamsDetectionEnabled: Bool = false
    @AppStorage("mm.autoPipelineEnabled") var autoPipelineEnabled: Bool = true
    /// When on, a meeting is processed (cleanup, summary, knowledge) on its own once it has a
    /// project or was filed to General, see MeetingProcessingRule. Off: only the Process buttons.
    /// Transcription itself always runs automatically. Replaces "mm.processWithoutAsking".
    @AppStorage("mm.processOnceAssigned") var processOnceAssigned: Bool = true
    /// Claude model for the background jobs (summary, titles, todos, task brief, time blocks,
    /// board summary, knowledge curation): "sonnet", "opus" or "haiku". Settings, AI.
    @AppStorage("mm.claudeModel") var claudeModel: String = "sonnet"
    @AppStorage("mm.defaultTranscriptionModel") var defaultTranscriptionModel: String = "parakeet"
    @AppStorage("mm.audioPreprocessingEnabled") var audioPreprocessingEnabled: Bool = true
    @AppStorage("mm.speakerDiarizationEnabled") var speakerDiarizationEnabled: Bool = false
    @AppStorage("mm.properNounCorrectionEnabled") var properNounCorrectionEnabled: Bool = true
    @AppStorage("mm.diarizeMicrophone") var diarizeMicrophone: Bool = false
    /// The user's own name: the microphone speaker is labelled with it instead of "You" (Settings, Audio).
    @AppStorage("mm.ownSpeakerName") var ownSpeakerName: String = ""
    /// Diarization engine: "nemotron3" (NVIDIA Nemotron 3, the default) or "fluidAudio"
    /// (pyannote-style clustering). Nemotron is used only once installed; until then FluidAudio runs.
    @AppStorage("mm.diarizationEngine") var diarizationEngine: String = "nemotron3"
    @AppStorage("mm.quickDictationEnabled") var quickDictationEnabled: Bool = true
    /// "toggle" — press ⌃⌥D to start, press again to insert.
    /// "holdFn" — hold the fn (globe) key, release to insert.
    /// "holdRightOption" — hold the right Option key, release to insert.
    /// The legacy value "hold" is treated as "holdRightOption".
    @AppStorage("mm.quickDictationMode") var quickDictationMode: String = "holdFn"
    @AppStorage("mm.quickDictationLanguage") var quickDictationLanguage: String = "auto"
    /// Double-tap the dictation key to start a quick recording; one more press stops it.
    @AppStorage("mm.quickRecordingEnabled") var quickRecordingEnabled: Bool = true
    /// Hold the dictation key with Control to give Claude a one-shot task; the answer lands on the clipboard.
    @AppStorage("mm.claudeTaskEnabled") var claudeTaskEnabled: Bool = true
    /// Claude Code model alias for those tasks: "sonnet", "haiku" or "opus".
    @AppStorage("mm.claudeTaskModel") var claudeTaskModel: String = "sonnet"
    /// The user's standing instructions for every task (tone, language, signature, ...).
    @AppStorage("mm.claudeTaskPrompt") var claudeTaskPrompt: String = ""
    /// The voice assistant may run terminal commands (user request 2026-10-13, on by default).
    @AppStorage("mm.claudeTaskAllowsTerminal") var claudeTaskAllowsTerminal: Bool = true
    @AppStorage("mm.remindersSyncDefault") var remindersSyncDefault: Bool = true
    @AppStorage("mm.liveDictationLanguage") var liveDictationLanguage: String = "auto"
    @AppStorage("mm.autoAcceptExtractedTasks") var autoAcceptExtractedTasks: Bool = true

    // MARK: - Review Reminder Times (custom encoding)

    /// Reminder times stored as Data (JSON-encoded [[String: Int]] with "hour" and "minute" keys).
    @AppStorage("mm.reviewReminderTimes") private var reviewReminderTimesData: Data = Data()

    /// Decoded array of DateComponents (hour + minute only). Defaults to empty array.
    var reviewReminderTimes: [DateComponents] {
        get {
            guard !reviewReminderTimesData.isEmpty,
                  let raw = try? JSONDecoder().decode([[String: Int]].self, from: reviewReminderTimesData)
            else { return [] }
            return raw.map { dict in
                var components = DateComponents()
                components.hour = dict["hour"]
                components.minute = dict["minute"]
                return components
            }
        }
        set {
            let raw = newValue.map { components -> [String: Int] in
                var dict: [String: Int] = [:]
                if let hour = components.hour { dict["hour"] = hour }
                if let minute = components.minute { dict["minute"] = minute }
                return dict
            }
            reviewReminderTimesData = (try? JSONEncoder().encode(raw)) ?? Data()
        }
    }

    // MARK: - Initializer

    /// Designated initializer. Pass a custom `UserDefaults` instance for test isolation.
    /// In production, `.standard` is used automatically via @AppStorage defaults.
    init(defaults: UserDefaults = .standard) {
        // Re-wire all @AppStorage properties to use the injected UserDefaults store
        // when a non-standard suite is provided (required for test isolation).
        if defaults !== UserDefaults.standard {
            _autoStartEnabled = AppStorage(wrappedValue: true, "mm.autoStartEnabled", store: defaults)
            _autoStopSilenceThreshold = AppStorage(wrappedValue: 30.0, "mm.autoStopSilenceThreshold", store: defaults)
            _manualRecordingSilenceEnabled = AppStorage(wrappedValue: false, "mm.manualRecordingSilenceEnabled", store: defaults)
            _teamsDetectionEnabled = AppStorage(wrappedValue: false, "mm.teamsDetectionEnabled", store: defaults)
            _autoPipelineEnabled = AppStorage(wrappedValue: true, "mm.autoPipelineEnabled", store: defaults)
            _processOnceAssigned = AppStorage(wrappedValue: true, "mm.processOnceAssigned", store: defaults)
            _claudeModel = AppStorage(wrappedValue: "sonnet", "mm.claudeModel", store: defaults)
            _defaultTranscriptionModel = AppStorage(wrappedValue: "parakeet", "mm.defaultTranscriptionModel", store: defaults)
            _audioPreprocessingEnabled = AppStorage(wrappedValue: true, "mm.audioPreprocessingEnabled", store: defaults)
            _speakerDiarizationEnabled = AppStorage(wrappedValue: false, "mm.speakerDiarizationEnabled", store: defaults)
            _diarizationEngine = AppStorage(wrappedValue: "nemotron3", "mm.diarizationEngine", store: defaults)
            _properNounCorrectionEnabled = AppStorage(wrappedValue: true, "mm.properNounCorrectionEnabled", store: defaults)
            _diarizeMicrophone = AppStorage(wrappedValue: false, "mm.diarizeMicrophone", store: defaults)
            _quickDictationEnabled = AppStorage(wrappedValue: true, "mm.quickDictationEnabled", store: defaults)
            _quickDictationMode = AppStorage(wrappedValue: "holdFn", "mm.quickDictationMode", store: defaults)
            _quickDictationLanguage = AppStorage(wrappedValue: "auto", "mm.quickDictationLanguage", store: defaults)
            _quickRecordingEnabled = AppStorage(wrappedValue: true, "mm.quickRecordingEnabled", store: defaults)
            _claudeTaskEnabled = AppStorage(wrappedValue: true, "mm.claudeTaskEnabled", store: defaults)
            _claudeTaskModel = AppStorage(wrappedValue: "sonnet", "mm.claudeTaskModel", store: defaults)
            _claudeTaskPrompt = AppStorage(wrappedValue: "", "mm.claudeTaskPrompt", store: defaults)
            _claudeTaskAllowsTerminal = AppStorage(wrappedValue: true, "mm.claudeTaskAllowsTerminal", store: defaults)
            _remindersSyncDefault = AppStorage(wrappedValue: true, "mm.remindersSyncDefault", store: defaults)
            _liveDictationLanguage = AppStorage(wrappedValue: "auto", "mm.liveDictationLanguage", store: defaults)
            _autoAcceptExtractedTasks = AppStorage(wrappedValue: true, "mm.autoAcceptExtractedTasks", store: defaults)
            _reviewReminderTimesData = AppStorage(wrappedValue: Data(), "mm.reviewReminderTimes", store: defaults)
        }
    }
}
