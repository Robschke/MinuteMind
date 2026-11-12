// Purpose: RecordingCardParts, the shared pieces of a recording card: the title header, the meta
//          line (when, how long, who, audio retention), the talk-time bar and the speaker preview.
// Dependencies: Sources/App/Components/SpeakerPalette.swift (colours, initials),
//               Sources/App/Transcription/TranscriptSpeakerSummary.swift (turns, talk time),
//               Sources/App/Components/SessionAudioPlayer.swift (SessionAudioPlayback, for seeking),
//               Sources/App/Components/StatusBadge.swift, Sources/App/Components/KeepAudioToggle.swift
//               (AudioRetentionChip)
// Used by: Sources/App/Views/AllTranscriptsView.swift (TranscriptCardWithProject),
//          Sources/App/Views/ProjectDetailView.swift (ProjectRecordingCard)
// Notes: Card redesign 2026-10-05, concept "Speaker Rail" (user's pick from three design agents).
//        The title is plain text (double-click or the "…" menu renames it), the status badge
//        shows only while something is happening (no green READY on finished meetings), the
//        language code moved into the date's tooltip. The preview shows the first three turns:
//        a filled avatar with initials, the name in the speaker's colour, a timestamp chip that
//        plays from that point, and a thin rail in the same colour along the text. Speaker data
//        is computed once per transcript (and own name), not on every render.

import SwiftUI

// MARK: - Header

struct RecordingCardHeader<Accessory: View>: View {
    let session: RecordingSession
    var transcriptionProgress: (current: Int, total: Int)? = nil
    @Binding var isRenaming: Bool
    let rename: (String) -> Void
    @ViewBuilder var accessory: () -> Accessory

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isRenaming {
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { isRenaming = false }
                    .onAppear {
                        draft = session.title
                        fieldFocused = true
                    }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Text(session.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                    .onTapGesture(count: 2) { isRenaming = true }
                    .help("Double-click to rename")
            }

            Spacer(minLength: 8)

            accessory()

            // Finished meetings need no badge; only states where something happens get one.
            if session.status != .completed {
                StatusBadge(
                    status: session.status,
                    animated: session.status == .recording || session.status == .liveTranscribing,
                    progress: transcriptionProgress.map { Double($0.current) / Double(max(1, $0.total)) })
            }
        }
    }

    private func commit() {
        guard isRenaming else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != session.title { rename(trimmed) }
        isRenaming = false
    }
}

// MARK: - Speakers of one transcript

/// Everything the card shows about a transcript's speakers, computed once per transcript.
struct RecordingSpeakerModel: Equatable {
    var order: [String] = []
    var kinds: [String: SpeakerPalette.Kind] = [:]
    var talk: [TranscriptSpeakerSummary.TalkTime] = []
    var turns: [TranscriptSpeakerSummary.Turn] = []

    init() {}

    init(transcript: String, ownName: String?) {
        talk = TranscriptSpeakerSummary.talkTimes(transcript)
        turns = TranscriptSpeakerSummary.previewTurns(transcript)
        order = talk.map(\.speaker)
        kinds = SpeakerPalette.assign(order, ownName: ownName)
    }

    func kind(of speaker: String) -> SpeakerPalette.Kind { kinds[speaker] ?? .unnamed }
    @MainActor func color(of speaker: String) -> Color { SpeakerPalette.color(for: kind(of: speaker)) }
}

/// Meta line, talk bar and speaker preview of a card.
struct RecordingCardSummary: View {
    let session: RecordingSession
    let playback: SessionAudioPlayback
    let ownName: String?

    @State private var model: RecordingSpeakerModel

    init(session: RecordingSession, playback: SessionAudioPlayback, ownName: String?) {
        self.session = session
        self.playback = playback
        self.ownName = ownName
        _model = State(initialValue: RecordingSpeakerModel(
            transcript: session.transcript?.text ?? "", ownName: ownName))
    }

    private struct Key: Equatable {
        let text: String
        let ownName: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordingMetaLine(session: session, playback: playback, model: model, ownName: ownName)
            if model.talk.count > 1 {
                SpeakerTalkBar(model: model)
            }
            if !model.turns.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.turns.enumerated()), id: \.offset) { _, turn in
                        SpeakerTurnRow(turn: turn, model: model, ownName: ownName, playback: playback)
                    }
                }
            }
        }
        .onChange(of: Key(text: session.transcript?.text ?? "", ownName: ownName)) { _, key in
            model = RecordingSpeakerModel(transcript: key.text, ownName: key.ownName)
        }
    }
}

// MARK: - Meta line

private struct RecordingMetaLine: View {
    let session: RecordingSession
    let playback: SessionAudioPlayback
    let model: RecordingSpeakerModel
    let ownName: String?

