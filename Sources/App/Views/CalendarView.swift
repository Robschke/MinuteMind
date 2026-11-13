// Purpose: Calendar navigation destination — event list sidebar + week calendar grid; event detail as a sheet.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift, Sources/App/Services/CalendarService.swift,
//               Sources/App/Services/AutoRecordStore.swift, Sources/App/Components/DesignSystem.swift,
//               Sources/App/Views/WeekCalendarView.swift, Sources/App/Views/CalendarEventDetailView.swift
// RBAC: No access control — all authenticated users can see their calendar events.
// Notes: Uses a plain HStack (not NavigationSplitView) to avoid double toolbar safe-area insets that
//        would otherwise appear when nested inside the main app's NavigationSplitView. The event list
//        has a fixed min/max width; the calendar fills all remaining space edge-to-edge.

import SwiftUI
import AppKit

struct CalendarView: View {
    @Environment(AppViewModel.self) var appViewModel

    @State private var selectedEventID: String? = nil
    @State private var groupedEvents: [Date: [CalendarEvent]] = [:]
    @State private var sortedDates: [Date] = []
    /// The event currently shown in the detail sheet; nil = sheet closed.
    @State private var detailEvent: CalendarEvent? = nil
    @State private var showingNewEventSheet = false

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // Left panel: upcoming events list
            eventListPanel
                .frame(minWidth: 220, maxWidth: 300)
            Divider()
            // Right panel: week calendar, fills all remaining space
            WeekCalendarView(
                calendarService: appViewModel.calendarService,
                autoRecordStore: appViewModel.autoRecordStore,
                onEventTap: { detailEvent = $0 }
            )
        }
        // Clearing the selection on dismiss is what makes a row clickable again: the sheet is driven
        // by onChange(of: selectedEventID), so a still-selected row produces no change and the
        // second click on the same event does nothing.
        .sheet(item: $detailEvent, onDismiss: { selectedEventID = nil }) { event in
            CalendarEventDetailView(event: event, appViewModel: appViewModel)
                .frame(
                    minWidth: 700, idealWidth: 900, maxWidth: .infinity,
                    minHeight: 620, idealHeight: 820, maxHeight: .infinity
                )
                .resizableSheet()
        }
        .sheet(isPresented: $showingNewEventSheet) {
            NewCalendarEventSheet(
                calendarService: appViewModel.calendarService,
                autoRecordStore: appViewModel.autoRecordStore,
                onCreated: {
                    Task { await loadEvents() }
                }
            )
        }
        .task {
            await loadEvents()
        }
        .onChange(of: selectedEventID) { _, newID in
            if let id = newID, let event = findEvent(id: id) {
                detailEvent = event
            }
        }
    }

    // MARK: - Event List Panel

    @ViewBuilder
    private var eventListPanel: some View {
        if !appViewModel.calendarService.isAuthorized {
            permissionPrompt
        } else {
            VStack(spacing: 0) {
                eventListHeader
                Divider()
                if sortedDates.isEmpty {
                    emptyState
                } else {
                    List(selection: $selectedEventID) {
                        ForEach(sortedDates, id: \.self) { date in
                            Section(header: sectionHeader(for: date)) {
                                ForEach(groupedEvents[date] ?? []) { event in
                                    EventRowView(
                                        event: event,
                                        isSelected: selectedEventID == event.id,
                                        autoRecord: autoRecordBinding(for: event)
                                    )
                                    .tag(event.id)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
        }
    }

    private var eventListHeader: some View {
        HStack {
            Text("Events")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Spacer()
            Button {
                showingNewEventSheet = true
            } label: {
                Image(systemName: "plus")
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func autoRecordBinding(for event: CalendarEvent) -> Binding<Bool> {
        Binding(
            get: { appViewModel.autoRecordStore.isEnabled(for: event.id) },
            set: { try? appViewModel.autoRecordStore.setEnabled($0, for: event.id) }
        )
    }

    // MARK: - Permission Prompt

    private var permissionPrompt: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingL) {
            Spacer()
            Image(systemName: "lock.calendar")
                .font(.system(size: 40))
                .foregroundStyle(DesignSystem.Colors.textTertiary)

            VStack(spacing: DesignSystem.Dimensions.spacingS) {
                Text("Calendar Access Required")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("MinuteMind needs access to your calendar to show upcoming events and enable auto-record.")
                    .font(DesignSystem.Typography.callout)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }

            Button("Open System Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
                )
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Dimensions.spacingXXXL)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingM) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 40))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text("No upcoming events")
                .font(DesignSystem.Typography.callout)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Section Header

    private func sectionHeader(for date: Date) -> Text {
        Text(sectionLabel(for: date))
            .font(DesignSystem.Typography.caption2)
            .foregroundStyle(DesignSystem.Colors.textTertiary)
    }

    private func sectionLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        return formatter.string(from: date)
    }

    // MARK: - Data Loading

    private func loadEvents() async {
        appViewModel.calendarService.updateAuthorizationStatus()
        if !appViewModel.calendarService.isAuthorized {
            _ = await appViewModel.calendarService.requestAccess()
        }
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let endDate = cal.date(byAdding: .day, value: 7, to: startOfToday) ?? Date()
        let fetched = appViewModel.calendarService.fetchEventsGroupedByDay(from: startOfToday, to: endDate)
        groupedEvents = fetched
        sortedDates = fetched.keys.sorted()
    }

    // MARK: - Helpers

    private func findEvent(id: String) -> CalendarEvent? {
        for events in groupedEvents.values {
            if let event = events.first(where: { $0.id == id }) {
                return event
            }
        }
        return nil
    }
}

// MARK: - Event Row

private struct EventRowView: View {
    @Environment(AppViewModel.self) private var appViewModel

    let event: CalendarEvent
    let isSelected: Bool
    @Binding var autoRecord: Bool

    private var project: Project? { appViewModel.project(for: event) }

    private var accent: Color { DesignSystem.Colors.textTertiary }

    var body: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingS) {
            Toggle("", isOn: $autoRecord)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Record this meeting automatically")

            // A bar mirroring the week grid so the two views read the same way.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(event.title)
                        .font(DesignSystem.Typography.callout)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    if autoRecord {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                }

                HStack(spacing: 5) {
                    Text(timeRangeLabel(for: event))
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    if let project {
                        ProjectAvatarView(projectID: project.id, pixelSize: 1)
                        Text(project.name)
                            .font(DesignSystem.Typography.caption1)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, DesignSystem.Dimensions.spacingXS)
        .opacity(event.participantStatus == .declined ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    private func timeRangeLabel(for event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let start = event.startDate.formatted(.dateTime.hour().minute())
        let end = event.endDate.formatted(.dateTime.hour().minute())
        return "\(start) – \(end)"
    }
}

// MARK: - New Calendar Event Sheet

private struct NewCalendarEventSheet: View {
    let calendarService: CalendarService
    let autoRecordStore: AutoRecordStore
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var date = Date()
    @State private var startTime = Date()
    @State private var endTime = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Text("New Event")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Button("Add") { Task { await createEvent() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
            .padding()

            Divider()

            Form {
                TextField("Title", text: $title)

                DatePicker("Date", selection: $date, displayedComponents: .date)

                DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)

                DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(DesignSystem.Colors.error)
                        .font(DesignSystem.Typography.caption1)
                }
            }
            .formStyle(.grouped)
            .padding(.bottom)
        }
        .frame(width: 380, height: 320)
    }

    private func createEvent() async {
        isSaving = true
        defer { isSaving = false }

        let cal = Calendar.current
        let dayComponents = cal.dateComponents([.year, .month, .day], from: date)
        let startComponents = cal.dateComponents([.hour, .minute], from: startTime)
        let endComponents = cal.dateComponents([.hour, .minute], from: endTime)

        var startDateComponents = dayComponents
        startDateComponents.hour = startComponents.hour
        startDateComponents.minute = startComponents.minute

        var endDateComponents = dayComponents
        endDateComponents.hour = endComponents.hour
        endDateComponents.minute = endComponents.minute

        guard let resolvedStart = cal.date(from: startDateComponents),
              let resolvedEnd = cal.date(from: endDateComponents) else {
            errorMessage = "Invalid date/time selection."
            return
        }

        guard resolvedEnd > resolvedStart else {
            errorMessage = "End time must be after start time."
            return
        }

        do {
            let eventID = try await calendarService.createEvent(
                title: title.trimmingCharacters(in: .whitespaces),
                startDate: resolvedStart,
                endDate: resolvedEnd
            )
            // Auto-enable recording for the new event
            try? autoRecordStore.setEnabled(true, for: eventID)
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
