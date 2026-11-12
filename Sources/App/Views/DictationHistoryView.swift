// Purpose: DictationHistoryView, the sidebar "Clipboard": every quick dictation and Claude mini
//          task said through the dictation key, newest first, to copy again when pasting failed
//          or something from earlier is needed.
// Dependencies: Sources/App/Store/DictationHistoryStore.swift (entries, delete, clear),
//               Sources/App/ViewModels/AppViewModel.swift (dictationHistory),
//               Sources/App/Components/DesignSystem.swift
// RBAC: None.
// Dependents: Sources/App/Views/ContentView.swift (detail for the sidebar's Clipboard entry)
// Notes: User request 2026-10-04. Dense rows like the Inbox, grouped by day. A row shows the
//        text (up to four lines, selectable), time, the app it was said into, and "Not inserted"
//        when the text only reached the clipboard. Claude tasks show the request above the
//        answer and the accent-coloured sparkle. Copy is always visible; Delete sits in the
//        context menu and on hover, Clear All asks first because it cannot be undone.

import AppKit
import SwiftUI

struct DictationHistoryView: View {
    @Environment(AppViewModel.self) private var viewModel

    enum Filter: String, CaseIterable { case all = "All", dictation = "Dictation", claude = "Claude" }

    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var confirmClear = false
    @State private var copiedID: UUID?

    private var rows: [DictationHistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return viewModel.dictationHistory.entries.filter { entry in
            switch filter {
            case .all: break
            case .dictation: if entry.kind != .dictation { return false }
            case .claude: if entry.kind != .claudeTask { return false }
            }
            guard !query.isEmpty else { return true }
            return entry.text.lowercased().contains(query)
                || (entry.request?.lowercased().contains(query) ?? false)
                || (entry.appName?.lowercased().contains(query) ?? false)
        }
    }

    /// Rows grouped by calendar day, newest day first.
    private var days: [(day: Date, entries: [DictationHistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
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
        .confirmationDialog("Clear the whole history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { viewModel.dictationHistory.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(viewModel.dictationHistory.entries.count) entries are deleted. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Clipboard")
                .font(DesignSystem.Typography.title3)
            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            Spacer()
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Button("Clear All") { confirmClear = true }
                .disabled(viewModel.dictationHistory.entries.isEmpty)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(days, id: \.day) { group in
                Section(Self.dayTitle(group.day)) {
                    ForEach(group.entries) { entry in
                        HistoryRow(
                            entry: entry,
                            justCopied: copiedID == entry.id,
                            onCopy: { copy(entry) },
                            onDelete: { viewModel.dictationHistory.delete(entry.id) })
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 32))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text(search.isEmpty ? "Nothing dictated yet" : "No matches")
                .font(.system(size: 15, weight: .medium))
            Text(search.isEmpty
                 ? "Everything you dictate with the fn key, and every Claude mini task, is kept here."
                 : "Try another word, or switch the filter to All.")
                .font(DesignSystem.Typography.footnote)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ entry: DictationHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copiedID = entry.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedID == entry.id { copiedID = nil }
        }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "en_US")))
    }
}

private struct HistoryRow: View {
    let entry: DictationHistoryEntry
    let justCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind == .claudeTask ? "sparkle" : "mic")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(entry.kind == .claudeTask ? PillStyle.claude : DesignSystem.Colors.textSecondary)
                .frame(width: 16)
                .padding(.top, 2)
                .accessibilityLabel(entry.kind == .claudeTask ? "Claude task" : "Dictation")
            VStack(alignment: .leading, spacing: 4) {
                if let request = entry.request {
                    Text("You asked: \(request)")
                        .font(DesignSystem.Typography.footnote)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(2)
                }
                Text(entry.text)
                    .font(.system(size: 13))
                    .lineLimit(4)
                    .textSelection(.enabled)
                metaLine
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete")
                    .accessibilityLabel("Delete")
                }
                Button(justCopied ? "Copied" : "Copy", action: onCopy)
                    .controlSize(.small)
                    .frame(minWidth: 64)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(entry.date.formatted(date: .omitted, time: .shortened))
            if let app = entry.appName {
                Text("\u{00B7}")
                Text(app)
            }
            if !entry.inserted {
                Text("\u{00B7}")
                Text("Not inserted").foregroundStyle(.orange)
            }
        }
        .font(DesignSystem.Typography.caption1)
        .foregroundStyle(DesignSystem.Colors.textTertiary)
    }
}
