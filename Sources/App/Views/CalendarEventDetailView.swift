// Purpose: Event detail sheet — title, date/time, attendees, calendar notes, linked recordings/summaries,
//          editable meeting notes (with tags and optional project link), and auto-record toggle.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift, Sources/App/Services/CalendarService.swift,
//               Sources/App/Services/AutoRecordStore.swift, Sources/App/Models/EventNote.swift,
//               Sources/App/Components/DesignSystem.swift
// RBAC: No access control — user-specific calendar data.
// Notes: Shown as a .sheet from CalendarView; the system provides a close button automatically.
//        Meeting summaries are loaded asynchronously from disk on appear.
//        Notes are saved to AppViewModel.eventNotes on every content/tag change.
//        The project picker lets the user link a note to a project so it appears in ProjectNotesTabView.

import SwiftUI

struct CalendarEventDetailView: View {
    let event: CalendarEvent
    var appViewModel: AppViewModel

    // MARK: - Auto-Record Binding

    private var autoRecordBinding: Binding<Bool> {
        Binding(
            get: { appViewModel.autoRecordStore.isEnabled(for: event.id) },
            set: { try? appViewModel.autoRecordStore.setEnabled($0, for: event.id) }
        )
    }

    // MARK: - State

    @State private var linkedSessions: [RecordingSession] = []
    @State private var minutesTexts: [UUID: String] = [:]
    @State private var expandedSummaries: Set<UUID> = []

    @State private var noteContent: String = ""
    @State private var noteTags: [String] = []
    @State private var noteProjectId: UUID? = nil
    @State private var newTagInput: String = ""
    @State private var showTagField = false
    /// Project assigned to this event/series — recordings go here automatically.
    @State private var eventProjectId: UUID? = nil
    /// Transcription language override for this event/series — nil means use the global default.
    @State private var eventLanguageCode: String? = nil

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Title ──────────────────────────────────────────────
                Text(event.title)
                    .font(DesignSystem.Typography.title2)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .padding(.bottom, DesignSystem.Dimensions.spacingM)

                Divider().overlay(DesignSystem.Colors.divider)
                    .padding(.bottom, DesignSystem.Dimensions.spacingM)

                // ── Date / Time ────────────────────────────────────────
                labelRow(icon: "calendar", text: dateTimeLabel)
                    .padding(.bottom, DesignSystem.Dimensions.spacingM)

                // ── Project Assignment ─────────────────────────────────
                projectAssignmentRow
                    .padding(.bottom, DesignSystem.Dimensions.spacingM)

                // ── Transcription Language ─────────────────────────────
                languageAssignmentRow
                    .padding(.bottom, DesignSystem.Dimensions.spacingM)

                // ── Attendees ──────────────────────────────────────────
                if !event.attendees.isEmpty {
                    labelRow(icon: "person.2", text: event.attendees.joined(separator: ", "))
                        .padding(.bottom, DesignSystem.Dimensions.spacingM)
                }

