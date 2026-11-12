// Purpose: Inline viewers for the workspace editor pane: images (NSImageView) and PDFs
//          (PDFKit), reloaded when the file changes on disk, plus their header detail
//          ("1200 × 800 px", "12 pages").
// Dependencies: AppKit, PDFKit, ImageIO, Sources/App/Supporting/ThemeStore.swift (background)
// Used by: Sources/App/Views/WorkspaceEditorPane.swift
// Notes: Decisions (2026-10-13): VS Code shows images inline, so images and PDFs open in the
//        editor pane instead of only through Quick Look; audio, video and Office files keep
//        Quick Look and their default app. Images fit the pane and are never enlarged beyond
//        their pixel size (small icons stay crisp), centred on the theme's card colour;
//        animated GIFs play. No zoom controls: "Open in <App>" covers close inspection. PDFs
//        scroll continuously, scaled to the pane's width, and keep the page they were on when
//        the file is rewritten (e.g. Claude regenerates a report).

import AppKit
import ImageIO
import PDFKit
import SwiftUI

/// An image file, fitted into the pane without enlarging it.
struct WorkspaceImageView: NSViewRepresentable {
    let url: URL
    /// Changes when the file changed on disk.
    let revision: Int

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.isEditable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = NSImage(contentsOf: url)
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        view.image = NSImage(contentsOf: url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var revision = 0
    }
}

/// A PDF, scrolling continuously at the pane's width.
struct WorkspacePDFView: NSViewRepresentable {
    let url: URL
    /// Changes when the file changed on disk.
    let revision: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = ThemeStore.shared.theme.card.nsColor
        view.document = PDFDocument(url: url)
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
        view.document = PDFDocument(url: url)
        if let page = view.document?.page(at: min(pageIndex, max(0, (view.document?.pageCount ?? 1) - 1))) {
            view.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var revision = 0
    }
}

enum WorkspaceFilePreviewInfo {
    /// "1200 × 800 px" for an image, "12 pages" for a PDF; nil when unknown.
    static func detail(for url: URL, kind: WorkspaceFileKind) -> String? {
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return "\(width) × \(height) px"
        case .pdf:
            guard let count = PDFDocument(url: url)?.pageCount else { return nil }
            return count == 1 ? "1 page" : "\(count) pages"
        case .text:
            return nil
        }
    }
}
