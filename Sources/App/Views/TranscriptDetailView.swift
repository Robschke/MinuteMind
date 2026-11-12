// Purpose: Reading, searching, editing and copying a session's transcript inside the app, with the
//          recording's audio alongside it — replaces handing the .txt to TextEdit.
// Dependencies: Sources/App/Transcription/TranscriptDocument.swift (line parsing),
//               Sources/App/Components/SessionAudioPlayer.swift (transport),
//               Sources/App/ViewModels/AppViewModel.swift (updateTranscriptText),
//               Sources/App/Components/ResizableSheet.swift,
//               Sources/App/Views/SpeakerNamingSheet.swift (opened from the speaker chips),
//               Sources/App/Components/SpeakerPalette.swift (speaker colours, shared with the cards)
// RBAC: None.
// Dependents: Sources/App/Components/SessionActions.swift (Transcript button)
// Notes: Two modes on purpose. Reading is the common case and gets a laid-out view — timestamps and
//        speaker names as their own columns, a colour per speaker, click a line to hear it. Editing
//        is the rare case and gets a plain monospaced TextEditor over the raw file format, because
//        that is the format the rest of the app parses; a rich editor would invite edits that break
//        the "[MM:SS] Speaker:" prefixes every downstream feature depends on.
//        Edits are only written on Save, so leaving the sheet never changes the transcript. Save is
//        disabled while nothing has changed, which also makes "did I change anything?" answerable.
//        In reading mode the whole line is a hit target: clicking anywhere in it moves the playhead
//        there and starts playing. A tap gesture only fires without movement, so dragging still
//        selects text.
//        Speaker naming is reachable from the reader itself, because the transcript is where one
//        notices "Speaker 2" and wants to fix it: the speaker chips open the naming sheet with
//        that speaker's field focused, and a "Name Speakers" button sits at the end of the row.
//        The button counts speakers still on a generated label and is tinted while any remain,
//        because "3 unnamed" is the prompt to act; once all are named it quietly reads "Rename".

import AppKit
import SwiftUI

