// Purpose: The morning question — "which of today's meetings should be recorded?" — as one compact
//          list with a switch per meeting, shown once a day when the app is first opened.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (todaysDecidableEvents, project(for:)),
//               Sources/App/Services/AutoRecordStore.swift
// RBAC: None.
// Dependents: Sources/App/Supporting/DailyBriefingPanel.swift
// Notes: Deliberately not a macOS notification: a notification can carry two or three actions, not
//        a list with a switch per row, and answering it for four meetings would mean four
//        notifications.
//        Toggles write straight through to AutoRecordStore, so the panel has no Save button and
//        dismissing it never loses a decision. All-day blockers, declined invitations and meetings
//        that already ended are filtered out by todaysDecidableEvents — they are never the answer.

import SwiftUI

struct DailyBriefingView: View {
    @Environment(AppViewModel.self) private var appViewModel

    /// Closes the panel. Owned by the panel controller, not by SwiftUI's dismiss.
    let onClose: () -> Void

    @State private var events: [CalendarEvent] = []
    /// Mirrors AutoRecordStore so toggling redraws — the store is not observable.
    @State private var recording: Set<String> = []

    private var recordingCount: Int {
        events.filter { recording.contains($0.id) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(events) { event in
                            row(event)
                            if event.id != events.last?.id {
                                Divider().padding(.leading, .space(12))
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)

                Divider()
                footer
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: .corner(14)))
        .overlay(
            RoundedRectangle(cornerRadius: .corner(14))
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .onAppear(perform: reload)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: .space(2)) {
                Text("Record today?")
                    .font(.themed(.headline))
                Text(summary)
                    .font(.themed(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.themed(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss until tomorrow")
        }
        .padding(.space(12))
    }

    private var summary: String {
        guard !events.isEmpty else { return "Nothing left on the calendar today." }
        let meetings = events.count == 1 ? "1 meeting" : "\(events.count) meetings"
        return recordingCount == 0
            ? "\(meetings) ahead · none set to record"
            : "\(meetings) ahead · \(recordingCount) set to record"
    }

    private var emptyState: some View {
        HStack(spacing: .space(8)) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(DesignSystem.Colors.success)
            Text("No meetings left today.")
                .font(.themed(.subheadline))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.space(12))
    }

    @ViewBuilder
    private func row(_ event: CalendarEvent) -> some View {
        let project = appViewModel.project(for: event)
        let accent = Color.secondary
        let isOn = recording.contains(event.id)

        Button {
            toggle(event)
        } label: {
            HStack(spacing: .space(10)) {
                RoundedRectangle(cornerRadius: .corner(1.5))
                    .fill(accent)
                    .frame(width: 3, height: 28)

                VStack(alignment: .leading, spacing: .space(2)) {
                    Text(event.title)
                        .font(.themed(.subheadline).weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: .space(5)) {
                        Text(timeLabel(event))
                            .font(.themed(.caption))
                            .foregroundStyle(.secondary)
                        if let project {
                            ProjectAvatarView(projectID: project.id, pixelSize: 1)
                            Text(project.name)
                                .font(.themed(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: isOn ? "record.circle.fill" : "circle")
                    .font(.themed(size: 17))
                    .foregroundStyle(isOn ? .red : .secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, .space(12))
            .padding(.vertical, .space(9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Will be recorded — click to turn off" : "Click to record this meeting")
    }

    private var footer: some View {
        HStack(spacing: .space(8)) {
            Button(recordingCount == events.count ? "Record none" : "Record all") {
                setAll(recordingCount != events.count)
            }
            .controlSize(.small)

            Spacer()

            Button("Done") { onClose() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(.space(12))
    }

    // MARK: - Actions

    private func reload() {
        events = appViewModel.todaysDecidableEvents()
        recording = Set(events.map(\.id).filter { appViewModel.autoRecordStore.isEnabled(for: $0) })
    }

    private func toggle(_ event: CalendarEvent) {
        let newValue = !recording.contains(event.id)
        try? appViewModel.autoRecordStore.setEnabled(newValue, for: event.id)
        if newValue {
            recording.insert(event.id)
        } else {
            recording.remove(event.id)
        }
    }

    private func setAll(_ enabled: Bool) {
        for event in events {
            try? appViewModel.autoRecordStore.setEnabled(enabled, for: event.id)
        }
        recording = enabled ? Set(events.map(\.id)) : []
    }

    private func timeLabel(_ event: CalendarEvent) -> String {
        let start = event.startDate.formatted(.dateTime.hour().minute())
        let end = event.endDate.formatted(.dateTime.hour().minute())
        return "\(start) – \(end)"
    }
}
