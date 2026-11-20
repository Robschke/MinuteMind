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
                VStack(alignment: .leading, spacing: .space(4)) {
                    Text("Import File")
                        .font(.themed(.headline))
                    Text(fileName)
                        .font(.themed(.subheadline))
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
                        HStack(spacing: .space(6)) {
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
                VStack(spacing: .space(16)) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.themed(size: 48))
                        .foregroundColor(DesignSystem.Colors.warning)
                    
                    Text("Failed to Extract Text")
                        .font(.themed(.headline))
                    
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
                VStack(spacing: .space(8)) {
                    HStack {
                        Text("Extracted Text")
                            .font(.themed(.subheadline))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text("\(editedText.count) characters")
                            .font(.themed(.caption))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, .space(8))
                    
                    // Text editor with border
                    TextEditor(text: $editedText)
                        .font(.themed(.body, design: .default))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.space(8))
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(.corner(6))
                        .overlay(
                            RoundedRectangle(cornerRadius: .corner(6))
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.horizontal)
                    
                    // Help text
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                        Text("Review and edit the extracted text before committing to the knowledge base. Embeddings will be generated for semantic search.")
                            .font(.themed(.caption))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, .space(8))
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 700, maxWidth: 1000, minHeight: 500, idealHeight: 600, maxHeight: 900)
    }
}
