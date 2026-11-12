// Purpose: Error thrown when a transcription is interrupted by the user, carrying any partial text
//          that was successfully transcribed before cancellation.
// Dependencies: None
// Used by: TranscriptionService, ParakeetTranscriptionService,
//          AppViewModel (catches this to save partial results)

import Foundation

struct TranscriptionInterruptedError: Error, LocalizedError {
    let partialText: String?

    var errorDescription: String? {
        if let text = partialText, !text.isEmpty {
            return "Transcription was stopped. Partial transcript saved."
        }
        return "Transcription was stopped."
    }
}
