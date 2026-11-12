// Purpose: SessionPlaybackStrip, a recording card's audio in one row: play/pause, the compact
//          waveform (click to jump) and the time.
// Dependencies: Sources/App/Components/SessionAudioPlayer.swift (SessionAudioPlayback),
//               Sources/App/Components/AudioWaveformView.swift (compact, cropMode),
//               Sources/App/Audio/AudioProcessor.swift (WaveformData)
// Used by: Sources/App/Views/AllTranscriptsView.swift (TranscriptCardWithProject),
//          Sources/App/Views/ProjectDetailView.swift (ProjectRecordingCard)
// Notes: Card redesign 2026-10-05 ("Speaker Rail"): replaces the separate transport row, the
//        Hide/Show toggle, the 56 pt waveform box and the inline "Crop Audio" link (cropping and
//        Restore Original now start from the card's "…" menu). The waveform loads once on
//        appear and reloads when the session's cached samples or crop range change, so a crop
//        or a restore from the menu shows up without the card telling it. No Space shortcut on
//        the play button: every card would claim it, and Space already starts a recording.

import SwiftUI

struct SessionPlaybackStrip: View {
    let session: RecordingSession
    /// The microphone file exists (its waveform is preferred, it carries the most speech).
    let hasMicrophone: Bool
    @Bindable var playback: SessionAudioPlayback
    let onGenerateWaveform: ((RecordingSession.Channel) async -> AudioProcessor.WaveformData?)?
    let onCropAudio: ((TimeInterval, TimeInterval) async -> Void)?
    @Binding var isCropping: Bool

    @State private var waveformData: AudioProcessor.WaveformData?
    @State private var isLoading = false
    @State private var hasAttemptedLoad = false

    var body: some View {
        HStack(alignment: isCropping ? .top : .center, spacing: 10) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying ? "Pause" : "Play")

            waveform
                .frame(maxWidth: .infinity)

            Text("\(timecode(playback.currentTime)) / \(timecode(playback.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .onAppear {
            guard !hasAttemptedLoad else { return }
            hasAttemptedLoad = true
            Task { await loadWaveform() }
        }
        .onChange(of: session.id) { _, _ in
            waveformData = nil
            Task { await loadWaveform() }
        }
        .onChange(of: session.waveformSamples) { _, samples in
            if samples != nil, waveformData == nil { Task { await loadWaveform() } }
        }
        // Cropping needs the waveform; without one the request from the menu is dropped.
        .onChange(of: isCropping) { _, cropping in
            if cropping, waveformData == nil { isCropping = false }
        }
        .onChange(of: session.cropStartTime) { _, _ in Task { await loadWaveform() } }
        .onChange(of: session.cropEndTime) { _, _ in Task { await loadWaveform() } }
    }

    @ViewBuilder
    private var waveform: some View {
        if let data = waveformData, !isLoading {
            AudioWaveformView(
                waveformData: data,
                recordingDate: session.createdAt,
                onCrop: { start, end in
                    Task {
                        isLoading = true
                        await onCropAudio?(start, end)
                        await loadWaveform()
                    }
                },
                currentPlaybackTime: playback.currentTime,
                isPlaying: playback.isPlaying,
                onSeek: { playback.seek(to: $0) },
                compact: true,
                cropMode: $isCropping
            )
        } else {
            // Without a waveform (still generating, or none can be made) a plain progress line.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geometry.size.width * playedFraction)
                }
            }
            .frame(height: 3)
            .overlay {
                if isLoading { ProgressView().controlSize(.mini) }
            }
            .frame(height: 28)
        }
    }

    private var playedFraction: CGFloat {
        guard playback.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, playback.currentTime / playback.duration)))
    }

    private func loadWaveform() async {
        guard let onGenerateWaveform else { return }
        isLoading = true
        defer { isLoading = false }
        waveformData = await onGenerateWaveform(hasMicrophone ? .microphone : .system)
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