struct TranscriptDetailView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    let session: RecordingSession

    @State private var isEditing = false
    @State private var draft = ""
    @State private var search = ""
    @State private var playback = SessionAudioPlayback()
    @State private var didCopy = false
    @State private var hoveredLineID: Int?
    @State private var showSpeakerNaming = false
    @State private var namingFocus: String?
    @State private var hoveredChip: String?
    /// Speaker colours shared with the recording cards; recomputed only when the transcript or
    /// the own name changes, not per row.
    @State private var speakerKinds: [String: SpeakerPalette.Kind] = [:]

    /// The session as it currently is in the store, not the copy captured when the sheet opened —
    /// otherwise saving an edit (or running Polish) would leave the reader showing stale text.
    private var liveSession: RecordingSession {
        viewModel.sessions.first { $0.id == session.id } ?? session
    }

    private var transcriptText: String {
        liveSession.transcript?.text ?? ""
    }

    private var lines: [TranscriptLine] {
        TranscriptDocument.parse(transcriptText)
    }

    private var visibleLines: [TranscriptLine] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return lines }
        return lines.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || ($0.speaker?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var speakers: [String] {
        TranscriptDocument.speakers(in: lines)
    }

    private var hasChanges: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != transcriptText
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if playback.hasAudio {
                SessionAudioPlayerView(playback: playback)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                Divider()
            }

            if isEditing {
                editor
            } else {
                reader
            }

            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .resizableSheet()
        .onAppear {
            draft = transcriptText
            playback.configure(
                micURL: viewModel.audioURL(for: session, channel: .microphone),
                systemURL: viewModel.audioURL(for: session, channel: .system))
        }
        .onDisappear { playback.stop() }
        .task(id: transcriptText + "\u{0}" + (viewModel.ownSpeakerName ?? "")) {
            speakerKinds = SpeakerPalette.assign(speakers, ownName: viewModel.ownSpeakerName)
        }
        .sheet(isPresented: $showSpeakerNaming) {
            SpeakerNamingSheet(session: liveSession, focusLabel: namingFocus)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(liveSession.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(metaDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if !speakers.isEmpty && !isEditing {
                HStack(spacing: 6) {
                    ForEach(speakers, id: \.self) { speaker in
                        speakerChip(speaker)
                    }
                    Spacer()

                    if !nameableLabels.isEmpty {
                        Button {
                            openSpeakerNaming(focus: nil)
                        } label: {
                            Label(
                                unnamedCount > 0 ? "Name Speakers (\(unnamedCount) unnamed)" : "Rename Speakers",
                                systemImage: "person.2.badge.gearshape")
                        }
                        .controlSize(.small)
                        .tint(unnamedCount > 0 ? .accentColor : nil)
                        .buttonStyle(.bordered)
                        .help("Listen to each voice and put a name to it")
                    }
                }
            }

            if !isEditing {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search this transcript", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Text("\(visibleLines.count) of \(lines.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding()
    }

    /// Labels as the transcript shows them that the naming sheet can rename ("Me" is not one).
    private var nameableLabels: Set<String> {
        Set(viewModel.nameableSpeakers(for: liveSession).map(\.displayLabel))
    }

    /// Speakers still carrying a generated label ("Speaker 2", "Other"): the reason to name at all,
    /// so the button counts them instead of reading like a setting.
    private var unnamedCount: Int {
        viewModel.nameableSpeakers(for: liveSession).filter { profile in
            profile.name == nil && SpeakerRenaming.isGenerated(profile.label)
        }.count
    }

    /// A chip doubles as a shortcut into naming that one speaker; chips that cannot be renamed stay
    /// plain text so they do not look clickable.
    @ViewBuilder
    private func speakerChip(_ speaker: String) -> some View {
        let isNameable = nameableLabels.contains(speaker)
        let isHovered = isNameable && hoveredChip == speaker

        let chip = HStack(spacing: 3) {
            Text(speaker)
            if isHovered {
                Image(systemName: "pencil")
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color(for: speaker).opacity(isHovered ? 0.28 : 0.15), in: Capsule())
        .foregroundStyle(color(for: speaker))

        if isNameable {
            Button {
                openSpeakerNaming(focus: speaker)
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    hoveredChip = speaker
                    NSCursor.pointingHand.push()
                } else {
                    if hoveredChip == speaker { hoveredChip = nil }
                    NSCursor.pop()
                }
            }
            .help("Name \(speaker)")
        } else {
            chip
        }
    }

    /// The reader's audio and the sheet's voice samples would play over each other, so the reader
    /// pauses first.
    private func openSpeakerNaming(focus: String?) {
        playback.pause()
        namingFocus = focus
        showSpeakerNaming = true
    }

    private var metaDescription: String {
        var parts = [liveSession.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = liveSession.duration, duration > 0 {
            parts.append("\(Int((duration / 60).rounded()))min")
        }
        parts.append("\(TranscriptDocument.wordCount(lines)) words")
        return parts.joined(separator: " · ")
    }

    // MARK: - Reading

    private var reader: some View {
        Group {
            if lines.isEmpty {
                emptyState
            } else if visibleLines.isEmpty {
                VStack(spacing: 6) {
                    Text("No lines match “\(search)”.")
                        .font(.subheadline)
                    Button("Clear search") { search = "" }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleLines) { line in
                            lineRow(line)
                        }
                    }
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func lineRow(_ line: TranscriptLine) -> some View {
        let isCurrent = isPlaying(line)
        let isHovered = hoveredLineID == line.id
        let canJump = canJump(to: line)

        HStack(alignment: .top, spacing: 10) {
            // The timestamp doubles as the jump affordance: on hover it turns into a play glyph, so
            // the row reads as clickable without adding a button to every line.
            ZStack(alignment: .leading) {
                Text(line.timestamp ?? "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .opacity(isHovered && canJump ? 0 : 1)

                if isHovered && canJump {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if let speaker = line.speaker {
                    HStack(spacing: 5) {
                        Text(speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(for: speaker))
                        if let flag = line.languageFlag {
                            Text(flag).font(.caption2)
                        }
                    }
                }
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(line.isSpoken ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(rowBackground(isCurrent: isCurrent, isHovered: isHovered && canJump))
        // Hit-test the whole row, not just its text, so anywhere in the line jumps the audio.
        .contentShape(Rectangle())
        .onTapGesture { jump(to: line) }
        .onHover { hovering in
            if hovering {
                hoveredLineID = line.id
            } else if hoveredLineID == line.id {
                hoveredLineID = nil
            }
        }
        .help(canJump ? "Jump to \(line.timestamp ?? "this moment")" : "")
    }

    private func rowBackground(isCurrent: Bool, isHovered: Bool) -> Color {
        if isCurrent { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color.primary.opacity(0.05) }
        return .clear
    }

    /// A line can be jumped to when there is audio and the line carries a usable timestamp.
    private func canJump(to line: TranscriptLine) -> Bool {
        playback.hasAudio && line.startSeconds != nil
    }

    /// Moves the playhead to this line and starts playing.
    ///
    /// Clicking a line means "let me hear this part" — seeking without playing would leave a paused
    /// reader looking like nothing happened. When audio is already running it simply moves.
    private func jump(to line: TranscriptLine) {
        guard let seconds = line.startSeconds, playback.hasAudio else { return }
        if playback.isPlaying {
            playback.seek(to: seconds)
        } else {
            playback.play(from: seconds)
        }
    }

    /// True for the line whose time range contains the playhead — the reader follows the audio.
    private func isPlaying(_ line: TranscriptLine) -> Bool {
        guard playback.isPlaying, let start = line.startSeconds else { return false }
        let next = lines.first { ($0.startSeconds ?? 0) > start }?.startSeconds ?? .greatestFiniteMagnitude
        return playback.currentTime >= start && playback.currentTime < next
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("This recording has no transcript yet.")
                .font(.subheadline)
            Text("Use the Transcribe button on the recording to create one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keep each line's “[MM:SS] Speaker:” prefix — speaker naming, AI polish and the export rely on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if isEditing {
                Button("Cancel") {
                    draft = transcriptText
                    isEditing = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Changes") {
                    viewModel.updateTranscriptText(draft, for: liveSession)
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
            } else {
                Button {
                    copyTranscript()
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .disabled(transcriptText.isEmpty)

                Button {
                    draft = transcriptText
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(transcriptText.isEmpty)

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    /// Copies what is on screen: the filtered lines when a search is active, everything otherwise.
    private func copyTranscript() {
        let text =
            search.trimmingCharacters(in: .whitespaces).isEmpty
            ? transcriptText
            : visibleLines.map { line in
                [line.timestamp.map { "[\($0)]" }, line.speaker.map { "\($0):" }, line.text]
                    .compactMap { $0 }.joined(separator: " ")
            }.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            didCopy = false
        }
    }

    // MARK: - Speaker colours

    /// The speaker's colour from SpeakerPalette, the same as on the recording cards.
    private func color(for speaker: String) -> Color {
        SpeakerPalette.color(
            for: speakerKinds[speaker] ?? .person(slot: SpeakerPalette.preferredSlot(for: speaker)))
    }
}
