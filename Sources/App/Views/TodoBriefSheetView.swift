// Purpose: Sheet presented when a daily task brief notification arrives. Shows each AI-selected
//          task with 2–3 calendar slot options; the user picks one per task and taps "Block Selected"
//          to create calendar blockers for all chosen slots.
// Dependencies: AppViewModel (createEvent via calendarService), TodoBriefService (BriefItem, TodoBrief),
//               CalendarService (ProposedTimeBlock)
// Used by: Sources/App/Views/ContentView.swift (.sheet on showTodoBriefSheet)

import SwiftUI

struct TodoBriefSheetView: View {
    @Environment(AppViewModel.self) var appViewModel
    @Binding var isPresented: Bool

    let brief: TodoBrief

    // Per-task selected slot index (nil = skip this task)
    @State private var selections: [UUID: UUID] = [:]   // taskID → slotID
    @State private var isBlocking = false
    @State private var blockedCount = 0
    @State private var errorMessage: String?
    @State private var showDone = false

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var selectedCount: Int {
        selections.values.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showDone {
                doneView
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        summaryCard
                        ForEach(brief.items, id: \.task.id) { item in
                            taskCard(item)
                        }
                    }
                    .padding(16)
                }
                Divider()
                footer
            }
        }
        .frame(width: 520, height: showDone ? 240 : min(CGFloat(160 + brief.items.count * 200), 680))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "checklist")
                .foregroundStyle(.blue)
            Text("Daily Task Brief")
                .font(.headline)
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Summary

    private var summaryCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.blue)
                .font(.subheadline)
                .padding(.top, 2)
            Text(brief.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Task card

    private func taskCard(_ item: BriefItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Task header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task.title)
                        .font(.subheadline).bold()
                    HStack(spacing: 6) {
                        if let priority = item.task.priority {
                            priorityBadge(priority)
                        }
                        if let due = item.task.dueDate {
                            Text("Due \(dateFormatter.string(from: due))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }

            // AI reason
            Text(item.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()

            if item.suggestedSlots.isEmpty {
                Text("No free slots found in the next 7 days.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                // Slot options
                VStack(spacing: 4) {
                    ForEach(item.suggestedSlots) { slot in
                        slotRow(slot: slot, taskID: item.task.id)
                    }
                }

                // Skip option
                Button {
                    selections.removeValue(forKey: item.task.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selections[item.task.id] == nil
                              ? "circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(selections[item.task.id] == nil ? Color.secondary : Color.secondary.opacity(0.4))
                        Text("Skip – don't block calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private func slotRow(slot: ProposedTimeBlock, taskID: UUID) -> some View {
        let isSelected = selections[taskID] == slot.id
        return Button {
            selections[taskID] = slot.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 1) {
                    Text(slotLabel(slot))
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(durationLabel(slot))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? .blue.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? .blue.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)

            Button {
                Task { await blockSelected() }
            } label: {
                if isBlocking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Blocking…")
                    }
                } else {
                    Text(selectedCount > 0
                         ? "Block \(selectedCount) Slot\(selectedCount == 1 ? "" : "s")"
                         : "Nothing selected")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedCount == 0 || isBlocking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Blocked \(blockedCount) calendar slot\(blockedCount == 1 ? "" : "s")")
                .font(.headline)
            Text("Your focus time has been added to the calendar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func blockSelected() async {
        isBlocking = true
        errorMessage = nil
        var created = 0

        // Build a lookup: slotID → ProposedTimeBlock across all items
        var slotByID: [UUID: ProposedTimeBlock] = [:]
        for item in brief.items {
            for slot in item.suggestedSlots {
                slotByID[slot.id] = slot
            }
        }

        for (_, slotID) in selections {
            guard let slot = slotByID[slotID] else { continue }
            do {
                _ = try await appViewModel.calendarService.createEvent(
                    title: slot.title,
                    startDate: slot.startDate,
                    endDate: slot.endDate
                )
                created += 1
            } catch {
                NSLog("TodoBriefSheetView: Failed to create event '%@': %@",
                      slot.title, error.localizedDescription)
                errorMessage = "Could not create \"\(slot.title)\": \(error.localizedDescription)"
            }
        }

        isBlocking = false
        if created > 0 {
            blockedCount = created
            showDone = true
        }
    }

    // MARK: - Helpers

    private func slotLabel(_ slot: ProposedTimeBlock) -> String {
        let start = dateFormatter.string(from: slot.startDate)
        let endTime = DateFormatter.localizedString(from: slot.endDate, dateStyle: .none, timeStyle: .short)
        return "\(start) – \(endTime)"
    }

    private func durationLabel(_ slot: ProposedTimeBlock) -> String {
        let mins = slot.durationMinutes
        return mins >= 60 ? "\(mins / 60)h \(mins % 60 > 0 ? "\(mins % 60)m" : "")" : "\(mins)m"
    }

    private func priorityBadge(_ priority: TaskPriority) -> some View {
        Text(priority.displayName)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(hex: priority.color).opacity(0.15))
            .foregroundStyle(Color(hex: priority.color))
            .clipShape(Capsule())
    }
}
