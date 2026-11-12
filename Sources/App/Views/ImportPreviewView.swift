import SwiftUI

struct ImportPreviewView: View {
    let fileName: String
    @Binding var extractedText: String
    @Binding var isCommitting: Bool
    @Binding var error: String?
    let onCommit: () -> Void
    let onCancel: () -> Void
    
    @State private var editedText: String
    
    init(
        fileName: String,
        extractedText: Binding<String>,
        isCommitting: Binding<Bool>,
        error: Binding<String?>,
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.fileName = fileName
        self._extractedText = extractedText
        self._isCommitting = isCommitting
        self._error = error
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._editedText = State(initialValue: extractedText.wrappedValue)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import File")
                        .font(.headline)
                    Text(fileName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                Button {
                    extractedText = editedText
                    onCommit()
                } label: {
                    if isCommitting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Committing...")
                        }
                    } else {
                        Text("Commit to Knowledge Base")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCommitting)
            }
            .padding()
            
            Divider()
            
            // Content area
            if let error = error {
                // Show extraction error
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    
                    Text("Failed to Extract Text")
                        .font(.headline)
                    
                    Text(error)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Try Another File") {
                        onCancel()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Text("Extracted Text")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text("\(editedText.count) characters")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    // Text editor with border
                    TextEditor(text: $editedText)
                        .font(.system(.body, design: .default))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.horizontal)
                    
                    // Help text
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                        Text("Review and edit the extracted text before committing to the knowledge base. Embeddings will be generated for semantic search.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 700, maxWidth: 1000, minHeight: 500, idealHeight: 600, maxHeight: 900)
    }
}
