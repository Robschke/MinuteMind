// Purpose: The single Transcribe / Retranscribe control shown on a session card. Runs the engine
//          configured in Settings → Automation instead of making the user pick one per recording.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift
//               (configuredTranscriptionModel, transcribeWithConfiguredEngine,
//                configuredTranscriptionEngineName, transcriptionEngineFallbackNote)
// RBAC: None.
// Dependents: Sources/App/Views/ProjectDetailView.swift (ProjectRecordingCard),
//             Sources/App/Views/AllTranscriptsView.swift (TranscriptCardWithProject)
// Notes: One button instead of per-engine buttons on both cards. The engine belongs in Settings:
//        a per-recording choice is one the user has to make dozens of times and almost always
//        answers identically.
//        The menu keeps a per-run language override, which the old per-engine submenus provided and
//        would otherwise be lost.
//        When the configured engine is unavailable, AppViewModel falls back to Apple Speech; the
//        note is surfaced here rather than swallowed, so a silent downgrade is visible.

import SwiftUI

struct SessionTranscribeButton: View {
    @Environment(AppViewModel.self) private var viewModel

    let session: RecordingSession
    /// Changes the wording when a transcript already exists — same action either way.
    var isRetranscribe: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Transcribe in") {
                    ForEach(AppViewModel.LanguageOption.allCases) { option in
                        Button {
                            viewModel.transcribeWithConfiguredEngine(
                                sessionID: session.id, language: option)
                        } label: {
                            Label(option.label, systemImage: icon(for: option))
                        }
                    }
                }
            } label: {
                Label(isRetranscribe ? "Retranscribe" : "Transcribe", systemImage: "waveform")
            } primaryAction: {
                viewModel.transcribeWithConfiguredEngine(sessionID: session.id)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .help(
                "Transcribe with \(viewModel.configuredTranscriptionEngineName) — change the engine in Settings → Automation"
            )

            if let note = viewModel.transcriptionEngineFallbackNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(viewModel.configuredTranscriptionEngineName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func icon(for language: AppViewModel.LanguageOption) -> String {
        switch language {
        case .auto: return "globe"
        case .german: return "character.book.closed"
        case .english: return "textformat"
        }
    }
}
