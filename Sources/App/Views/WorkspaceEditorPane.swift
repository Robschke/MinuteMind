// Purpose: WorkspaceEditorPane, the workspace's file pane between the file tree and Claude: a
//          text, code or Markdown file from the project repo, read rendered or edited in place,
//          or an image or PDF shown inline.
// Dependencies: Sources/App/Supporting/WorkspaceEditorStore.swift (WorkspaceDocument, autosave,
//               disk reload), Sources/App/Views/WorkspaceCodeEditor.swift (highlighted editor,
//               line numbers), Sources/App/Views/WorkspaceFilePreviews.swift (image, PDF),
//               Sources/App/Components/MarkdownDisplayView.swift (MarkdownUI), AppKit
// Used by: Sources/App/Views/ProjectWorkspaceView.swift
// Notes: Decisions (design review 3): Markdown opens rendered with a Preview / Edit switch, its
//        YAML frontmatter shown as a small metadata row instead of raw text; plain text opens
//        for editing. The editor is an NSTextView (undo, find bar on Cmd+F, no smart quotes or
//        dashes so Markdown syntax survives) in SF Mono 12. Saving is automatic; the header says
//        "Edited" while unsaved and "Saved" / "Updated on disk" for 2 s, so Claude's changes never
//        appear silently. Cmd+S saves at once. Conflicts with the disk show a banner.
//        "Open in <App>" and a double click in the tree open the file outside MinuteMind.
//        2026-10-13 (all common formats, like VS Code): code and config files open with syntax
//        colours and line numbers (WorkspaceCodeEditor); Markdown's Edit mode is coloured too.
//        Images and PDFs show inline with their size or page count in the header. Large text
//        (2 to 10 MB) opens read-only and the header says "Read-only, large file" instead of
//        hiding why typing does nothing. The pane uses the theme's card colour, like the editor.
//        No JSON "Format" action: Foundation's JSON round trip reorders keys and rewrites
//        numbers, which would silently change the user's file.

import AppKit
import SwiftUI

struct WorkspaceEditorPane: View {
    let document: WorkspaceDocument
    let repo: URL
    let onClose: () -> Void

    @State private var now = Date()
    /// Image size or PDF page count, read once per revision.
    @State private var mediaDetail: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let conflict = document.conflict { conflictBanner(conflict) }
            if let error = document.saveError {
                banner(text: "Could not save: \(error)", systemImage: "exclamationmark.triangle.fill") {
                    Button("Try Again") { document.save() }
                }
            }
            content
        }
        .background(DesignSystem.Colors.card)
        .background {
            Button("Save") { document.save() }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task(id: document.lastEvent?.at) {
            // Lets the "Saved" / "Updated on disk" note fade after 2 s.
            now = Date()
            try? await Task.sleep(for: .seconds(2.1))
            now = Date()
        }
        .task(id: document.revision) {
            guard !document.kind.isText else { return }
            let url = document.url
            let kind = document.kind
            mediaDetail = await Task.detached(priority: .utility) {
                WorkspaceFilePreviewInfo.detail(for: url, kind: kind)
            }.value
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: document.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(document.url.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(relativePath)
            statusNote
            Spacer(minLength: 8)
            if document.isMarkdown {
                Picker("Mode", selection: Bindable(document).isEditingMarkdown) {
                    Text("Preview").tag(false)
                    Text("Edit").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Button {
                document.save()
                NSWorkspace.shared.open(document.url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in \(appName)")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    @ViewBuilder
    private var statusNote: some View {
        let text: String? = if document.isDirty {
            "Edited"
        } else if let event = document.lastEvent, now.timeIntervalSince(event.at) < 2 {
            event.kind == .saved ? "Saved" : "Updated on disk"
        } else if document.kind.isText, document.isReadOnly {
            "Read-only, large file"
        } else if !document.kind.isText {
            mediaDetail
        } else {
            nil
        }
        if let text {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }

    private var relativePath: String {
        document.url.path.replacingOccurrences(of: repo.path + "/", with: "")
    }

    private var appName: String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: document.url) else { return "Default App" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: - Banners

    @ViewBuilder
    private func conflictBanner(_ conflict: WorkspaceDocument.Conflict) -> some View {
        switch conflict {
        case .changedOnDisk:
            banner(text: "This file changed on disk while you were editing.", systemImage: "exclamationmark.arrow.triangle.2.circlepath") {
                Button("Reload") { document.reloadFromDisk() }
                Button("Keep Mine") { document.keepMine() }
            }
        case .deletedOnDisk:
            banner(text: "This file was moved or deleted.", systemImage: "trash") {
                Button("Save Again") { document.keepMine() }
                Button("Close", action: onClose)
            }
        }
    }

    private func banner(text: String, systemImage: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text).lineLimit(2)
            Spacer()
            actions().controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch document.kind {
        case .image:
            WorkspaceImageView(url: document.url, revision: document.revision)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .pdf:
            WorkspacePDFView(url: document.url, revision: document.revision)
        case .text(let language):
            textContent(language: language)
        }
    }

    @ViewBuilder
    private func textContent(language: String?) -> some View {
        if document.isMarkdown, !document.isEditingMarkdown {
            let parts = WorkspaceEditorStore.splitFrontmatter(document.text)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !parts.fields.isEmpty { frontmatterRow(parts.fields) }
                    MarkdownDisplayView(content: parts.body)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            WorkspaceCodeEditor(text: Bindable(document).text, language: language, isEditable: !document.isReadOnly)
        }
    }

    private func frontmatterRow(_ fields: [(key: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(fields.prefix(8).enumerated()), id: \.offset) { _, field in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(field.key)
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 70, alignment: .leading)
                    Text(field.value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(.system(size: 11))
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}
