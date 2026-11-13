// Purpose: AllTranscriptsView, the main page when no project is selected: header, the recording
//          card (name, project, status, Live and Record) and the list of all transcripts.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (recording, live transcription, queue,
//               recordingStartBlockingProject, selectMicrophone), Sources/App/Audio/AudioDeviceManager.swift,
//               Sources/App/Views/ProjectSettingsSheet.swift ("Set Up…")
// Used by: Sources/App/Views/ContentView.swift (detail column)
// Notes: Recording card decisions (2026-10-05, with the user and a design review): two fixed rows,
//        no field labels, short button labels (Record/Stop, Live/Stop Live) that keep their width,
//        one status line with a fixed height (timer and microphone menu while recording, "Set Up…"
//        when the project has no export folder), live preview fixed at about four lines. Device
//        pickers moved to Settings, Audio. The page must never be wider than the detail column:
//        NavigationSplitView centres overflow, which slides the page under the sidebar.

import AVFoundation
import CoreAudio
import SwiftUI

/// The main transcripts view showing all recordings (when no project is selected)
struct AllTranscriptsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    /// True while audio files are hovering over the transcripts list during a drag.
    @State private var isDropTargeted = false
    /// The project whose settings "Set Up…" opened from a blocked status line.
    @State private var projectForSettings: Project?

    var body: some View {
        @Bindable var viewModel = viewModel
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingXXL) {
                    header
                    controlsContainer
                }
                .padding(DesignSystem.Dimensions.spacingXXXL)
                .padding(.bottom, DesignSystem.Dimensions.spacingL)

                Divider()
                    .overlay(DesignSystem.Colors.divider)

                // No bottom padding: the list runs to the window edge.
                transcriptsSection
                    .padding(.horizontal, DesignSystem.Dimensions.spacingXXXL)
                    .padding(.top, DesignSystem.Dimensions.spacingXXL)
            }
        }
        .sheet(item: $projectForSettings) { project in
            ProjectSettingsSheet(project: project)
                .environment(viewModel)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("Call Transcription")
                .font(DesignSystem.Typography.largeTitle)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: DesignSystem.Dimensions.spacingL)

            HStack(spacing: DesignSystem.Dimensions.spacingL) {
                Toggle(
                    isOn: Binding(
                        get: { viewModel.meetingDetectionEnabled },
                        set: { newValue in
                            viewModel.setMeetingDetection(newValue)
                            if newValue {
                                viewModel.showTeamsConsentInfo = true
                            }
                        }
                    )
                ) {
                    Label("Detect Meetings", systemImage: "video.fill")
                        .font(DesignSystem.Typography.callout)
                }
                .toggleStyle(.switch)
                .fixedSize()
                .help("Detect calls in Teams, Zoom, Meet, Webex, Slack and FaceTime and offer to record them")
            }
        }
    }

    /// Two rows that exist in every state: name and project on top, status and buttons below.
    /// Only the name field stretches with the window, and states only swap what sits inside the
    /// fixed slots, so the card neither reflows on a sidebar drag nor jumps when recording starts.
    private var controlsContainer: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingM) {
            HStack(spacing: DesignSystem.Dimensions.spacingM) {
                TextField("Name (auto: date and time)", text: $viewModel.pendingSessionTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignSystem.Typography.body)
                    .frame(minWidth: 160, maxWidth: .infinity)
                    .help("Optional. Left empty, the recording is named with its date and time")

                Picker("Project", selection: $viewModel.pendingProjectID) {
                    Text("No project").tag(nil as UUID?)
                    Divider()
                    Text(ProjectRepositoryService.generalProject.name).tag(ProjectRepositoryService.generalProjectID as UUID?)
                    Divider()
                    ForEach(viewModel.projects) { project in
                        Text(project.name).tag(project.id as UUID?)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .help("Assign the recording to a project: transcripts and summaries are then exported to its folder")
            }

            HStack(spacing: DesignSystem.Dimensions.spacingM) {
                statusLine
                    .font(DesignSystem.Typography.callout)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)

                recordButtons
            }

            if viewModel.isLiveTranscribing {
                livePreview
                    .transition(.opacity)
            }
        }
        .animation(DesignSystem.Animation.smooth, value: viewModel.isLiveTranscribing)
        .padding(DesignSystem.Dimensions.spacingXXL)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadiusLarge)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadiusLarge)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        .shadow(
            color: DesignSystem.Shadows.soft.color,
            radius: DesignSystem.Shadows.soft.radius,
            x: DesignSystem.Shadows.soft.x,
            y: DesignSystem.Shadows.soft.y
        )
    }

    private var recordButtons: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingM) {
            Button {
                Task {
                    if viewModel.isLiveTranscribing {
                        await viewModel.stopLiveTranscription()
                    } else {
                        do {
                            _ = try await viewModel.startLiveTranscription()
                        } catch {
                            viewModel.errorMessage = error.localizedDescription
                        }
                    }
                }
            } label: {
                stableLabel(
                    isActive: viewModel.isLiveTranscribing,
                    idle: ("Live", "text.bubble"),
                    active: ("Stop Live", "stop.circle.fill")
                )
                .font(DesignSystem.Typography.callout.weight(.medium))
            }
            .keyboardShortcut("l", modifiers: .command)
            .buttonStyle(.bordered)
            .help(viewModel.isLiveTranscribing ? "Stop live transcription (⌘L)" : "Start live transcription (⌘L)")

            Button {
                Task {
                    if viewModel.isRecording {
                        await viewModel.stopRecording()
                    } else {
                        await viewModel.startRecording()
                    }
                }
            } label: {
                stableLabel(
                    isActive: viewModel.isRecording,
                    idle: ("Record", "record.circle"),
                    active: ("Stop", "stop.circle.fill")
                )
                .font(DesignSystem.Typography.callout.weight(.semibold))
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.isRecording && viewModel.recordingStartBlockReason() != nil)
            .help(viewModel.isRecording ? "Stop recording (Space)" : "Start recording (Space)")
        }
        .fixedSize()
    }

    /// Lays out both labels and shows one, so a button keeps the width of its longer label and
    /// pressing it never moves anything next to it.
    private func stableLabel(
        isActive: Bool, idle: (title: String, icon: String), active: (title: String, icon: String)
    ) -> some View {
        ZStack {
            Label(idle.title, systemImage: idle.icon)
                .opacity(isActive ? 0 : 1)
                .accessibilityHidden(isActive)
            Label(active.title, systemImage: active.icon)
                .opacity(isActive ? 1 : 0)
                .accessibilityHidden(!isActive)
        }
    }

    /// One line in a fixed-height slot. Most urgent state wins: recording, live, a blocked project
    /// (it explains the disabled Record button), transcription, waveform, import, ready.
    @ViewBuilder
    private var statusLine: some View {
        if viewModel.isRecording {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                statusDot(.red)
                Text("Recording")
                    .fontWeight(.medium)
                if let start = viewModel.currentSession?.createdAt {
                    RecordingElapsedText(start: start)
                }
                Text("·")
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                RecordingMicrophoneMenu(deviceManager: viewModel.audioDeviceManager) { deviceID in
                    viewModel.selectMicrophone(deviceID)
                }
            }
        } else if viewModel.isLiveTranscribing {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                statusDot(.orange)
                Text("Live transcribing")
                    .fontWeight(.medium)
            }
        } else if let project = viewModel.recordingStartBlockingProject() {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("“\(project.name)” has no export folder.")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Set Up…") {
                    projectForSettings = project
                }
                .buttonStyle(.link)
                .fixedSize()
            }
            .help(viewModel.recordingStartBlockReason() ?? "")
        } else if viewModel.isTranscribing {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                statusDot(.blue)
                Text(transcribingText)
                    .lineLimit(1)
                Group {
                    if let progress = viewModel.transcriptionProgress {
                        ProgressView(value: Double(progress.current), total: Double(progress.total))
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .frame(width: 120)
                Button("Stop") {
                    viewModel.transcriptionQueue.cancelCurrentJob()
                }
                .buttonStyle(.link)
                .fixedSize()
            }
            .help(transcribingHelp)
        } else if viewModel.isGeneratingWaveform {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                ProgressView()
                    .controlSize(.small)
                Text("Generating waveform…")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Button("Cancel") {
                    viewModel.cancelWaveformGeneration()
                }
                .buttonStyle(.link)
                .fixedSize()
            }
        } else if viewModel.isImportingAudio {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                ProgressView()
                    .controlSize(.small)
                Text("Importing audio…")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        } else {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                statusDot(.green)
                Text("Ready")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var transcribingText: String {
        let pending = viewModel.transcriptionQueue.pendingCount
        if let progress = viewModel.transcriptionProgress {
            return pending > 0
                ? "Transcribing \(progress.current)/\(progress.total), \(pending) queued"
                : "Transcribing \(progress.current)/\(progress.total)"
        }
        return pending > 0 ? "Transcribing, \(pending) queued" : "Transcribing…"
    }

    /// The details that used to sit in their own rows: progress message and the next jobs.
    private var transcribingHelp: String {
        var lines: [String] = []
        if !viewModel.transcriptionProgressMessage.isEmpty {
            lines.append(viewModel.transcriptionProgressMessage)
        }
        let pendingJobs = viewModel.transcriptionQueue.jobs.filter { $0.status == .pending }
        if !pendingJobs.isEmpty {
            lines.append("Up next: " + pendingJobs.prefix(3).map(\.sessionTitle).joined(separator: ", "))
            if pendingJobs.count > 3 {
                lines.append("and \(pendingJobs.count - 3) more")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static let livePreviewBottom = "live-preview-bottom"

    /// Fixed height (about four lines) with the newest line kept in view, so the card does not
    /// grow with every sentence.
    private var livePreview: some View {
        let isEmpty = viewModel.liveTranscriptPreview.isEmpty
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Text(isEmpty ? "Listening…" : viewModel.liveTranscriptPreview)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(
                            isEmpty ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textPrimary
                        )
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignSystem.Dimensions.spacingM)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.livePreviewBottom)
                }
            }
            .frame(height: 100)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                    .fill(Color.orange.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                    .stroke(Color.orange.opacity(0.2), lineWidth: 0.5)
            )
            .onAppear {
                proxy.scrollTo(Self.livePreviewBottom, anchor: .bottom)
            }
            .onChange(of: viewModel.liveTranscriptPreview) {
                proxy.scrollTo(Self.livePreviewBottom, anchor: .bottom)
            }
        }
    }

    private var transcriptsSection: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingL) {
            HStack {
                Text("Transcripts")
                    .font(DesignSystem.Typography.title3)

                if !viewModel.sessions.isEmpty {
                    Text("\(viewModel.sessions.count)")
                        .font(DesignSystem.Typography.callout.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.textTertiary.opacity(0.12))
                        )
                }

                Spacer()

                HStack(spacing: DesignSystem.Dimensions.spacingS) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .font(.system(size: 13))

                    TextField("Search transcripts...", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.body)
                        .frame(maxWidth: 250)

                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DesignSystem.Dimensions.spacingM)
                .padding(.vertical, DesignSystem.Dimensions.spacingS)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                        .fill(DesignSystem.Colors.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                )
            }

            if viewModel.sessions.isEmpty {
                contentPlaceholder
            } else if viewModel.filteredSessions.isEmpty {
                noSearchResultsPlaceholder
            } else {
                ScrollView {
                    LazyVStack(spacing: DesignSystem.Dimensions.spacingL) {
                        ForEach(viewModel.filteredSessions) { session in
                            TranscriptCardWithProject(
                                session: session,
                                projects: viewModel.projects,
                                renameAction: { updatedTitle in
                                    viewModel.renameSession(session, newTitle: updatedTitle)
                                },
                                openTranscriptAction: {
                                    viewModel.openTranscript(session)
                                },
                                micURL: viewModel.audioURL(for: session, channel: .microphone),
                                speakerURL: viewModel.audioURL(for: session, channel: .system),
                                minutesURL: viewModel.minutesURL(for: session),
                                canGenerateMinutes: viewModel.canGenerateMeetingMinutes,
                                isGeneratingMinutes: viewModel.isGeneratingMinutes(for: session),
                                generateMinutesAction: {
                                    // "Process": Claude cleanup, summary and knowledge, same as the pill and the inbox.
                                    viewModel.processMeeting(session.id)
                                },
                                openMinutesAction: {
                                    viewModel.openMinutes(session)
                                },
                                deleteMinutesAction: {
                                    viewModel.deleteMinutes(for: session)
                                },
                                deleteMic: {
                                    viewModel.deleteAudio(for: session, channel: .microphone)
                                },
                                deleteSpeaker: {
                                    viewModel.deleteAudio(for: session, channel: .system)
                                },
                                deleteTranscript: {
                                    viewModel.deleteTranscript(for: session)
                                },
                                deleteSession: {
                                    viewModel.deleteSession(session)
                                },
                                assignToProject: { projectID in
                                    viewModel.assignSessionToProject(session, projectID: projectID)
                                },
                                onError: { message in
                                    viewModel.errorMessage = message
                                },
                                transcriptionProgress: viewModel.transcribingSessionID == session.id ? viewModel.transcriptionProgress : nil,
                                onGenerateWaveform: { channel in
                                    await viewModel.generateWaveform(for: session, channel: channel)
                                },
                                onCropAudio: { startTime, endTime in
                                    await viewModel.cropAudio(sessionID: session.id, startTime: startTime, endTime: endTime)
                                },
                                onRestoreAudio: {
                                    await viewModel.restoreOriginalAudio(sessionID: session.id)
                                },
                                resetTranscription: {
                                    viewModel.resetTranscribingSession(sessionID: session.id)
                                }
                            )
                        }
                    }
                }
            }
        }
        // Drop audio files anywhere on the transcripts list to import them as cards.
        .dropDestination(for: URL.self) { urls, _ in
            let audioURLs = urls.filter(AudioImportService.hasAudioExtension)
            guard !audioURLs.isEmpty else { return false }
            Task { await viewModel.importAudioFiles(audioURLs) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadius)
                    .strokeBorder(
                        DesignSystem.Colors.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadius)
                            .fill(DesignSystem.Colors.accent.opacity(0.06))
                    )
                    .overlay {
                        Label("Drop audio files to import", systemImage: "square.and.arrow.down")
                            .font(DesignSystem.Typography.callout.weight(.medium))
                            .foregroundStyle(DesignSystem.Colors.accent)
                    }
                    .allowsHitTesting(false)
            }
        }
        .animation(DesignSystem.Animation.smooth, value: isDropTargeted)
    }

    private var contentPlaceholder: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingXL) {
            VStack(spacing: DesignSystem.Dimensions.spacingM) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)

                VStack(spacing: DesignSystem.Dimensions.spacingS) {
                    Text("No recordings yet")
                        .font(DesignSystem.Typography.title3)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(
                        "Start a capture to see transcripts appear here, or drop an existing audio file onto this area (File → Import Audio…, ⌘I) to turn it into a transcript card. Sessions run entirely in the background, so you can keep using your Mac without switching audio devices."
                    )
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 480)
                }
            }
        }
        .padding(DesignSystem.Dimensions.spacingXXXL)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadius)
                .fill(DesignSystem.Colors.card.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadius)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
        )
    }

    private var noSearchResultsPlaceholder: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingXL) {
            VStack(spacing: DesignSystem.Dimensions.spacingM) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 42))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)

                VStack(spacing: DesignSystem.Dimensions.spacingS) {
                    Text("No results found")
                        .font(DesignSystem.Typography.title3)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(
                        "No transcripts match \"\(viewModel.searchQuery)\". Try a different search term or clear the search to see all transcripts."
                    )
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 420)
                }

                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Text("Clear Search")
                        .font(DesignSystem.Typography.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DesignSystem.Dimensions.spacingXXXL)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadius)
                .fill(DesignSystem.Colors.card.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadius)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
        )
    }
}

