// Purpose: Apple Calendar-style week grid (Mon–Sun) with hourly rows, current-time indicator, and clickable event blocks.
// Dependencies: CalendarService, AutoRecordStore, DesignSystem, CalendarEvent,
//               Sources/App/Supporting/CalendarOverlapLayout.swift
// Used by: Sources/App/Views/CalendarView.swift (NavigationSplitView detail panel)
// Notes: Uses HStack-based column layout instead of ZStack+GeometryReader so day columns fill
//        available width naturally. Headers and grid are aligned because both use the same HStack
//        width model. Events are positioned with offsets inside each day's ZStack column: y from
//        the start time, x and width from CalendarOverlapLayout, so overlapping events stand side
//        by side like in Outlook instead of covering each other.
//        The red current-time dot overlaps the left separator via a negative x offset.

import SwiftUI

struct WeekCalendarView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @ObservedObject var calendarService: CalendarService
    let autoRecordStore: AutoRecordStore
    let onEventTap: (CalendarEvent) -> Void

    @State private var weekStart: Date = WeekCalendarView.mondayOfWeek(containing: Date())
    @State private var events: [CalendarEvent] = []

    // MARK: - Layout Constants

    private let startHour = 7
    private let endHour = 22
    private let hourHeight: CGFloat = 60
    private let timeColumnWidth: CGFloat = 52
    private let minimumBlockHeight: CGFloat = 22

    private var gridHeight: CGFloat { CGFloat(endHour - startHour) * hourHeight }

    private var weekDays: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var timedEvents: [CalendarEvent] { events.filter { !$0.isAllDay } }
    private var allDayEvents: [CalendarEvent] { events.filter { $0.isAllDay } }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            navigationHeader
            Divider().overlay(DesignSystem.Colors.divider)
            dayColumnHeadersRow
            if !allDayEvents.isEmpty {
                Divider().overlay(DesignSystem.Colors.divider)
                allDayRow
            }
            Divider().overlay(DesignSystem.Colors.divider)
            timeGrid
        }
        .task(id: weekStart) {
            await loadEvents()
        }
        .onChange(of: calendarService.isAuthorized) { _, authorized in
            if authorized { Task { await loadEvents() } }
        }
    }

    // MARK: - Navigation Header

    private var navigationHeader: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingS) {
            Text(monthYearLabel)
                .font(DesignSystem.Typography.title2.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Spacer()
            Button {
                weekStart = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
            } label: {
                Image(systemName: "chevron.left").imageScale(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignSystem.Colors.textSecondary)

            Button("Today") {
                weekStart = Self.mondayOfWeek(containing: Date())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                weekStart = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? weekStart
            } label: {
                Image(systemName: "chevron.right").imageScale(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Day Column Headers

    private var dayColumnHeadersRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeColumnWidth, height: 1)
            ForEach(weekDays, id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                VStack(spacing: 2) {
                    Text(dayAbbreviation(day))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isToday ? Color.accentColor : DesignSystem.Colors.textSecondary)
                    ZStack {
                        if isToday {
                            Circle().fill(Color.accentColor).frame(width: 26, height: 26)
                        }
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.system(size: 15, weight: isToday ? .semibold : .regular))
                            .foregroundStyle(isToday ? .white : DesignSystem.Colors.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - All-day Row

    private var allDayRow: some View {
        HStack(spacing: 0) {
            Text("all-day")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(width: timeColumnWidth, alignment: .trailing)
                .padding(.trailing, 6)
            ForEach(weekDays, id: \.self) { day in
                let dayEvents = allDayEvents.filter {
                    Calendar.current.isDate($0.startDate, inSameDayAs: day)
                }
                VStack(spacing: 2) {
                    ForEach(dayEvents) { event in
                        Button { onEventTap(event) } label: {
                            Text(event.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor))
                        }
                        .buttonStyle(.plain)
                    }
                    if dayEvents.isEmpty { Color.clear.frame(height: 20) }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: - Time Grid

    private var timeGrid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    timeLabelsColumn
                    ForEach(Array(weekDays.enumerated()), id: \.offset) { idx, day in
                        // Left border for each column
                        Rectangle()
                            .fill(Color.gray.opacity(0.12))
                            .frame(width: 0.5, height: gridHeight)
                        dayColumn(for: day)
                    }
                    // Right border
                    Rectangle()
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: 0.5, height: gridHeight)
                }
                .frame(maxWidth: .infinity)
            }
            .task {
                let targetHour = max(startHour, Calendar.current.component(.hour, from: Date()) - 1)
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.none) { proxy.scrollTo("wk-hour-\(targetHour)", anchor: .top) }
            }
        }
    }

    // MARK: - Time Labels Column

    private var timeLabelsColumn: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: timeColumnWidth, height: gridHeight)
            // Scroll anchors
            ForEach(startHour...endHour, id: \.self) { hour in
                Color.clear.frame(width: 1, height: 1)
                    .id("wk-hour-\(hour)")
                    .offset(x: 0, y: CGFloat(hour - startHour) * hourHeight)
            }
            // Hour labels — positioned just above each hour line
            ForEach(startHour..<endHour, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .frame(width: timeColumnWidth - 6, alignment: .trailing)
                    .offset(x: 0, y: CGFloat(hour - startHour) * hourHeight - 7)
            }
        }
        .frame(width: timeColumnWidth)
    }

    // MARK: - Single Day Column

    private func dayColumn(for day: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        let dayEvents = timedEvents.filter {
            Calendar.current.isDate($0.startDate, inSameDayAs: day)
        }

        return ZStack(alignment: .topLeading) {
            // Today background highlight
            if isToday {
                Color.accentColor.opacity(0.04)
                    .frame(maxWidth: .infinity)
                    .frame(height: gridHeight)
            }

            // Hour + half-hour lines
            hourLinesOverlay

            // Current time indicator (today only)
            if isToday {
                currentTimeIndicator
            }

            // Event blocks, overlapping ones side by side
            GeometryReader { proxy in
                let slots = overlapSlots(for: dayEvents)
                ForEach(dayEvents) { event in
                    let slot = slots[event.id] ?? CalendarOverlapLayout.Slot(column: 0, span: 1, columns: 1)
                    eventBlock(for: event)
                        .frame(width: proxy.size.width * slot.widthFraction)
                        .offset(
                            x: proxy.size.width * slot.leadingFraction,
                            y: max(0, yOffset(for: event.startDate))
                        )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: gridHeight)
        .clipped()
    }

    /// Horizontal slots for one day's events. Overlap counts on the drawn height, since short
    /// events are drawn at least `minimumBlockHeight` tall.
    private func overlapSlots(for dayEvents: [CalendarEvent]) -> [String: CalendarOverlapLayout.Slot] {
        let items = dayEvents.map {
            CalendarOverlapLayout.Item(id: $0.id, start: $0.startDate, end: $0.endDate)
        }
        let minimumDuration = TimeInterval(minimumBlockHeight / hourHeight * 3600)
        return CalendarOverlapLayout.slots(for: items, minimumDuration: minimumDuration)
    }

    // MARK: - Hour Lines

    private var hourLinesOverlay: some View {
        VStack(spacing: 0) {
            ForEach(startHour..<endHour, id: \.self) { _ in
                Rectangle()
                    .fill(Color.gray.opacity(0.13))
                    .frame(height: 0.5)
                Color.clear.frame(height: hourHeight / 2 - 0.5)
                Rectangle()
                    .fill(Color.gray.opacity(0.07))
                    .frame(height: 0.5)
                Color.clear.frame(height: hourHeight / 2 - 0.5)
            }
            // Final hour line
            Rectangle()
                .fill(Color.gray.opacity(0.13))
                .frame(height: 0.5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Current Time Indicator

    @ViewBuilder
    private var currentTimeIndicator: some View {
        let y = yOffset(for: Date())
        if y >= 0 && y <= gridHeight {
            ZStack(alignment: .leading) {
                // Red line across full column
                Rectangle()
                    .fill(Color.red.opacity(0.7))
                    .frame(height: 1.5)
                    .offset(y: y)
                // Red dot at left edge, straddling the column separator
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .offset(x: -4, y: y - 3.5)
            }
        }
    }

    // MARK: - Event Block

    private func eventBlock(for event: CalendarEvent) -> some View {
        let yStart = yOffset(for: event.startDate)
        let yEnd   = yOffset(for: event.endDate)
        let blockH = max(minimumBlockHeight, yEnd - yStart)
        let isAutoRecord = autoRecordStore.isEnabled(for: event.id)

        let accent = accentColor(for: event)

        return Button { onEventTap(event) } label: {
            HStack(spacing: 0) {
                // The project's colour as a bar rather than a fill: it stays legible in both
                // appearances and does not depend on the contrast of a user-picked colour.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(event.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)
                            .lineLimit(blockH > 40 ? 2 : 1)

                        if isAutoRecord {
                            Image(systemName: "record.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.red)
                                .help("Will be recorded automatically")
                        }
                        Spacer(minLength: 0)
                    }

                    if blockH > 32 {
                        Text(timeRangeLabel(for: event))
                            .font(.system(size: 10))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
                .padding(.leading, 5)
                .padding(.trailing, 4)
                .padding(.vertical, 3)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: blockH, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(accent.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(accent.opacity(0.25), lineWidth: 0.5)
            )
            .opacity(event.participantStatus == .declined ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .help(event.title)
    }

    /// Colour for an event: its project's, or a neutral grey when it is not assigned to one.
    /// Colour therefore means something — you can see at a glance which project a block belongs to.
    private func accentColor(for event: CalendarEvent) -> Color {
        guard let project = appViewModel.project(for: event) else {
            return DesignSystem.Colors.textSecondary
        }
        return Color(hex: project.colorHex)
    }

    // MARK: - Helpers

    private var monthYearLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: weekStart)
    }

    private func dayAbbreviation(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date).uppercased()
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour > 0 else { return "" }
        let suffix = hour < 12 ? "AM" : "PM"
        let h = hour == 12 ? 12 : (hour % 12)
        return "\(h) \(suffix)"
    }

    private func yOffset(for date: Date) -> CGFloat {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let mins = CGFloat((c.hour ?? 0) * 60 + (c.minute ?? 0))
        return (mins - CGFloat(startHour * 60)) / 60.0 * hourHeight
    }

    private func timeRangeLabel(for event: CalendarEvent) -> String {
        let s = event.startDate.formatted(.dateTime.hour().minute())
        let e = event.endDate.formatted(.dateTime.hour().minute())
        return "\(s) – \(e)"
    }

    private func loadEvents() async {
        guard calendarService.isAuthorized else { return }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let fetched = calendarService.fetchEvents(from: weekStart, to: end)
        events = fetched.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Static Helpers

    static func mondayOfWeek(containing date: Date) -> Date {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date) // 1=Sun,2=Mon,...7=Sat
        let daysFromMonday = (weekday + 5) % 7
        return cal.startOfDay(for: cal.date(byAdding: .day, value: -daysFromMonday, to: date) ?? date)
    }
}