    var body: some View {
        HStack(spacing: 6) {
            if session.isQuickRecording {
                Label("Quick recording", systemImage: "waveform")
                    .fontWeight(.medium)
                    .help("Started by double tapping the dictation key. Assign a project to file it in its workspace.")
                separator
            }
            Text(dateText)
                .help(fullDateText)
            if let duration = durationText {
                separator
                Text(duration)
            }
            if !model.order.isEmpty {
                separator
                avatarStack
                // Dropped first when the line gets tight; the avatars already say who was there.
                ViewThatFits(in: .horizontal) {
                    Text(model.order.count == 1 ? "1 speaker" : "\(model.order.count) speakers")
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Spacer(minLength: 8)
            AudioRetentionChip(session: session)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var separator: some View {
        Text("\u{00B7}").foregroundStyle(.tertiary)
    }

    private var avatarStack: some View {
        let shown = model.order.prefix(4)
        return HStack(spacing: -3) {
            ForEach(Array(shown), id: \.self) { speaker in
                // One letter at this size; two would be clipped by the overlap.
                SpeakerAvatar(
                    initials: String(SpeakerPalette.initials(for: speaker, ownName: ownName).prefix(
                        SpeakerRenaming.isGenerated(speaker) ? 2 : 1)),
                    kind: model.kind(of: speaker), size: 18)
                    .overlay(Circle().stroke(DesignSystem.Colors.card, lineWidth: 1.5))
                    .help(speaker)
            }
            if model.order.count > shown.count {
                Text("+\(model.order.count - shown.count)")
                    .padding(.leading, 8)
            }
        }
    }

    private var dateText: String {
        let calendar = Calendar.current
        let time = session.createdAt.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(session.createdAt) { return "Today \(time)" }
        if calendar.isDateInYesterday(session.createdAt) { return "Yesterday \(time)" }
        return session.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var fullDateText: String {
        "\(session.createdAt.formatted(date: .complete, time: .shortened)) \u{00B7} \(session.languageCode)"
    }

    private var durationText: String? {
        let seconds = playback.duration > 0 ? playback.duration : (session.duration ?? 0)
        guard seconds >= 1 else { return nil }
        if seconds < 60 { return "\(Int(seconds)) s" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

// MARK: - Talk bar

private struct SpeakerTalkBar: View {
    let model: RecordingSpeakerModel

    private var total: TimeInterval { model.talk.reduce(0) { $0 + $1.seconds } }
    /// Largest share first, in the bar and in the legend, so both read the same way.
    private var sorted: [TranscriptSpeakerSummary.TalkTime] { model.talk.sorted { $0.seconds > $1.seconds } }

    var body: some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(sorted, id: \.speaker) { entry in
                            Rectangle()
                                .fill(segmentColor(entry.speaker))
                                .frame(width: max(2, (geometry.size.width - CGFloat(model.talk.count - 1) * 2)
                                    * entry.seconds / total))
                                .help("\(entry.speaker): \(percent(entry.seconds))%, about \(minutes(entry.seconds))")
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())

                HStack(spacing: 10) {
                    ForEach(sorted.prefix(4), id: \.speaker) { entry in
                        HStack(spacing: 4) {
                            Circle().fill(segmentColor(entry.speaker)).frame(width: 6, height: 6)
                            Text("\(firstName(entry.speaker)) \(percent(entry.seconds))%")
                        }
                    }
                    if model.talk.count > 4 {
                        Text("+\(model.talk.count - 4)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    /// Generated labels are unfinished: drawn faint, so an unnamed speaker is never the loudest
    /// segment.
    private func segmentColor(_ speaker: String) -> Color {
        let color = model.color(of: speaker)
        return model.kind(of: speaker) == .unnamed ? color.opacity(0.35) : color
    }

    private func firstName(_ speaker: String) -> String {
        SpeakerRenaming.isGenerated(speaker) ? speaker : String(speaker.split(separator: " ").first ?? "")
    }

    private func percent(_ seconds: TimeInterval) -> Int { Int((seconds / total * 100).rounded()) }

    private func minutes(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int((seconds / 60).rounded())) min"
    }
}

// MARK: - Speaker preview

private struct SpeakerTurnRow: View {
    let turn: TranscriptSpeakerSummary.Turn
    let model: RecordingSpeakerModel
    let ownName: String?
    let playback: SessionAudioPlayback

    @State private var isHoveringTime = false

    var body: some View {
        let kind = model.kind(of: turn.speaker)
        let color = model.color(of: turn.speaker)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                SpeakerAvatar(initials: SpeakerPalette.initials(for: turn.speaker, ownName: ownName), kind: kind, size: 22)
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(kind == .unnamed ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let timestamp = turn.timestamp {
                    timeChip(timestamp)
                }
            }
            HStack(spacing: 0) {
                Rectangle()
                    .fill(color.opacity(0.35))
                    .frame(width: 2)
                Text(turn.text)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The rail is as tall as the text, not as tall as the row offers.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 10)
        }
    }

    /// "You" shows the own name when one is set.
    private var displayName: String {
        if turn.speaker == TranscriptFormatting.localSpeaker, let ownName, !ownName.isEmpty { return ownName }
        return turn.speaker
    }

    private func timeChip(_ timestamp: String) -> some View {
        let canPlay = playback.hasAudio && turn.startSeconds != nil
        return Button {
            if let start = turn.startSeconds { playback.play(from: start) }
        } label: {
            Text(isHoveringTime && canPlay ? "\u{25B6} \(timestamp)" : timestamp)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(
                    isHoveringTime && canPlay ? AnyShapeStyle(Color.accentColor)
                        : canPlay ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .onHover { isHoveringTime = $0 }
        .help(canPlay ? "Play from \(timestamp)" : timestamp)
    }
}

/// A round avatar with initials: filled in the speaker's colour, dashed for generated labels.
struct SpeakerAvatar: View {
    let initials: String
    let kind: SpeakerPalette.Kind
    var size: CGFloat = 22

    var body: some View {
        let color = SpeakerPalette.color(for: kind)
        ZStack {
            if kind == .unnamed {
                // Filled underneath, so an overlapping avatar in a stack does not show through.
                Circle().fill(Color(nsColor: .controlBackgroundColor))
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
            } else {
                Circle().fill(color)
            }
            Text(initials)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(kind == .unnamed ? color : SpeakerPalette.avatarText)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(2)
        }
        .frame(width: size, height: size)
    }
}