/// A transcript row with project assignment
struct TranscriptCardWithProject: View {
    @Environment(AppViewModel.self) private var viewModel
    let session: RecordingSession
    let projects: [Project]
    let renameAction: (String) -> Void
    let openTranscriptAction: () -> Void
    let micURL: URL?
    let speakerURL: URL?
    let minutesURL: URL?
    let canGenerateMinutes: Bool
    let isGeneratingMinutes: Bool
    let generateMinutesAction: () -> Void
    let openMinutesAction: () -> Void
    let deleteMinutesAction: () -> Void
    let deleteMic: () -> Void
    let deleteSpeaker: () -> Void
    let deleteTranscript: () -> Void
    let deleteSession: () -> Void
    let assignToProject: (UUID?) -> Void
    let onError: (String) -> Void
    let transcriptionProgress: (current: Int, total: Int)?
    let onGenerateWaveform: ((RecordingSession.Channel) async -> AudioProcessor.WaveformData?)?
    let onCropAudio: ((TimeInterval, TimeInterval) async -> Void)?
    let onRestoreAudio: (() async -> Void)?
    let resetTranscription: (() -> Void)?
    /// Owns audio playback for this card: the strip, the waveform and the preview's time chips.
    @State private var playback = SessionAudioPlayback()
    @State private var isRenaming = false
    @State private var isCropping = false

