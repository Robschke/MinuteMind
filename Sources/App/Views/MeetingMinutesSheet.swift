import SwiftUI

struct MeetingMinutesSheet: View {
    @Environment(AppViewModel.self) var viewModel
    @Environment(\.dismiss) private var dismiss
    let session: RecordingSession
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
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
                } else {
                    ScrollView {
                        MarkdownDisplayView(content: content)
                            .padding()
                    }
                }
            }
            .navigationTitle("Meeting Minutes")
            .navigationSubtitle(session.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        copyContentToClipboard()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .help("Copy content to clipboard (formatted for Teams/Slack)")
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            do {
                content = try viewModel.readMinutesContent(for: session)
                isLoading = false
            } catch {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }
    
    private func copyContentToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }
}
