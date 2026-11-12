// Purpose: ScheduledJobEditorView, the right side of the Jobs tab for one job: title, on/off, Run
//          Now, prompt, schedule (hourly, daily, weekly, with weekdays), access level, model,
//          notifications, and the list of past runs.
// Dependencies: Sources/App/Supporting/ScheduledJobStore.swift (edits autosave through update),
//               Sources/App/Models/ScheduledJob.swift, Sources/App/Models/JobSchedule.swift,
//               Sources/App/Views/ScheduledJobsView.swift (ScheduledJobStatusIcon, ScheduledJobFormat)
// RBAC: Shows and sets the job's access level (read only, standard, full).
// Dependents: Sources/App/Views/ScheduledJobsView.swift
// Notes: Every control writes through a binding into the store, which saves by itself (no Save
//        button). The run list rereads the files when the store reports a new run.

import AppKit
import SwiftUI

struct ScheduledJobEditorView: View {
    @Environment(AppViewModel.self) private var viewModel
    let key: ScheduledJobKey
    let onOpenRun: (String) -> Void
    let onDeleted: () -> Void

    @State private var runs: [ScheduledJobRun] = []
    @State private var confirmingDelete = false

    private var store: ScheduledJobStore { viewModel.scheduledJobs }

    private var job: ScheduledJob? { store.job(key) }

    private func binding<Value>(_ path: WritableKeyPath<ScheduledJob, Value>, default value: Value) -> Binding<Value> {
        Binding(
            get: { job?[keyPath: path] ?? value },
            set: { newValue in
                guard var edited = job else { return }
                edited[keyPath: path] = newValue
                store.update(in: key.projectID, edited)
            })
    }

    var body: some View {
        if let job {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(job)
                    promptSection
                    scheduleSection(job)
                    accessSection(job)
                    settingsSection
                    runsSection
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear(perform: loadRuns)
            .onChange(of: store.runsRevision) { _, _ in loadRuns() }
            .confirmationDialog("Delete \"\(job.title)\"?", isPresented: $confirmingDelete) {
                Button("Delete Job", role: .destructive) {
                    store.delete(key)
                    onDeleted()
                }
            } message: {
                Text("The job and its \(runs.count) run(s) are removed from the workspace. Git keeps them in the history.")
            }
        }
    }

    private func loadRuns() {
        runs = store.runs(key, limit: 50)
    }

    // MARK: - Header