    init(
        session: RecordingSession,
        projects: [Project],
        renameAction: @escaping (String) -> Void,
        openTranscriptAction: @escaping () -> Void,
        micURL: URL?,
        speakerURL: URL?,
        minutesURL: URL?,
        canGenerateMinutes: Bool,
        isGeneratingMinutes: Bool,
        generateMinutesAction: @escaping () -> Void,
        openMinutesAction: @escaping () -> Void,
        deleteMinutesAction: @escaping () -> Void,
        deleteMic: @escaping () -> Void,
        deleteSpeaker: @escaping () -> Void,
        deleteTranscript: @escaping () -> Void,
        deleteSession: @escaping () -> Void,
        assignToProject: @escaping (UUID?) -> Void,
        onError: @escaping (String) -> Void,
        transcriptionProgress: (current: Int, total: Int)? = nil,
        onGenerateWaveform: ((RecordingSession.Channel) async -> AudioProcessor.WaveformData?)? = nil,
        onCropAudio: ((TimeInterval, TimeInterval) async -> Void)? = nil,
        onRestoreAudio: (() async -> Void)? = nil,
        resetTranscription: (() -> Void)? = nil
    ) {
        self.session = session
        self.projects = projects
        self.renameAction = renameAction
        self.openTranscriptAction = openTranscriptAction
        self.micURL = micURL
        self.speakerURL = speakerURL
        self.minutesURL = minutesURL
        self.canGenerateMinutes = canGenerateMinutes
        self.isGeneratingMinutes = isGeneratingMinutes
        self.generateMinutesAction = generateMinutesAction
        self.openMinutesAction = openMinutesAction
        self.deleteMinutesAction = deleteMinutesAction
        self.deleteMic = deleteMic
        self.deleteSpeaker = deleteSpeaker
        self.deleteTranscript = deleteTranscript
        self.deleteSession = deleteSession
        self.assignToProject = assignToProject
        self.onError = onError
        self.transcriptionProgress = transcriptionProgress
        self.onGenerateWaveform = onGenerateWaveform
        self.onCropAudio = onCropAudio
        self.onRestoreAudio = onRestoreAudio
        self.resetTranscription = resetTranscription
    }

