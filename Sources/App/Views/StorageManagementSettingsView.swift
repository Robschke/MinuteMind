// Purpose: StorageManagementSettingsView — "Storage" tab in the Settings sheet. Shows total disk
//          usage of recordings, a per-project breakdown, and the largest recordings with an archive
//          action (re-encode to 32 kbps mono, or delete audio keeping the transcript). Also offers a
//          bulk "archive recordings older than N days" action, and rebuilding the knowledge search
//          index. Analysis runs automatically on appear.
// Dependencies: Sources/App/Services/StorageAnalyzer.swift (StorageReport + StorageArchiveAction),
//               Sources/App/ViewModels/AppViewModel.swift (analyzeStorage(), archiveSession(...),
//               rebuildKnowledgeBase()),
//               Sources/App/Views/ProjectsSidebarView.swift (Color(hex:) extension)
// RBAC: None — user settings, local data only.
// Dependents: Sources/App/Views/MeetingMinutesSettingsView.swift (Storage tab)
// Notes: Both archive actions are lossy/destructive and not reversible — guarded by a confirmation
//        dialog. Analysis is cheap (file metadata only) and runs off the main actor, so re-running
//        after each action (and on appear) is fine.

import SwiftUI

struct StorageManagementSettingsView: View {
    @Environment(AppViewModel.self) private var viewModel

    @State private var report: StorageReport = .empty
    @State private var isAnalyzing = false
    @State private var isArchiving = false
    @State private var hasLoaded = false

    /// The recording whose per-item archive dialog is open.
    @State private var pendingArchive: RecordingFileUsage?
    /// Whether the bulk-archive action sheet is open.
    @State private var showBulkDialog = false
    /// Age threshold (in days) for the bulk action.
    @State private var bulkAgeDays = 90
    /// Last status message (e.g. "Freed 1.2 GB").
    @State private var statusMessage: String?
    @State private var isRebuildingIndex = false
    @State private var indexRebuilt = false

    /// How many of the largest recordings to surface.
    private let largestLimit = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                totalSection
                Divider()
                perProjectSection
                Divider()
                largestRecordingsSection
                Divider()
                bulkSection
                Divider()
                searchIndexSection
                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await runAnalysis()
        }
        .confirmationDialog(
            "Archive \"\(pendingArchive?.sessionTitle ?? "recording")\"",
            isPresented: Binding(
                get: { pendingArchive != nil },
                set: { if !$0 { pendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = pendingArchive {
                Button("Re-encode to 32 kbps mono") {
                    archive { await viewModel.archiveSession(target.sessionID, action: .recompress) }
                }
                Button("Delete audio (keep transcript)", role: .destructive) {
                    archive { await viewModel.archiveSession(target.sessionID, action: .deleteAudio) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text("Re-encoding shrinks the audio (~75% smaller, still playable). Deleting removes the audio entirely and keeps only the transcript and minutes. Both are permanent.")
        }
        .confirmationDialog(
            "Archive recordings older than \(bulkAgeDays) days",
            isPresented: $showBulkDialog,
            titleVisibility: .visible
        ) {
            Button("Re-encode to 32 kbps mono") {
                archive {
                    let result = await viewModel.archiveSessions(olderThanDays: bulkAgeDays, action: .recompress)
                    return result.freed
                }
            }
            Button("Delete audio (keep transcript)", role: .destructive) {
                archive {
                    let result = await viewModel.archiveSessions(olderThanDays: bulkAgeDays, action: .deleteAudio)
                    return result.freed
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Applies to every recording older than \(bulkAgeDays) days that still has audio. Both actions are permanent.")
        }
    }

    // MARK: - Total

    private var totalSection: some View {
        GroupBox(label: sectionLabel("Total storage used", systemImage: "externaldrive.fill")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(formatted(report.totalBytes))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    if isAnalyzing || isArchiving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("across \(report.projects.reduce(0) { $0 + $1.recordingCount }) recordings")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task { await runAnalysis() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAnalyzing || isArchiving)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Per project

    private var perProjectSection: some View {
        GroupBox(label: sectionLabel("By project", systemImage: "folder.fill")) {
            VStack(alignment: .leading, spacing: 12) {
                if report.projects.isEmpty {
                    emptyHint("No recordings use any storage yet.")
                } else {
                    ForEach(report.projects) { usage in
                        projectRow(usage)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func projectRow(_ usage: ProjectStorageUsage) -> some View {
        let fraction = report.totalBytes > 0
            ? Double(usage.totalBytes) / Double(report.totalBytes)
            : 0
        let color = usage.colorHex.map { Color(hex: $0) } ?? Color.secondary

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(usage.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("· \(usage.recordingCount) rec.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatted(usage.totalBytes))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Largest recordings

    private var largestRecordingsSection: some View {
        GroupBox(label: sectionLabel("Largest recordings", systemImage: "waveform")) {
            VStack(alignment: .leading, spacing: 10) {
                if report.largestRecordings.isEmpty {
                    emptyHint("No audio recordings found.")
                } else {
                    let items = Array(report.largestRecordings.prefix(largestLimit))
                    ForEach(items) { file in
                        largestRow(file)
                        if file.id != items.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func largestRow(_ file: RecordingFileUsage) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.sessionTitle.isEmpty ? "Untitled recording" : file.sessionTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(file.kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(formatted(file.bytes))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button {
                pendingArchive = file
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .buttonStyle(.bordered)
            .disabled(isArchiving)
            .help("Re-encode or delete this recording's audio to free space")
        }
    }

    // MARK: - Bulk archive

    private var bulkSection: some View {
        GroupBox(label: sectionLabel("Bulk archive", systemImage: "tray.full.fill")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Recordings older than")
                        .font(.subheadline)
                    Picker("Age", selection: $bulkAgeDays) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("180 days").tag(180)
                        Text("1 year").tag(365)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                Button {
                    showBulkDialog = true
                } label: {
                    Label("Archive these…", systemImage: "archivebox.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isArchiving)

                Text("Re-encode (shrink) or delete the audio of all older recordings at once. You choose which after pressing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Search index

    private var searchIndexSection: some View {
        GroupBox(label: sectionLabel("Search index", systemImage: "magnifyingglass")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Knowledge search reads the knowledge files of every workspace. Rebuild the index if search misses something that is in the files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        Task {
                            isRebuildingIndex = true
                            indexRebuilt = false
                            await viewModel.rebuildKnowledgeBase()
                            isRebuildingIndex = false
                            indexRebuilt = true
                        }
                    } label: {
                        Label("Rebuild Search Index", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRebuildingIndex)
                    if isRebuildingIndex {
                        ProgressView().controlSize(.small)
                        Text("Rebuilding\u{2026}").font(.caption).foregroundStyle(.secondary)
                    } else if indexRebuilt {
                        Label("Rebuilt", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Actions

    /// Runs an archive operation that returns bytes freed, then refreshes the report.
    private func archive(_ operation: @escaping () async -> Int64) {
        Task {
            isArchiving = true
            statusMessage = nil
            let freed = await operation()
            report = await viewModel.analyzeStorage()
            isArchiving = false
            statusMessage = freed > 0 ? "Freed \(formatted(freed))." : "No space could be freed."
        }
    }

    private func runAnalysis() async {
        isAnalyzing = true
        report = await viewModel.analyzeStorage()
        isAnalyzing = false
    }

    // MARK: - Helpers

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }
}
