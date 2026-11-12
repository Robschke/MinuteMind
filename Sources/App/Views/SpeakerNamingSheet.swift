// Purpose: Lets the user put a name to each diarized speaker — play a few seconds of that voice,
//          type who it was, and apply the names to the transcript.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (speakerProfiles, renameSpeakers,
//               speakerSampleURL, speakerNameSuggestions),
//               Sources/App/Models/RecordingSession.swift (SpeakerProfile),
//               Sources/App/Components/ResizableSheet.swift
// Used by: Sources/App/Components/SessionActions.swift (card overflow → "Name Speakers"),
//          Sources/App/Views/TranscriptDetailView.swift (speaker chips, "Name Speakers" button)
// Notes: Playback seeks the original recording to the sample range instead of exporting a clip, so
//        opening the sheet is instant and nothing is written to disk. A single shared player is
//        stopped when the sheet closes. Names are applied only on Save, so cancelling changes
//        nothing.
//        Saving also teaches the voice library (VoiceDirectoryStore), which is why speakers can
//        already arrive named — those rows are marked "Recognized" so a wrong automatic match is
//        visible rather than silently trusted.
//        `focusLabel` comes from clicking a speaker chip in the transcript reader: that row is
//        scrolled to, highlighted, its name field focused and its sample played, so naming one
//        speaker is click, listen, type. Drafts and focus are keyed by the original label, which
//        stays unique even when two speakers were given the same name.
//        Saving names on a meeting that already has a summary asks whether to update the summary
//        (user decision 2026-10-05), since it still uses the old labels.
//        Saving names on an unprocessed meeting with a project starts processing if it has not
//        started yet ("Save and Process", MeetingProcessingRule). Without a project the footer says
//        that choosing one comes next. Naming is optional: processing never waits for it.

import AVFoundation
import SwiftUI

