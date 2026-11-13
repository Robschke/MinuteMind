// Purpose: AppUpdateSheet, the dialog that offers a newer MinuteMind release with its release
//          notes, Later and Update.
// Dependencies: Sources/App/Services/AppUpdateChecker.swift (later, update, state),
//               Sources/App/Services/AppUpdateService.swift (Release, installed version),
//               Sources/App/Components/MarkdownDisplayView.swift (release notes)
// Used by: Sources/App/Views/ContentView.swift
// Notes: The notes are the GitHub release body, written per release in release-notes/<version>.md.
//        After Update the buttons stay disabled: MinuteMind quits within seconds and the new
//        version opens by itself.

import SwiftUI

struct AppUpdateSheet: View {
    let release: AppUpdateService.Release
    let checker: AppUpdateChecker
    @State private var notesHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MinuteMind \(release.version) is available")
                    .font(.title3.weight(.semibold))
                Text("You have \(AppUpdateService.installedVersion). MinuteMind quits, updates and opens again in about a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("What's new")
                .font(.headline)
            ScrollView {
                Group {
                    if notes.isEmpty {
                        Link("See the release on GitHub", destination: release.page)
                    } else {
                        MarkdownDisplayView(content: notes)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: NotesHeightKey.self, value: proxy.size.height)
                })
            }
            .onPreferenceChange(NotesHeightKey.self) { notesHeight = $0 }
            // As tall as the notes, scrolling only beyond 260 pt.
            .frame(height: min(max(notesHeight, 20), 260))

            Divider()

            if let error = checker.updateError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if checker.isUpdating {
                    ProgressView().controlSize(.small)
                    Text("Updating\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Later") { checker.later() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(checker.isUpdating)
                Button("Update") { checker.update() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checker.isUpdating)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(checker.isUpdating)
    }

    /// The release body without GitHub's "Full Changelog" link line.
    private var notes: String {
        release.notes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("**Full Changelog**") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct NotesHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
