// Purpose: SpeechAuthorization, asks macOS for speech recognition permission from any isolation
//          without crashing.
// Dependencies: Speech (SFSpeechRecognizer)
// Used by: Sources/App/Supporting/OnboardingPermissions.swift (setup's speech step),
//          Sources/App/Services/QuickDictationService.swift (ensureAuthorized)
// Notes: SFSpeechRecognizer.requestAuthorization calls its handler on a background queue. A
//        handler written inside a @MainActor type inherits the main actor, and the Swift 6
//        runtime traps when it runs off the main thread (the app crashes right after the user
//        answers the permission prompt). This function is nonisolated and its handler is
//        @Sendable, so the handler carries no actor and only resumes the continuation.

import Speech

enum SpeechAuthorization {
    nonisolated static func request() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }
}