struct SpeakerNamingSheet: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    let session: RecordingSession
    /// Transcript label of the speaker to start with (scrolled to and focused); nil for none.
    var focusLabel: String? = nil

    /// Draft names keyed by the speaker's original label ("Speaker 2"), which stays unique even
    /// when two speakers were given the same name. Mapped to the transcript's current labels on save.
    @State private var draftNames: [String: String] = [:]
    @State private var player: AVPlayer?
    @State private var playingLabel: String?
    @State private var stopTask: Task<Void, Never>?
    @FocusState private var focusedField: String?
    /// Original label of the row opened from the transcript, highlighted until another field is
    /// focused so the user sees where they landed.
    @State private var highlightedLabel: String?
    @State private var offerSummaryUpdate = false

    /// Most-talkative speaker first — the person who dominated a meeting is usually the easiest to
    /// place, so naming from the top down is the fastest path through the list.
    private var profiles: [RecordingSession.SpeakerProfile] {
        viewModel.nameableSpeakers(for: session)
            .sorted { ($0.spokenSeconds ?? 0) > ($1.spokenSeconds ?? 0) }
    }

    /// True for transcripts made before speakers were recorded: labels can be renamed, but there is
    /// no audio sample to play and no voice to learn.
    private var isTextOnly: Bool {
        viewModel.speakerProfiles(for: session).isEmpty && !profiles.isEmpty
    }

    private var suggestions: [String] {
        viewModel.speakerNameSuggestions(for: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if profiles.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(profiles) { profile in
                                speakerRow(profile)
                                    .id(profile.label)
                                if profile.id != profiles.last?.id { Divider() }
                            }
                        }
                    }
                    .task { await focusRequestedSpeaker(proxy) }
                }
            }

            Divider()

            footer
        }
        .frame(minWidth: 480, minHeight: 320)
        .resizableSheet()
        .onAppear(perform: seedDrafts)
        .onChange(of: focusedField) { _, field in
            if let field, field != highlightedLabel { highlightedLabel = nil }
        }
        .onDisappear(perform: stopPlayback)
        .alert("Update the summary with the new names?", isPresented: $offerSummaryUpdate) {
            Button("Update Summary") {
                viewModel.processMeeting(session.id)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            Button("Not Now", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("The current summary still uses the old speaker labels.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name Speakers")
                .font(.headline)
            Text("Listen to a few seconds of each voice, then enter who it was. The names replace the speaker labels in the transcript — and are remembered, so this person is recognized automatically in future recordings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isTextOnly {
                Label(
                    "This transcript was made before voice samples were stored — you can rename the labels, but there is nothing to play back and no voice is learned. Transcribe again to enable both.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No speakers were detected for this recording.")
                .font(.subheadline)
            Text("Enable \"Identify speakers\" in Settings → Automation and transcribe again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func speakerRow(_ profile: RecordingSession.SpeakerProfile) -> some View {
        HStack(spacing: 12) {
            Button {
                togglePlayback(for: profile)
            } label: {
                Image(systemName: playingLabel == profile.label ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(
                profile.sampleDuration <= 0
                    || viewModel.speakerSampleURL(for: profile, in: session) == nil)
            .help(
                profile.sampleDuration <= 0
                    ? "No audio sample stored for this speaker"
                    : "Play \(Int(profile.sampleDuration.rounded()))s of this speaker")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(profile.label)
                        .font(.subheadline.weight(.medium))
                    if profile.wasAutoMatched == true {
                        Label("Recognized", systemImage: "sparkles")
                            .font(.caption2)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.accentColor)
                            .help("Matched against a voice you named before — correct it if it's wrong")
                    }
                }
                Text(subtitle(for: profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 190, alignment: .leading)

            TextField(
                "Name", text: Binding(
                    get: { draftNames[profile.label] ?? "" },
                    set: { draftNames[profile.label] = $0 })
            )
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: profile.label)

            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { draftNames[profile.label] = suggestion }
                    }
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pick a name from the meeting's participants")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(
            highlightedLabel == profile.label ? Color.accentColor.opacity(0.08) : .clear)
    }

    private var footer: some View {
        HStack {
            if playingLabel != nil {
                Label("Playing…", systemImage: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if needsProject {
                Text("Next: choose a project to process this meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(savesAndProcesses ? "Save and Process" : "Save Names") {
                applyNames()
                if canUpdateSummary {
                    offerSummaryUpdate = true
                } else {
                    viewModel.speakersNamed(session.id)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!hasUsableNames)
        }
        .padding()
    }

    // MARK: - Actions

    private var current: RecordingSession? {
        viewModel.sessions.first { $0.id == session.id }
    }

    /// Unprocessed meeting with a project: saving starts processing.
    private var savesAndProcesses: Bool {
        guard let current else { return false }
        return MeetingProcessingRule.decide(
            current, trigger: .speakersNamed, enabled: viewModel.automationSettings.processOnceAssigned) == .process
    }

    /// Unprocessed meeting without a project: processing waits for one.
    private var needsProject: Bool {
        guard let current, !current.isQuickRecording else { return false }
        return current.meetingMinutesFileName == nil && !current.hasProcessingTarget
    }

    /// A meeting that already has a summary was summarized with the old labels.
    private var canUpdateSummary: Bool {
        guard viewModel.canGenerateMeetingMinutes,
            let current = viewModel.sessions.first(where: { $0.id == session.id })
        else { return false }
        return viewModel.minutesURL(for: current) != nil && !viewModel.isGeneratingMinutes(for: current)
    }

    private var hasUsableNames: Bool {
        profiles.contains { profile in
            let trimmed = (draftNames[profile.label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != profile.displayLabel
        }
    }

    /// Pre-fills fields with names already assigned earlier.
    private func seedDrafts() {
        for profile in profiles where profile.name != nil {
            draftNames[profile.label] = profile.name ?? ""
        }
    }

    private func applyNames() {
        // renameSpeakers works on the labels the transcript currently shows.
        var names: [String: String] = [:]
        for profile in profiles {
            let trimmed = (draftNames[profile.label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != profile.displayLabel {
                names[profile.displayLabel] = trimmed
            }
        }

        guard !names.isEmpty else { return }
        viewModel.renameSpeakers(names, for: session)
    }

    /// Opening from a speaker chip means "who is this?": scroll to that row, focus its field and
    /// play its sample, so naming is listen and type. The short wait lets the sheet finish
    /// presenting; before that the nested panel takes first responder and drops the focus.
    private func focusRequestedSpeaker(_ proxy: ScrollViewProxy) async {
        guard let focusLabel,
            let profile = profiles.first(where: { $0.displayLabel == focusLabel })
        else { return }

        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }

        highlightedLabel = profile.label
        withAnimation { proxy.scrollTo(profile.label, anchor: .center) }
        focusedField = profile.label
        if profile.sampleDuration > 0 { togglePlayback(for: profile) }
    }

    // MARK: - Playback

    private func togglePlayback(for profile: RecordingSession.SpeakerProfile) {
        if playingLabel == profile.label {
            stopPlayback()
            return
        }
        stopPlayback()

        guard let url = viewModel.speakerSampleURL(for: profile, in: session) else { return }

        let player = AVPlayer(url: url)
        player.seek(
            to: CMTime(seconds: profile.sampleStart, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()

        self.player = player
        playingLabel = profile.label

        // Stop at the end of the sample range — AVPlayer has no built-in range playback.
        let duration = max(profile.sampleDuration, 0.5)
        stopTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run { stopPlayback() }
        }
    }

    private func stopPlayback() {
        stopTask?.cancel()
        stopTask = nil
        player?.pause()
        player = nil
        playingLabel = nil
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    /// Channel, sample position, and how much this speaker talked — talk time is often the fastest
    /// way to tell who is who ("the one who spoke for 20 minutes is the presenter").
    private func subtitle(for profile: RecordingSession.SpeakerProfile) -> String {
        guard profile.sampleDuration > 0 else { return "From the transcript" }

        var parts = [
            profile.channel == .microphone ? "This Mac's microphone" : "Meeting audio",
            timecode(profile.sampleStart),
        ]
        if let spoken = profile.spokenSeconds, spoken >= 1 {
            parts.append("\(spokenDescription(spoken)) spoken")
        }
        return parts.joined(separator: " · ")
    }

    private func spokenDescription(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? "\(Int(seconds.rounded()))s"
            : "\(Int((seconds / 60).rounded()))min"
    }
}
