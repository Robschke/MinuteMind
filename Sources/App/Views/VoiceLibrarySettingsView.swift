// Purpose: Lists the voices MinuteMind has learned — the people it recognises automatically in new
//          recordings — and lets the user rename or forget any of them.
// Dependencies: Sources/App/Store/VoiceDirectoryStore.swift,
//               Sources/App/Models/KnownVoice.swift,
//               Sources/App/ViewModels/AppViewModel.swift (voiceDirectory)
// RBAC: None — local user data, no access control.
// Dependents: Sources/App/Views/AutomationSettingsView.swift (speaker identification section)
// Notes: VoiceDirectoryStore is a plain (non-observable) store, so the list is mirrored into local
//        state and reloaded after every mutation. That is deliberate: the directory is written from
//        transcription too, and a snapshot the user explicitly refreshes beats a half-observable
//        store that updates in some paths and not others.
//        Deleting is offered without a confirmation dialog but is non-destructive to transcripts —
//        names already written into a transcript stay; only future recognition is forgotten.

import SwiftUI

struct VoiceLibrarySettingsView: View {
    @Environment(AppViewModel.self) private var appViewModel

    @State private var voices: [KnownVoice] = []
    @State private var editingID: UUID?
    @State private var draftName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Known voices")
                    .font(.subheadline.weight(.medium))
                if !voices.isEmpty {
                    Text("\(voices.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reload the list")
            }

            if voices.isEmpty {
                Text("No voices learned yet. Name a speaker in a transcript's \"Name speakers\" sheet and that person is recognized in every later recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("These people are named automatically when their voice is detected. Rename or forget one if it was ever matched to the wrong person.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(voices) { voice in
                        row(voice)
                        if voice.id != voices.last?.id { Divider() }
                    }
                }
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func row(_ voice: KnownVoice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(Color.accentColor)

            if editingID == voice.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(voice) }
                Button("Save") { commitRename(voice) }
                    .controlSize(.small)
                Button("Cancel") { editingID = nil }
                    .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.name)
                        .font(.subheadline)
                    Text(detail(for: voice))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editingID = voice.id
                    draftName = voice.name
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename this voice")

                Button {
                    appViewModel.voiceDirectory.delete(voice.id)
                    reload()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Forget this voice — transcripts keep the names they already have")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// How much evidence backs this voice — the honest signal for whether a match can be trusted.
    private func detail(for voice: KnownVoice) -> String {
        let samples = voice.sampleCount == 1 ? "1 sample" : "\(voice.sampleCount) samples"
        guard voice.totalSpokenSeconds >= 60 else { return samples }
        return "\(samples) · \(Int((voice.totalSpokenSeconds / 60).rounded()))min heard"
    }

    private func commitRename(_ voice: KnownVoice) {
        appViewModel.voiceDirectory.rename(voice.id, to: draftName)
        editingID = nil
        reload()
    }

    private func reload() {
        voices = appViewModel.voiceDirectory.voices
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
