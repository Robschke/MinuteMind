// Purpose: InboxView, the triage list of meetings that still need processing (Claude cleanup,
//          summary, knowledge): everything recorded since the inbox exists, from "transcribing"
//          through "ready" and "processing" to "failed", plus the skipped ones behind a filter.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (inboxSessions, skippedInboxSessions,
//               processingStage, processMeeting, processAllInbox, stopProcessingAll,
//               cancelProcessing, dismissFromInbox, restoreToInbox, assignSessionToProject),
//               Sources/App/Components/DesignSystem.swift
// Used by: Sources/App/Views/ContentView.swift (detail for the sidebar's Inbox entry)
// Notes: Built from design review 1 (2a.1 to 2a.10): dense rows instead of transcript cards;
//        "Skip" (not "Dismiss") keeps the meeting and offers Undo for 5 s; Process All shows its
//        count, runs serially and can be stopped; processing shows steps, not a percentage; a
//        processed row says "Processed · Open Summary" for 3 s before it leaves. Unassigned
//        meetings get an inline project menu instead of a blocking dialog, so processing never
//        needs an extra step. Keyboard: Cmd+Return processes, Delete skips the selected row.
//        2026-10-13 (MeetingProcessingRule): a meeting is processed once it has a project, so an
//        unassigned row has no Process button; "Choose project" in its meta line is the action
//        (General included). A project picked here processes at once (2026-10-27: processing no
//        longer waits for speaker names).
//        Process All takes only rows with a project.

import SwiftUI

