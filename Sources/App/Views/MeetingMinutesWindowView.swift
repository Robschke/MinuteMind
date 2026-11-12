// Purpose: MeetingMinutesWindowView, the Summary window of one meeting: read, edit, copy and
//          update the summary.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (readMinutesContent, saveMinutesContent,
//               processMeeting, isGeneratingMinutes)
// Used by: Sources/App/MinuteMindApp.swift ("meeting-minutes" window group)
// Notes: "Update Summary" (user decision 2026-10-05) reruns Process for the meeting, e.g. after
//        naming speakers; the window reloads the file when processing ends, so it never shows a
//        stale summary. It is hidden while editing, so an update cannot overwrite unsaved edits.

import MarkdownUI
import SwiftUI

struct MeetingMinutesWindowView: View {
    @Environment(AppViewModel.self) var viewModel
    let sessionID: UUID

    @State private var content: String = ""
    @State private var isEditing = false
    @State private var editedContent: String = ""
    @State private var isLoading = true
    @State private var error: String?

    var session: RecordingSession? {
        viewModel.sessions.first(where: { $0.id == sessionID })
    }

    private var isUpdating: Bool {
        session.map { viewModel.isGeneratingMinutes(for: $0) } ?? false
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading Minutes...")
            } else if let error = error {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Failed to load minutes")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let session = session {
                VStack(spacing: 0) {
                    // Toolbar area
                    HStack {
                        Text(session.title)
                            .font(.headline)

                        Spacer()

                        if isEditing {
                            Button("Cancel") {
                                isEditing = false
                                editedContent = content
                            }
                            .keyboardShortcut(.cancelAction)

                            Button("Save") {
                                saveChanges()
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        } else {
                            if isUpdating {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Updating\u{2026}")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Button {
                                    viewModel.processMeeting(sessionID)
                                } label: {
                                    Label("Update Summary", systemImage: "arrow.clockwise")
                                }
                                .disabled(!viewModel.canGenerateMeetingMinutes)
                                .help("Write the summary again from the current transcript, e.g. after naming speakers")
                            }

                            Button {
                                isEditing = true
                                editedContent = content
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .disabled(isUpdating)
                            
                            Button {
                                copyContentToClipboard()
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .help("Copy content to clipboard (formatted for Teams/Slack)")
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    if isEditing {
                        TextEditor(text: $editedContent)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                    } else {
                        ScrollView {
                            MarkdownDisplayView(content: content)
                                .padding()
                        }
                    }
                }
            } else {
                Text("Session not found")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            loadContent()
        }
        .onChange(of: isUpdating) { _, updating in
            if !updating, !isEditing { loadContent() }
        }
    }

    private func loadContent() {
        guard let session = session else { return }
        do {
            content = try viewModel.readMinutesContent(for: session)
            editedContent = content
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }
    
    private func copyContentToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }

    private func saveChanges() {
        guard let session = session else { return }
        do {
            try viewModel.saveMinutesContent(for: session, content: editedContent)
            content = editedContent
            isEditing = false
        } catch {
            self.error = "Failed to save: \(error.localizedDescription)"
        }
    }
}
