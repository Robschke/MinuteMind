// Purpose: How a Shared Project's sync shows in the UI: the "people" mark beside its name in the
//          sidebar (with an orange dot when sync has a problem) and the sync state with a
//          Sync now button in the workspace branch row, plus the texts both use. Files held back
//          for their size show as "N files not synced" in the row, with a popover to sync them
//          anyway.
// Dependencies: Sources/App/Models/SharedProject.swift (SharedSyncStatus),
//               Sources/App/Services/SharedProjectSyncService.swift (AppViewModel.sharedSync),
//               Sources/App/Services/SharedSyncCommit.swift (SharedHeldBackFile),
//               Sources/App/ViewModels/AppViewModel+SharedSync.swift (syncSharedProjectNow,
//               syncLargeFileAnyway),
//               Sources/App/Components/DesignSystem.swift (tokens)
// Used by: Sources/App/Views/ProjectsSidebarView.swift (ProjectRowView),
//          Sources/App/Views/WorkspaceGitBranchBar.swift, Tests/SharedProjectUITests.swift
// Notes: The relative time is our own wording ("Synced 2 min ago"), not RelativeDateTimeFormatter,
//        so it is the same on every locale and fits the narrow branch row. It refreshes every
//        30 s through a TimelineView, minute precision is all it shows.
//        Sync now is a plain text button in the row's 11 pt style, like the branch label beside
//        it; it is disabled while a sync runs.
//        Held back files do not count as a problem: they never put the orange dot on the
//        sidebar mark, only the orange text in the branch row.

import SwiftUI

/// Texts for a Shared Project's sync state.
enum SharedSyncText {
    /// "Syncing…", the problem message, "Synced 2 min ago" or "Not synced yet".
    static func label(for status: SharedSyncStatus, now: Date = Date()) -> String {
        switch status.state {
        case .syncing: return "Syncing…"
        case .problem(let message): return message
        case .idle:
            guard let lastSynced = status.lastSynced else { return "Not synced yet" }
            return "Synced \(ago(lastSynced, now: now))"
        }
    }

    /// "just now", "1 min ago", "5 h ago", "3 d ago". Dates in the future count as now.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }

    /// "1 file not synced", "3 files not synced".
    static func heldBackLabel(count: Int) -> String {
        count == 1 ? "1 file not synced" : "\(count) files not synced"
    }

    /// "72 MB" (binary megabytes, like the limits).
    static func size(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_048_576).rounded())) MB"
    }

    /// The tooltip of the sidebar mark.
    static func markTooltip(for status: SharedSyncStatus) -> String {
        if case .problem(let message) = status.state { return message }
        return "Shared Project"
    }
}

/// The sidebar's mark for a Shared Project: two people, an orange dot when sync needs attention.
struct SharedProjectMark: View {
    let status: SharedSyncStatus

    var body: some View {
        Image(systemName: "person.2.fill")
            .font(.system(size: 10))
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .overlay(alignment: .topTrailing) {
                if status.hasProblem {
                    Circle()
                        .fill(DesignSystem.Colors.warning)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -2)
                }
            }
            .help(SharedSyncText.markTooltip(for: status))
            .accessibilityLabel(status.hasProblem
                                ? "Shared Project, sync problem: \(SharedSyncText.markTooltip(for: status))"
                                : "Shared Project")
    }
}

/// The branch row's part for a Shared Project: sync state, files held back for their size (a
/// popover lists them with Sync anyway) and Sync now.
struct WorkspaceSharedSyncStatus: View {
    let projectID: UUID
    @Environment(AppViewModel.self) private var viewModel
    @State private var showsHeldBack = false

    var body: some View {
        let status = viewModel.sharedSync.status(for: projectID)
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(SharedSyncText.label(for: status, now: context.date))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(status.hasProblem ? DesignSystem.Colors.warning : DesignSystem.Colors.textSecondary)
            }
            .help(status.hasProblem ? SharedSyncText.label(for: status) : "Meetings, recordings, knowledge and every other file outside private/ sync with the other members in the background.")
            if !status.heldBack.isEmpty {
                Button(SharedSyncText.heldBackLabel(count: status.heldBack.count)) { showsHeldBack = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .help("Files over 50 MB stay on this Mac. Click to see them.")
                    .fixedSize()
                    .popover(isPresented: $showsHeldBack, arrowEdge: .top) {
                        SharedHeldBackList(files: status.heldBack) { path in
                            viewModel.syncLargeFileAnyway(path, in: projectID)
                        }
                    }
            }
            Button("Sync now") { viewModel.syncSharedProjectNow(projectID) }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.accent)
                .disabled(status.state == .syncing)
                .help("Fetch the other members' changes and send yours now")
                .fixedSize()
        }
        .font(DesignSystem.Typography.caption1)
    }
}

/// The popover of held back files: path, size, and Sync anyway up to 100 MB.
struct SharedHeldBackList: View {
    let files: [SharedHeldBackFile]
    let syncAnyway: (String) -> Void
    @State private var allowed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Over 50 MB, kept on this Mac")
                .font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(files) { file in
                    GridRow {
                        Text(file.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .leading)
                            .help(file.path)
                        Text(SharedSyncText.size(file.size))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .gridColumnAlignment(.trailing)
                        if !file.canSyncAnyway {
                            Text("Over 100 MB, cannot sync")
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        } else if allowed.contains(file.path) {
                            Text("Syncing…")
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        } else {
                            Button("Sync anyway") {
                                allowed.insert(file.path)
                                syncAnyway(file.path)
                            }
                            .help("Send this file to the other members now and from now on")
                        }
                    }
                }
            }
            Text("Remove a file or move it to private/ to clear it from this list.")
                .font(DesignSystem.Typography.caption1)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .font(DesignSystem.Typography.footnote)
        .padding(14)
        .frame(minWidth: 320)
    }
}