    private func header(_ job: ScheduledJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                TextField("Job title", text: binding(\.title, default: ""))
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.title3)
                Spacer(minLength: 8)
                Toggle("Active", isOn: binding(\.enabled, default: false))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Run on the schedule")
                runButton(job)
                Menu {
                    Button("Show File in Workspace") {
                        viewModel.workspaceEditors.state(for: key.projectID)
                            .open(ScheduledJobFiles.jobFile(key.jobID, in: viewModel.scheduledJobs.repoURL(key.projectID)))
                        viewModel.selectedProjectID = key.projectID
                        viewModel.requestedProjectTab = .workspaces
                    }
                    Divider()
                    Button("Delete Job…", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text(statusLine(job))
                .font(DesignSystem.Typography.footnote)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private func runButton(_ job: ScheduledJob) -> some View {
        if store.isRunning(key) || store.isQueued(key) {
            Button {
                store.cancel(key)
            } label: {
                Label(store.isRunning(key) ? "Stop" : "Cancel", systemImage: "stop.fill")
            }
            .controlSize(.small)
        } else {
            Button {
                store.flushPendingWrites()
                store.runNow(key)
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .controlSize(.small)
            .disabled(job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(job.prompt.isEmpty ? "Write a prompt first" : "Run once now, outside the schedule")
        }
    }

    private func statusLine(_ job: ScheduledJob) -> String {
        if let running = store.running, running.key == key {
            return "Running since \(running.started.formatted(date: .omitted, time: .shortened))"
        }
        if store.isQueued(key) { return "Waiting for another job to finish" }
        if !job.enabled { return "Off: runs only with Run Now" }
        if job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a prompt so the job can run" }
        guard let next = store.nextRun(of: job) else { return job.schedule.summary }
        return "\(job.schedule.summary). Next run \(ScheduledJobFormat.when(next))."
    }

    // MARK: - Prompt

    private var promptSection: some View {
        section("Prompt", note: "What Claude does on every run. Its final answer is saved as the run's result.") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: binding(\.prompt, default: ""))
                    .font(DesignSystem.Typography.callout)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 140)
                if job?.prompt.isEmpty ?? true {
                    Text("For example: Summarize yesterday's meetings of this project and list open decisions.")
                        .font(DesignSystem.Typography.callout)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(DesignSystem.Colors.card, in: RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius).stroke(DesignSystem.Colors.border))
        }
    }

    // MARK: - Schedule

    private func scheduleSection(_ job: ScheduledJob) -> some View {
        let schedule = binding(\.schedule, default: JobSchedule())
        return section("Schedule") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: schedule.cadence) {
                    ForEach(JobSchedule.Cadence.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                HStack(spacing: 8) {
                    switch job.schedule.cadence {
                    case .daily:
                        Text("At")
                        timePicker(schedule.time)
                    case .hourly:
                        Text("Every hour from")
                        timePicker(schedule.time)
                        Text("to")
                        timePicker(schedule.until)
                    case .weekly:
                        Text("On")
                        Picker("", selection: schedule.weekday) {
                            ForEach(JobWeekday.weekOrder, id: \.self) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("at")
                        timePicker(schedule.time)
                    }
                }
                .font(DesignSystem.Typography.callout)

                if job.schedule.cadence != .weekly {
                    HStack(spacing: 6) {
                        ForEach(JobWeekday.weekOrder, id: \.self) { day in
                            dayChip(day, days: schedule.days)
                        }
                    }
                }
                Text("Runs only while MinuteMind is open. A run missed while the Mac was asleep or the app was closed is made up once.")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
    }

    private func timePicker(_ time: Binding<JobTime>) -> some View {
        DatePicker(
            "",
            selection: Binding(
                get: {
                    Calendar.current.date(bySettingHour: time.wrappedValue.hour, minute: time.wrappedValue.minute, second: 0, of: Date()) ?? Date()
                },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    time.wrappedValue = JobTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                }),
            displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.stepperField)
            .fixedSize()
    }

    /// A weekday on or off. Empty days mean every day, so the chips show all as on then.
    private func dayChip(_ day: JobWeekday, days: Binding<Set<JobWeekday>>) -> some View {
        let all = Set(JobWeekday.allCases)
        let current = days.wrappedValue.isEmpty ? all : days.wrappedValue
        let isOn = current.contains(day)
        return Button {
            var next = current
            if isOn { next.remove(day) } else { next.insert(day) }
            // At least one day stays on; all seven are stored as "every day".
            guard !next.isEmpty else { return }
            days.wrappedValue = next == all ? [] : next
        } label: {
            Text(day.shortName)
                .font(DesignSystem.Typography.footnote.weight(isOn ? .semibold : .regular))
                .frame(width: 40, height: 24)
                .foregroundStyle(isOn ? Color.white : DesignSystem.Colors.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? DesignSystem.Colors.accent : DesignSystem.Colors.surfaceSecondary))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Access

    private func accessSection(_ job: ScheduledJob) -> some View {
        section("Access", note: "What Claude may do during a run. Nobody can confirm anything while it runs.") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: binding(\.access, default: .standard)) {
                    ForEach(ScheduledJob.Access.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                Label(job.access.explanation, systemImage: job.access == .full ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(DesignSystem.Typography.footnote)
                    .foregroundStyle(job.access == .full ? DesignSystem.Colors.warning : DesignSystem.Colors.textSecondary)
            }
        }
    }

    // MARK: - Model and notifications

    private var settingsSection: some View {
        HStack(alignment: .top, spacing: 40) {
            section("Model") {
                Picker("", selection: binding(\.model, default: nil)) {
                    Text("App setting (\(viewModel.automationSettings.claudeModel.capitalized))").tag(String?.none)
                    Divider()
                    ForEach(ScheduledJob.models, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            section("Notification") {
                Picker("", selection: binding(\.notify, default: .always)) {
                    ForEach(ScheduledJob.Notify.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Runs

    private var runsSection: some View {
        section("Runs") {
            if runs.isEmpty {
                Text("No runs yet.")
                    .font(DesignSystem.Typography.footnote)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(runs) { run in
                        Button { onOpenRun(run.id) } label: { runRow(run) }
                            .buttonStyle(.plain)
                        if run.id != runs.last?.id { Divider() }
                    }
                }
                .background(DesignSystem.Colors.card, in: RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius))
                .overlay(RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius).stroke(DesignSystem.Colors.border))
            }
        }
    }

    private func runRow(_ run: ScheduledJobRun) -> some View {
        HStack(spacing: 10) {
            ScheduledJobStatusIcon(status: run.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ScheduledJobFormat.when(run.started))
                        .font(DesignSystem.Typography.subheadline)
                    if let trigger = ScheduledJobFormat.trigger(run.trigger) {
                        Text(trigger)
                            .font(DesignSystem.Typography.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(DesignSystem.Colors.surfaceSecondary, in: Capsule())
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    Text(ScheduledJobFormat.duration(run.duration))
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                if !run.headline.isEmpty {
                    Text(run.headline)
                        .font(DesignSystem.Typography.footnote)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Layout

    private func section<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.subheadline.weight(.semibold))
                if let note {
                    Text(note)
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }
            content()
        }
    }
}
