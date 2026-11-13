// Purpose: CrashReportsRow, the crash report switch at the top of Settings, Help: the opt-in,
//          what a report contains, and Show Last Report with exactly what would be sent.
// Dependencies: Sources/App/Services/CrashReporter.swift (setting, latest report)
// Used by: Sources/App/Views/HelpSettingsView.swift
// Notes: Off by default; the user switches it on here or on the setup's finish page.

import SwiftUI

struct CrashReportsRow: View {
    @State private var reporter = CrashReporter.shared
    @State private var latestReport: String?
    @State private var isReportShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Send crash reports automatically", isOn: $reporter.isEnabled)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CrashReportsRow.contents)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Show Last Report") { isReportShown = true }
                    .controlSize(.small)
                    .disabled(latestReport == nil)
                    .help(latestReport == nil ? "No crash in the last 14 days." : "Shows exactly what is sent.")
            }
            .padding(.leading, 20)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .task { latestReport = await Task.detached { CrashReporter.latestReportText() }.value }
        .sheet(isPresented: $isReportShown) {
            CrashReportSheet(text: latestReport ?? "")
        }
    }

    /// What a report holds, shared with the setup's finish page.
    static let contents = "Where MinuteMind crashed, the app and macOS version and the Mac model, sent at the next launch. No recordings, transcripts or names."
}

private struct CrashReportSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last Crash Report")
                .font(.headline)
            Text("This is exactly what is sent. Nothing else leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}