struct InboxView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow

    enum Filter: String, CaseIterable { case toProcess = "To Process", skipped = "Skipped" }

    @State private var filter: Filter = .toProcess
    @State private var selection: UUID?
    @State private var undo: (id: UUID, title: String)?
    @State private var undoTask: Task<Void, Never>?
    @State private var confirmBatch = false

    private var rows: [RecordingSession] {
        filter == .toProcess ? viewModel.inboxSessions : viewModel.skippedInboxSessions
    }

    private var idleRows: [RecordingSession] {
        viewModel.inboxSessions.filter { viewModel.processingStage[$0.id] == nil && !viewModel.recentlyProcessed.contains($0.id) }
    }

    /// Rows Process All takes: everything with a project, including rows waiting for names.
    private var readyCount: Int { idleRows.filter(\.hasProcessingTarget).count }

    /// Rows Process All leaves out until they get a project.
    private var unassignedCount: Int { idleRows.filter { !$0.hasProcessingTarget }.count }

    private var unassignedNote: String {
        unassignedCount == 1 ? "1 meeting without a project" : "\(unassignedCount) meetings without a project"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .overlay(alignment: .bottom) { undoToast }
        .confirmationDialog("Process \(readyCount) meetings?", isPresented: $confirmBatch, titleVisibility: .visible) {
            Button("Process \(readyCount)") { viewModel.processAllInbox() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Claude cleans up each transcript, then writes the summary and adds it to knowledge."
                 + (unassignedCount > 0 ? " \(unassignedNote) \(unassignedCount == 1 ? "stays" : "stay") in the Inbox." : ""))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Inbox")
                .font(DesignSystem.Typography.title3)
            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            Spacer()
            if let batch = viewModel.inboxBatch {
                ProgressView().controlSize(.small)
                Text(viewModel.inboxBatchStopping
                     ? "Stopping after the current meeting\u{2026}"
                     : "Processing \(min(batch.done + 1, batch.total)) of \(batch.total)")
                    .font(DesignSystem.Typography.footnote)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Button("Stop") { viewModel.stopProcessingAll() }
                    .disabled(viewModel.inboxBatchStopping)
            } else if filter == .toProcess, readyCount > 0 {
                Button("Process All (\(readyCount))") {
                    readyCount > 5 ? (confirmBatch = true) : viewModel.processAllInbox()
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help(unassignedCount > 0 ? "\(unassignedNote) \(unassignedCount == 1 ? "is" : "are") left out" : "Process every meeting with a project")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            ForEach(rows) { session in
                InboxRow(
                    session: session,
                    isSelected: selection == session.id,
                    isSkipped: filter == .skipped,
                    onProcess: { viewModel.processMeeting(session.id) },
                    onSkip: { skip(session) },
                    onRestore: { viewModel.restoreToInbox(session.id) },
                    onCancel: { viewModel.cancelProcessing(session.id) },
                    onOpenSummary: { openWindow(id: "meeting-minutes", value: session.id) })
                .tag(session.id)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .listStyle(.inset)
        .animation(DesignSystem.Animation.smooth, value: rows.map(\.id))
        .onKeyPress(.delete) {
            guard filter == .toProcess, let id = selection, let session = rows.first(where: { $0.id == id }) else { return .ignored }
            skip(session)
            return .handled
        }
        .background {
            Button("") {
                if let id = selection { viewModel.processMeeting(id) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .hidden()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text(filter == .toProcess ? "All caught up" : "Nothing skipped")
                .font(.system(size: 15, weight: .medium))
            Text(filter == .toProcess
                 ? "Meetings you record wait here until they're processed."
                 : "Meetings you skip stay here, so you can still process them later.")
                .font(DesignSystem.Typography.footnote)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Skip with undo

    private func skip(_ session: RecordingSession) {
        viewModel.dismissFromInbox(session.id)
        undo = (session.id, session.title)
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { undo = nil }
        }
    }

    @ViewBuilder
    private var undoToast: some View {
        if let undo {
            HStack(spacing: 12) {
                Text("Skipped \(undo.title)")
                    .lineLimit(1)
                Button("Undo") {
                    viewModel.restoreToInbox(undo.id)
                    self.undo = nil
                }
                .keyboardShortcut("z", modifiers: .command)
            }
            .font(DesignSystem.Typography.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Row

private struct InboxRow: View {
    @Environment(AppViewModel.self) private var viewModel
    let session: RecordingSession
    let isSelected: Bool
    let isSkipped: Bool
    let onProcess: () -> Void
    let onSkip: () -> Void
    let onRestore: () -> Void
    let onCancel: () -> Void
    let onOpenSummary: () -> Void

    @State private var hovering = false

    /// Untitled recordings are named after their start time, which the meta line already shows.
    private var isAutoTitle: Bool {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return [0, -60, 60].contains { formatter.string(from: session.createdAt.addingTimeInterval($0)) == session.title }
    }

    private var displayTitle: String {
        isAutoTitle ? (session.calendarEventTitle ?? "Untitled meeting") : session.title
    }

    private var project: Project? {
        guard let id = session.projectID else {
            return session.assignedToGeneral == true ? ProjectRepositoryService.generalProject : nil
        }
        return viewModel.projects.first { $0.id == id }
    }
    /// Why the transcribed meeting is not processing yet: no project, or unnamed speakers.
    private var stage: AppViewModel.ProcessingStage? { viewModel.processingStage[session.id] }
    private var processed: Bool { viewModel.recentlyProcessed.contains(session.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            projectMarker
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isAutoTitle && session.calendarEventTitle == nil ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                metaLine
                statusLine
            }
            Spacer(minLength: 12)
            actions
                .frame(minWidth: 170, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Process") { onProcess() }
                .disabled(stage != nil || processed || !session.hasProcessingTarget)
            if isSkipped { Button("Move to Inbox", action: onRestore) } else { Button("Skip", action: onSkip) }
        }
    }

    private var projectMarker: some View {
        Group {
            if let project {
                Circle().fill(Color(hex: project.colorHex)).frame(width: 8, height: 8)
            } else {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
        .frame(width: 12)
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            Text(Self.meta(for: session))
            Text("\u{00B7}")
            Menu {
                Button("No Project") { viewModel.assignSessionToProject(session, projectID: nil) }
                Divider()
                // Filing to General counts as a project (MeetingProcessingRule).
                Button(ProjectRepositoryService.generalProject.name) {
                    viewModel.assignSessionToProject(session, projectID: ProjectRepositoryService.generalProjectID)
                }
                Divider()
                ForEach(viewModel.projects) { project in
                    Button(project.name) { viewModel.assignSessionToProject(session, projectID: project.id) }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(project?.name ?? "Choose project")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .foregroundStyle(project == nil ? Color.accentColor : DesignSystem.Colors.textSecondary)
            .fixedSize()
            .accessibilityLabel(project.map { "Project: \($0.name)" } ?? "Choose project")
        }
        .font(DesignSystem.Typography.caption1)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if processed {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DesignSystem.Colors.success)
                    Text("Processed")
                    Button("Open Summary", action: onOpenSummary).buttonStyle(.link)
                }
            } else if let stage {
                StepStrip(stage: stage)
            } else if session.status == .transcribing || isQueued {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(queueText)
                }
            } else if session.status == .failed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DesignSystem.Colors.warning)
                    Text(session.lastErrorMessage ?? "Transcription failed")
                }
            } else if session.status == .recorded {
                Text("Not transcribed yet")
            } else {
                Text(Self.preview(for: session))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(DesignSystem.Colors.textTertiary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var actions: some View {
        let showAll = isSelected || hovering
        HStack(spacing: 8) {
            if processed {
                EmptyView()
            } else if stage != nil {
                Button(action: onCancel) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Cancel processing")
            } else if isSkipped {
                Button("Move to Inbox", action: onRestore)
                    .controlSize(.small)
                    .opacity(showAll ? 1 : 0)
            } else {
                Button("Skip", action: onSkip)
                    .buttonStyle(.borderless)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .help("Keep the meeting without processing it")
                    .opacity(showAll ? 1 : 0)
                if session.status == .failed {
                    Button("Retry", action: onProcess)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .opacity(showAll ? 1 : 0)
                } else if session.hasProcessingTarget {
                    Button("Process", action: onProcess)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .opacity(showAll ? 1 : 0)
                }
            }
        }
        .font(DesignSystem.Typography.footnote)
    }

    private var isQueued: Bool {
        viewModel.transcriptionQueue.jobs.contains { $0.sessionID == session.id && $0.status == .pending }
    }

    private var queueText: String {
        let pending = viewModel.transcriptionQueue.jobs.filter { $0.status == .pending }
        if let index = pending.firstIndex(where: { $0.sessionID == session.id }) {
            return index == 0 ? "Queued, next up" : "Queued \u{00B7} \(index) ahead"
        }
        return "Transcribing\u{2026}"
    }

    /// "Tue 30 Sep, 10:00 · 3 h 14 min", in English like the rest of the UI.
    private static func meta(for session: RecordingSession) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE d MMM, HH:mm"
        var parts = [formatter.string(from: session.createdAt)]
        if let duration = session.duration {
            let minutes = max(1, Int((duration / 60).rounded()))
            parts.append(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Speakers plus the first real sentence, which says more than "Hi, can you hear me?".
    private static func preview(for session: RecordingSession) -> String {
        let speakers = (session.speakerProfiles ?? []).compactMap(\.name)
        let text = session.transcript?.text ?? ""
        let sentence = text
            .components(separatedBy: "\n")
            .map { line -> String in
                // Drop the "[MM:SS] Speaker:" prefix.
                guard let colon = line.firstIndex(of: "]").flatMap({ line[$0...].firstIndex(of: ":") }) else { return line }
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            .first { $0.split(separator: " ").count > 8 } ?? text
        let people = speakers.isEmpty ? "" : (speakers.prefix(2).joined(separator: ", ") + (speakers.count > 2 ? ", +\(speakers.count - 2)" : "") + ": ")
        return people + sentence
    }
}

/// "✓ Cleaned up · ◌ Summarizing · Knowledge": done, current, pending.
private struct StepStrip: View {
    let stage: AppViewModel.ProcessingStage

    private static let steps: [(AppViewModel.ProcessingStage, String)] = [
        (.cleaningUp, "Clean up"), (.summarizing, "Summary"), (.extractingKnowledge, "Knowledge"),
    ]

    var body: some View {
        if stage == .queued {
            Text("Waiting\u{2026}")
        } else if stage == .waitingForTranscript {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Will process after transcription")
            }
        } else {
            let current = Self.steps.firstIndex { $0.0 == stage } ?? 0
            HStack(spacing: 6) {
                ForEach(Self.steps.indices, id: \.self) { index in
                    if index > 0 { Text("\u{00B7}") }
                    HStack(spacing: 3) {
                        if index < current {
                            Image(systemName: "checkmark").font(.system(size: 10))
                        } else if index == current {
                            ProgressView().controlSize(.mini)
                        }
                        Text(Self.steps[index].1)
                    }
                    .foregroundStyle(index == current ? DesignSystem.Colors.textPrimary : index < current ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textTertiary)
                }
            }
        }
    }
}