                // ── Calendar Notes ─────────────────────────────────────
                if let notes = event.notes, !notes.isEmpty {
                    Divider().overlay(DesignSystem.Colors.divider)
                        .padding(.bottom, DesignSystem.Dimensions.spacingM)

                    sectionHeader("Notes", icon: "note.text")
                        .padding(.bottom, DesignSystem.Dimensions.spacingS)

                    Text(notes)
                        .font(DesignSystem.Typography.callout)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignSystem.Dimensions.spacingM)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                                .fill(DesignSystem.Colors.card)
                        )
                        .padding(.bottom, DesignSystem.Dimensions.spacingM)
                }

                // ── Linked Recordings & Summaries ──────────────────────
                if !linkedSessions.isEmpty {
                    Divider().overlay(DesignSystem.Colors.divider)
                        .padding(.bottom, DesignSystem.Dimensions.spacingM)

                    sectionHeader("Recordings", icon: "waveform")
                        .padding(.bottom, DesignSystem.Dimensions.spacingS)

                    ForEach(linkedSessions) { session in
                        recordingRow(for: session)
                            .padding(.bottom, DesignSystem.Dimensions.spacingS)
                    }
                    // small spacer before next section
                    Color.clear.frame(height: DesignSystem.Dimensions.spacingS)
                }

                // ── My Meeting Notes ───────────────────────────────────
                Divider().overlay(DesignSystem.Colors.divider)
                    .padding(.bottom, DesignSystem.Dimensions.spacingM)

                sectionHeader("My Notes", icon: "pencil")
                    .padding(.bottom, DesignSystem.Dimensions.spacingS)

                notesEditor
                    .padding(.bottom, DesignSystem.Dimensions.spacingM)

                // ── Auto-Record Toggle ─────────────────────────────────
                Divider().overlay(DesignSystem.Colors.divider)
                    .padding(.bottom, DesignSystem.Dimensions.spacingM)

                Toggle("Auto-record this meeting", isOn: autoRecordBinding)
                    .font(DesignSystem.Typography.callout)
                    .toggleStyle(.switch)
                    .padding(.bottom, DesignSystem.Dimensions.spacingS)

                Text("If recorded, session will be named: \(event.title)")
                    .font(DesignSystem.Typography.caption1.italic())
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(DesignSystem.Dimensions.spacingXXL)
        }
        .task {
            // Load sessions linked to this event and their meeting minutes
            linkedSessions = appViewModel.sessionsForEvent(event.id)
            for session in linkedSessions {
                if let url = appViewModel.minutesURL(for: session),
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    minutesTexts[session.id] = text
                }
            }
            // Load saved note
            if let existing = appViewModel.note(for: event.id) {
                noteContent = existing.content
                noteTags = existing.tags
                noteProjectId = existing.projectId
            }
            // Load event project assignment
            eventProjectId = appViewModel.projectID(for: event)
            // Load event language override (nil = use global default)
            eventLanguageCode = appViewModel.languageCode(for: event)
        }
        .onChange(of: noteContent) { saveNote() }
        .onChange(of: noteTags) { saveNote() }
        .onChange(of: noteProjectId) { saveNote() }
        .onChange(of: eventProjectId) { newID in
            appViewModel.setEventProject(newID, for: event)
            // When the event project changes, sync the note to the same project if unset.
            if noteProjectId == nil, newID != nil {
                noteProjectId = newID
            }
        }
        .onChange(of: eventLanguageCode) { newCode in
            appViewModel.setEventLanguage(newCode, for: event)
        }
    }

    // MARK: - Project Assignment Row

    private var projectAssignmentRow: some View {
        HStack(alignment: .center, spacing: DesignSystem.Dimensions.spacingS) {
            Image(systemName: "folder")
                .font(.system(size: 14))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Picker("", selection: $eventProjectId) {
                    Text("No project").tag(nil as UUID?)
                    ForEach(appViewModel.projects) { project in
                        Text(project.name).tag(project.id as UUID?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                if event.isRecurring {
                    Text(eventProjectId == nil
                         ? "Assign all occurrences of this series to a project"
                         : "All occurrences of this series → \(projectName(for: eventProjectId))")
                        .font(DesignSystem.Typography.caption2)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }
        }
    }

    private func projectName(for id: UUID?) -> String {
        guard let id else { return "—" }
        return appViewModel.projects.first(where: { $0.id == id })?.name ?? "—"
    }

    // MARK: - Transcription Language Row

    private var languageAssignmentRow: some View {
        HStack(alignment: .center, spacing: DesignSystem.Dimensions.spacingS) {
            Image(systemName: "globe")
                .font(.system(size: 14))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Picker("", selection: $eventLanguageCode) {
                    Text("Default (\(defaultLanguageLabel))").tag(nil as String?)
                    ForEach(AppViewModel.LanguageOption.allCases) { option in
                        Text(option.label).tag(option.rawValue as String?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                if event.isRecurring {
                    Text(eventLanguageCode == nil
                         ? "All occurrences use the default transcription language"
                         : "All occurrences of this series → \(languageLabel(for: eventLanguageCode))")
                        .font(DesignSystem.Typography.caption2)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }
        }
    }

    /// Label of the current global default language, shown in the "Default (…)" picker entry.
    private var defaultLanguageLabel: String {
        (AppViewModel.LanguageOption(rawValue: appViewModel.automationSettings.liveDictationLanguage) ?? .auto).label
    }

    private func languageLabel(for code: String?) -> String {
        guard let code, let option = AppViewModel.LanguageOption(rawValue: code) else {
            return defaultLanguageLabel
        }
        return option.label
    }

    // MARK: - Notes Editor

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingS) {
            TextEditor(text: $noteContent)
                .font(DesignSystem.Typography.callout)
                .frame(minHeight: 120)
                .padding(DesignSystem.Dimensions.spacingS)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                        .fill(DesignSystem.Colors.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                        .stroke(DesignSystem.Colors.divider, lineWidth: 1)
                )

            // Tags row
            HStack(spacing: DesignSystem.Dimensions.spacingXS) {
                Image(systemName: "tag")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)

                ForEach(noteTags, id: \.self) { tag in
                    tagChip(tag)
                }

                if showTagField {
                    TextField("tag name", text: $newTagInput)
                        .font(.system(size: 11))
                        .textFieldStyle(.plain)
                        .frame(width: 80)
                        .onSubmit {
                            addTag()
                        }
                } else {
                    Button {
                        showTagField = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            // Project link
            HStack(spacing: DesignSystem.Dimensions.spacingXS) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)

                Picker("", selection: $noteProjectId) {
                    Text("No project").tag(nil as UUID?)
                    ForEach(appViewModel.projects) { project in
                        Text(project.name).tag(project.id as UUID?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 11))
                .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 3) {
            Text(tag)
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Button {
                noteTags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(DesignSystem.Colors.card)
                .overlay(Capsule().stroke(DesignSystem.Colors.divider, lineWidth: 1))
        )
    }

    // MARK: - Recording Row

    @ViewBuilder
    private func recordingRow(for session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingXS) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 14))
                Text(session.title)
                    .font(DesignSystem.Typography.callout.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                if let text = minutesTexts[session.id], !text.isEmpty {
                    Button {
                        if expandedSummaries.contains(session.id) {
                            expandedSummaries.remove(session.id)
                        } else {
                            expandedSummaries.insert(session.id)
                        }
                    } label: {
                        Label(
                            expandedSummaries.contains(session.id) ? "Hide summary" : "Show summary",
                            systemImage: expandedSummaries.contains(session.id)
                                ? "chevron.up" : "chevron.down"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let createdAt = Optional(session.createdAt) {
                Text(createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }

            if expandedSummaries.contains(session.id), let text = minutesTexts[session.id] {
                Divider().overlay(DesignSystem.Colors.divider)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(DesignSystem.Dimensions.spacingS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                            .fill(DesignSystem.Colors.card)
                    )
            }
        }
        .padding(DesignSystem.Dimensions.spacingS)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                .fill(DesignSystem.Colors.card)
        )
    }

    // MARK: - Subviews

    private func labelRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Dimensions.spacingS) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 18)
            Text(text)
                .font(DesignSystem.Typography.callout)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: DesignSystem.Dimensions.spacingXS) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(title)
                .font(DesignSystem.Typography.subheadline.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private var dateTimeLabel: String {
        let dateStr = event.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if event.isAllDay {
            return "\(dateStr) · All day"
        }
        let startTime = event.startDate.formatted(.dateTime.hour().minute())
        let endTime = event.endDate.formatted(.dateTime.hour().minute())
        return "\(dateStr) · \(startTime) – \(endTime)"
    }

    // MARK: - Persistence

    private func addTag() {
        let trimmed = newTagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !noteTags.contains(trimmed) {
            noteTags.append(trimmed)
        }
        newTagInput = ""
        showTagField = false
    }

    private func saveNote() {
        guard !noteContent.isEmpty || !noteTags.isEmpty else { return }
        var note = appViewModel.note(for: event.id) ?? EventNote(
            eventId: event.id,
            eventTitle: event.title,
            eventDate: event.startDate
        )
        note.content = noteContent
        note.tags = noteTags
        note.projectId = noteProjectId
        appViewModel.upsertNote(note)
    }
}
