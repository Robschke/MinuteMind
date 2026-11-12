// Purpose: ScheduledJobsView, the Jobs tab of a project (and of General): the workspace's jobs on
//          the left with their state, and on the right the selected job's editor or, once a run is
//          picked, that run's result in its place.
// Dependencies: Sources/App/Supporting/ScheduledJobStore.swift, Sources/App/Views/ScheduledJobEditorView.swift,
//               Sources/App/Views/ScheduledJobRunView.swift, Sources/App/ViewModels/AppViewModel+ScheduledJobs.swift
//               (requestedJobRun)
// RBAC: None.
// Dependents: Sources/App/Views/ProjectDetailView.swift (Jobs tab), Sources/App/Views/GeneralWorkspaceView.swift
// Notes: Layout as chosen for the feature: list left, detail right, a run replaces the right side
//        with a way back to the job. Edits save by themselves (the store writes after a short pause
//        and commits later); leaving the tab writes what is pending.

import SwiftUI

struct ScheduledJobsView: View {
    @Environment(AppViewModel.self) private var viewModel
    let projectID: UUID

    @State private var selectedJobID: String?
    @State private var openRunID: String?
    @State private var createError: String?

    private var store: ScheduledJobStore { viewModel.scheduledJobs }
    private var jobs: [ScheduledJob] { store.jobs(for: projectID) }

    var body: some View {
        HStack(spacing: 0) {
            jobList
                .frame(width: 260)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            store.reload(projectID)
            if selectedJobID == nil { selectedJobID = jobs.first?.id }
            applyRequest()
        }
        .onChange(of: viewModel.requestedJobRun) { _, _ in applyRequest() }
        .onChange(of: selectedJobID) { _, _ in openRunID = nil }
        .onDisappear { store.flushPendingWrites() }
        .alert("Could not create the job", isPresented: Binding(get: { createError != nil }, set: { if !$0 { createError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(createError ?? "")
        }
    }

    private func applyRequest() {
        guard let request = viewModel.requestedJobRun, request.projectID == projectID else { return }
        viewModel.requestedJobRun = nil
        store.reload(projectID)
        selectedJobID = request.jobID
        // Selecting clears the open run; set it after that change has gone through.
        let runID = request.runID
        Task { @MainActor in openRunID = runID }
    }

    // MARK: - List

    private var jobList: some View {
        VStack(spacing: 0) {
            if jobs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                    Text("No jobs yet")
                        .font(DesignSystem.Typography.subheadline)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text("A job is a prompt Claude runs on a schedule in this workspace.")
                        .font(DesignSystem.Typography.footnote)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedJobID) {
                    ForEach(jobs) { job in
                        ScheduledJobRow(job: job, key: ScheduledJobKey(projectID: projectID, jobID: job.id))
                            .tag(job.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Button {
                    createJob()
                } label: {
                    Label("New Job", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if let running = store.running, running.key.projectID != projectID {
                    Text("Another job is running")
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
    }

    private func createJob() {
        do {
            let job = try store.create(in: projectID, title: "New Job", prompt: "")
            selectedJobID = job.id
        } catch {
            createError = error.localizedDescription
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let jobID = selectedJobID, jobs.contains(where: { $0.id == jobID }) {
            let key = ScheduledJobKey(projectID: projectID, jobID: jobID)
            if let runID = openRunID {
                ScheduledJobRunView(key: key, runID: runID) { openRunID = nil }
                    .id(runID)
            } else {
                ScheduledJobEditorView(key: key, onOpenRun: { openRunID = $0 }, onDeleted: {
                    selectedJobID = jobs.first?.id
                })
                .id(jobID)
            }
        } else {
            VStack(spacing: 10) {
                Text(jobs.isEmpty ? "Create a job to have Claude work on a schedule" : "Select a job")
                    .font(DesignSystem.Typography.callout)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                if jobs.isEmpty {
                    Button("New Job", action: createJob)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// One job in the list: on/off dot, title, what happens next, and the last run's outcome.
private struct ScheduledJobRow: View {
    @Environment(AppViewModel.self) private var viewModel
    let job: ScheduledJob
    let key: ScheduledJobKey

    private var store: ScheduledJobStore { viewModel.scheduledJobs }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(job.enabled ? DesignSystem.Colors.success : DesignSystem.Colors.textTertiary.opacity(0.5))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(DesignSystem.Typography.subheadline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.isRunning(key) {
                ProgressView().controlSize(.small)
            } else if let last = store.latestRuns[key] {
                ScheduledJobStatusIcon(status: last.status)
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if store.isRunning(key) { return "Running" }
        if store.isQueued(key) { return "Waiting to run" }
        if !job.enabled { return "Off" }
        if job.prompt.isEmpty { return "No prompt yet" }
        guard let next = store.nextRun(of: job) else { return job.schedule.summary }
        return "Next: " + ScheduledJobFormat.when(next)
    }
}

/// Success, failure or stop as a small coloured symbol.
struct ScheduledJobStatusIcon: View {
    let status: ScheduledJobRun.Status

    var body: some View {
        switch status {
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DesignSystem.Colors.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(DesignSystem.Colors.error)
        case .cancelled:
            Image(systemName: "stop.circle.fill").foregroundStyle(DesignSystem.Colors.textTertiary)
        }
    }
}

/// Date and duration wording shared by the jobs views.
enum ScheduledJobFormat {
    /// "Today 08:00", "Tomorrow 08:00", "Mon 16 Nov, 08:00".
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ", " + time
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min \(total % 60) s" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func trigger(_ trigger: ScheduledJobRun.Trigger) -> String? {
        switch trigger {
        case .schedule: return nil
        case .catchUp: return "caught up"
        case .manual: return "run by hand"
        }
    }
}
