// Purpose: ScheduledJobRunView, one run of a job in place of the job's editor: a way back to the
//          job, "Open in Workspace" for the run's Markdown file, the run's facts (when, outcome,
//          duration, trigger, model, access) and Claude's result rendered as Markdown.
// Dependencies: Sources/App/Supporting/ScheduledJobStore.swift (run, job title),
//               Sources/App/ViewModels/AppViewModel+ScheduledJobs.swift (openJobRunInWorkspace),
//               Sources/App/Components/MarkdownDisplayView.swift,
//               Sources/App/Views/ScheduledJobsView.swift (ScheduledJobStatusIcon, ScheduledJobFormat)
// RBAC: None.
// Dependents: Sources/App/Views/ScheduledJobsView.swift

import SwiftUI

struct ScheduledJobRunView: View {
    @Environment(AppViewModel.self) private var viewModel
    let key: ScheduledJobKey
    let runID: String
    let onBack: () -> Void

    @State private var run: ScheduledJobRun?

    private var store: ScheduledJobStore { viewModel.scheduledJobs }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Label(store.job(key)?.title ?? "Job", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    viewModel.openJobRunInWorkspace(key, runID: runID)
                } label: {
                    Label("Open in Workspace", systemImage: "doc.text")
                }
                .controlSize(.small)
                .disabled(run == nil)
            }
            .padding(.horizontal, 24)
            .frame(height: 44)
            Divider()
            if let run {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        facts(run)
                        Divider()
                        MarkdownDisplayView(content: run.output)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
                Text("This run's file is gone.")
                    .font(DesignSystem.Typography.callout)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .onAppear { run = store.run(key, runID: runID) }
    }

    private func facts(_ run: ScheduledJobRun) -> some View {
        HStack(spacing: 10) {
            ScheduledJobStatusIcon(status: run.status)
            Text(ScheduledJobFormat.when(run.started))
                .font(DesignSystem.Typography.headline)
            Text(statusLabel(run.status))
                .foregroundStyle(run.status == .failed ? DesignSystem.Colors.error : DesignSystem.Colors.textSecondary)
            Text("·").foregroundStyle(DesignSystem.Colors.textTertiary)
            Text(ScheduledJobFormat.duration(run.duration))
            if let trigger = ScheduledJobFormat.trigger(run.trigger) {
                Text("·").foregroundStyle(DesignSystem.Colors.textTertiary)
                Text(trigger)
            }
            Text("·").foregroundStyle(DesignSystem.Colors.textTertiary)
            Text("\(run.model.capitalized), \(run.access.label.lowercased()) access")
        }
        .font(DesignSystem.Typography.footnote)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
    }

    private func statusLabel(_ status: ScheduledJobRun.Status) -> String {
        switch status {
        case .succeeded: return "Finished"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }
}