    private var currentProject: Project? {
        guard let projectID = session.projectID else {
            return session.assignedToGeneral == true ? ProjectRepositoryService.generalProject : nil
        }
        return projects.first { $0.id == projectID }
    }

    private var hasTranscript: Bool {
        session.transcript?.text.isEmpty == false
    }

    // Card redesign 2026-10-05 ("Speaker Rail"): header with the project chip, meta line,
    // talk bar and speaker preview, then the playback strip and the actions. Shared parts live in
    // RecordingCardParts.swift and SessionPlaybackStrip.swift.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecordingCardHeader(
                session: session,
                transcriptionProgress: session.status == .transcribing ? transcriptionProgress : nil,
                isRenaming: $isRenaming,
                rename: renameAction
            ) {
                projectMenu
            }

            RecordingCardSummary(session: session, playback: playback, ownName: viewModel.ownSpeakerName)

            if !hasTranscript {
                statusLine
            }

            if playback.hasAudio {
                SessionPlaybackStrip(
                    session: session, hasMicrophone: micURL != nil, playback: playback,
                    onGenerateWaveform: onGenerateWaveform, onCropAudio: onCropAudio,
                    isCropping: $isCropping)
            }

            // The bar renders in every state: it carries the overflow menu, and a session with no
            // transcript still needs to be deletable.
            transcriptActions
            extractedItemsSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystem.Colors.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        // Configured on the card, not on the strip: the strip only exists once the player has
        // audio, and SwiftUI never fires onAppear for a view that is not there.
        .onAppear { playback.configure(micURL: micURL, systemURL: speakerURL) }
        .onChange(of: micURL) { _, new in playback.configure(micURL: new, systemURL: speakerURL) }
        .onChange(of: speakerURL) { _, new in playback.configure(micURL: micURL, systemURL: new) }
        .onDisappear { playback.stop() }
    }

    private var projectMenu: some View {
        Menu {
            Button("No Project") {
                assignToProject(nil)
            }
            Divider()
            // Filing to General counts as a project: processing starts (MeetingProcessingRule).
            projectMenuItem(ProjectRepositoryService.generalProject, isCurrent: session.assignedToGeneral == true)
            Divider()
            ForEach(projects) { project in
                projectMenuItem(project, isCurrent: session.projectID == project.id)
            }
        } label: {
            if let project = currentProject {
                HStack(spacing: 4) {
                    ProjectAvatarView(projectID: project.id, pixelSize: 1)
                    Text(project.name)
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(4)
            } else {
                Label("Assign to Project", systemImage: "folder.badge.plus")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func projectMenuItem(_ project: Project, isCurrent: Bool) -> some View {
        Button {
            assignToProject(project.id)
        } label: {
            HStack {
                Text(project.name)
                if isCurrent {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    /// Shown instead of the speaker preview while there is no transcript.
    @ViewBuilder
    private var statusLine: some View {
        if let error = session.lastErrorMessage {
            Text("Transcription failed: \(error)")
                .font(.callout)
                .foregroundStyle(.red)
        } else {
            HStack(spacing: 8) {
                Text(statusPlaceholder)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // A transcription can get stuck; the way out has to stay next to the status.
                if session.status == .transcribing, let reset = resetTranscription {
                    Button {
                        reset()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reset stuck transcription - use this if transcription has been running for too long")
                }
            }
        }
    }

    private var statusPlaceholder: String {
        switch session.status {
        case .recording:
            return "Recording…"
        case .recorded:
            return "Ready to transcribe."
        case .transcribing:
            return "Transcription pending…"
        case .liveTranscribing:
            return "Live transcribing…"
        case .completed:
            return "Transcript will appear here."
        case .failed:
            return "Transcription failed."
        case .idle:
            return "Ready."
        }
    }

    /// One button, one engine: the engine is chosen once in Settings, Automation.
    /// See SessionTranscribeButton for why this replaced four side-by-side engine buttons.
    private var transcriptActions: some View {
        SessionActionBar(
            session: session,
            hasMinutes: minutesURL != nil,
            canGenerateMinutes: canGenerateMinutes,
            isGeneratingMinutes: isGeneratingMinutes,
            canExtractTodos: viewModel.canExtractTodos && session.meetingMinutesFileName != nil,
            isExtractingTodos: viewModel.isExtractingTodos(for: session),
            canExtractKnowledge: session.meetingMinutesFileName != nil,
            isExtractingKnowledge: viewModel.isExtractingKnowledge(for: session),
            hasMic: micURL != nil,
            hasSystemAudio: speakerURL != nil,
            handlers: SessionActionHandlers(
                openTranscript: openTranscriptAction,
                generateMinutes: generateMinutesAction,
                openMinutes: openMinutesAction,
                deleteMinutes: deleteMinutesAction,
                extractTodos: { Task { await viewModel.extractTodosFromMinutes(for: session) } },
                extractKnowledge: { Task { await viewModel.extractKnowledgeFromMinutes(for: session) } },
                deleteMic: deleteMic,
                deleteSpeaker: deleteSpeaker,
                deleteTranscript: deleteTranscript,
                deleteSession: deleteSession,
                rename: { isRenaming = true },
                cropAudio: playback.hasAudio && onCropAudio != nil ? { isCropping = true } : nil,
                restoreAudio: isCropped ? { Task { await onRestoreAudio?() } } : nil))
    }

    private var isCropped: Bool {
        onRestoreAudio != nil && (session.cropStartTime != nil || session.cropEndTime != nil)
    }

    private var extractedItemsSection: some View {
        let sessionTasks = viewModel.tasksForSession(session.id)
        let pendingTasks = sessionTasks.filter { $0.needsReview == true }
        let acceptedTasks = sessionTasks.filter { $0.needsReview != true }

        return Group {
            if !sessionTasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Extracted Items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !pendingTasks.isEmpty {
                            Button {
                                viewModel.acceptAllExtractedTasks(for: session.id, projectID: session.projectID)
                            } label: {
                                Label("Accept All", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    ForEach(pendingTasks) { task in
                        AllTranscriptsExtractedTaskRow(
                            task: task,
                            isPending: true,
                            onAccept: { viewModel.acceptExtractedTask(task, projectID: session.projectID) },
                            onReject: { viewModel.rejectExtractedTask(task) }
                        )
                    }

                    if !acceptedTasks.isEmpty {
                        DisclosureGroup("Accepted tasks (\(acceptedTasks.count))") {
                            ForEach(acceptedTasks) { task in
                                AllTranscriptsExtractedTaskRow(
                                    task: task,
                                    isPending: false,
                                    onAccept: {},
                                    onReject: {}
                                )
                            }
                        }
                        .font(.caption)
                    }

                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Extracted Task Row (AllTranscripts)

private struct AllTranscriptsExtractedTaskRow: View {
    let task: ProjectTask
    let isPending: Bool
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isPending ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(isPending ? .orange : .green)
                .font(.caption)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.caption)
                    .lineLimit(2)
                if let assignee = task.assignee, !assignee.isEmpty {
                    Text(assignee)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let priority = task.priority {
                Text(priority.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(hex: priority.color).opacity(0.2))
                    .cornerRadius(3)
            }

            if isPending {
                Button {
                    onAccept()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Accept task")

                Button {
                    onReject()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Reject task")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isPending ? Color.orange.opacity(0.08) : Color.clear)
        )
    }
}

/// Elapsed time of the running recording, ticking once a second (m:ss, h:mm:ss after an hour).
private struct RecordingElapsedText: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(start)))
                .monospacedDigit()
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// The microphone of the running recording, switchable in place for the "wrong mic mid-call"
/// case. Shown only while recording; otherwise the choice lives in Settings, Audio. Observes the
/// device manager directly, since its @Published changes do not pass through AppViewModel.
private struct RecordingMicrophoneMenu: View {
    @ObservedObject var deviceManager: AudioDeviceManager
    let select: (AudioDeviceID?) -> Void

    private var title: String {
        deviceManager.selectedInputDeviceID == nil ? "System Default" : deviceManager.selectedInputDeviceName
    }

    var body: some View {
        Menu {
            Picker(
                "Microphone",
                selection: Binding(get: { deviceManager.selectedInputDeviceID }, set: { select($0) })
            ) {
                Text("System Default").tag(nil as AudioDeviceID?)
                ForEach(deviceManager.inputDevices) { device in
                    Text(device.name).tag(device.id as AudioDeviceID?)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(title, systemImage: "mic.fill")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 60, maxWidth: 200, alignment: .leading)
        .help("Microphone for this recording")
        .onAppear { deviceManager.refreshDevices() }
    }
}
