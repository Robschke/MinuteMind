// Purpose: One audio transport for a recording session — play/pause and scrub position. It plays
//          both channels together when both exist.
// Dependencies: AVFoundation, Sources/App/Models/RecordingSession.swift (Channel)
// RBAC: None.
// Dependents: Sources/App/Views/ProjectDetailView.swift (ProjectRecordingCard),
//             Sources/App/Views/AllTranscriptsView.swift (TranscriptCardWithProject)
// Notes: Replaces four near-identical playback structs spread across the two card views, which
//        offered "Play both" / "Microphone only" / "Speaker only" as three separate buttons and had
//        no pause at all — only stop, which threw away your position in a 40-minute meeting.
//        The two channels are separate files, so "mix" means two AVAudioPlayers started against a
//        shared `deviceCurrentTime` deadline. Pausing captures the position and resuming re-arms
//        both players on a fresh deadline, which keeps them in sync without remixing audio on disk.
//        The Mix / Mic / Meeting picker was removed (user decision 2026-10-04): nobody used it and
//        the labels did not explain themselves. The source model stays internal, always the mix.

import AVFoundation
import Observation
import SwiftUI

/// Playback state for one session's audio. Owns the players so the transport and the waveform
/// always agree on the current position.
@Observable
@MainActor
final class SessionAudioPlayback {

    /// Which audio a session can play. `.mix` is only offered when both files exist.
    enum Source: String, CaseIterable, Identifiable {
        case mix
        case microphone
        case system

        var id: String { rawValue }
    }

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    /// Selected source. Changing it while playing keeps playing at the same position.
    var source: Source = .mix {
        didSet {
            guard source != oldValue else { return }
            let wasPlaying = isPlaying
            let position = currentTime
            unload()
            if wasPlaying {
                play(from: position)
            } else {
                prepare()
                seek(to: position)
            }
        }
    }

    var onError: ((String) -> Void)?

    private var micURL: URL?
    private var systemURL: URL?
    private var players: [AVAudioPlayer] = []
    private var ticker: Timer?
    private let finishWatcher = FinishWatcher()

    var availableSources: [Source] {
        switch (micURL, systemURL) {
        case (.some, .some): return [.mix, .microphone, .system]
        case (.some, nil): return [.microphone]
        case (nil, .some): return [.system]
        default: return []
        }
    }

    var hasAudio: Bool { !availableSources.isEmpty }

    // MARK: - Configuration

    /// Points the transport at a session's files. Safe to call on every view update — it only
    /// resets when the URLs actually changed, so playback is not interrupted by a redraw.
    func configure(micURL: URL?, systemURL: URL?) {
        guard micURL != self.micURL || systemURL != self.systemURL else { return }

        stop()
        self.micURL = micURL
        self.systemURL = systemURL

        if !availableSources.contains(source) {
            source = availableSources.first ?? .mix
        }
        prepare()
    }

    // MARK: - Transport

    func toggle() {
        isPlaying ? pause() : play(from: currentTime)
    }

    func play(from position: TimeInterval? = nil) {
        if players.isEmpty { prepare() }
        guard !players.isEmpty else { return }

        let start = min(max(position ?? currentTime, 0), max(duration - 0.05, 0))
        for player in players { player.currentTime = start }

        // A shared deadline slightly in the future is what keeps two files sample-aligned.
        let deadline = (players.first?.deviceCurrentTime ?? 0) + 0.08
        finishWatcher.remaining = players.count
        for player in players { player.play(atTime: deadline) }

        isPlaying = true
        currentTime = start
        startTicker()
    }

    func pause() {
        for player in players { player.pause() }
        currentTime = players.first?.currentTime ?? currentTime
        isPlaying = false
        stopTicker()
    }

    /// Stops and rewinds. Used when the view goes away or the source files change.
    func stop() {
        unload()
        currentTime = 0
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), max(duration, 0))
        currentTime = clamped
        if isPlaying {
            play(from: clamped)
        } else {
            for player in players { player.currentTime = clamped }
        }
    }

    // MARK: - Players

    private func prepare() {
        let urls: [URL]
        switch source {
        case .mix: urls = [micURL, systemURL].compactMap { $0 }
        case .microphone: urls = [micURL].compactMap { $0 }
        case .system: urls = [systemURL].compactMap { $0 }
        }
        guard !urls.isEmpty else { return }

        do {
            players = try urls.map { url in
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = finishWatcher
                player.prepareToPlay()
                return player
            }
            // The channels can differ in length; the longer one defines the timeline.
            duration = players.map(\.duration).max() ?? 0
            finishWatcher.onFinished = { [weak self] in
                guard let self else { return }
                self.pause()
                self.currentTime = 0
                for player in self.players { player.currentTime = 0 }
            }
        } catch {
            players = []
            onError?("Unable to play audio: \(error.localizedDescription)")
        }
    }

    private func unload() {
        stopTicker()
        for player in players { player.stop() }
        players = []
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let player = self.players.first, player.isPlaying else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Fires once both channels have run out, not on the first one to finish.
    ///
    /// AVAudioPlayer calls its delegate off the main actor, so the completion hops explicitly
    /// rather than asserting isolation it does not have.
    private final class FinishWatcher: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        var onFinished: (@MainActor () -> Void)?
        var remaining = 0

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            remaining -= 1
            guard remaining <= 0 else { return }
            let handler = onFinished
            Task { @MainActor in handler?() }
        }
    }
}

/// The transport row: play/pause, elapsed / total, and the channel picker when there is a choice.
struct SessionAudioPlayerView: View {
    @Bindable var playback: SessionAudioPlayback

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(playback.isPlaying ? "Pause" : "Play")

            Text("\(timecode(playback.currentTime)) / \(timecode(playback.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()
        }
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
