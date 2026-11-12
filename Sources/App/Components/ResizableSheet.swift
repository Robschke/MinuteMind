// Purpose: Modifier that makes a SwiftUI sheet window user-resizable on macOS, and keeps the size
//          the user dragged it to.
// Dependencies: AppKit (NSViewRepresentable, NSWindow notifications)
// RBAC: None.
// Dependents: every sheet that applies .resizableSheet() (transcript, notes, event details, ...)
// Notes: SwiftUI .sheet() presents via NSPanel whose styleMask lacks .resizable by default.
//        Setting maxWidth/maxHeight to .infinity only controls content sizing, not the window
//        chrome. This modifier reaches into the NSWindow after the sheet appears and inserts
//        .resizable into the styleMask so the user can drag any edge or corner to resize.
//        Apply to the *content* view inside the .sheet closure, not to the .sheet modifier itself.
//        SwiftUI also re-applies the sheet's own size whenever the content updates (a hover is
//        enough), which snapped a dragged-out sheet back to its minimum size (2026-10-04). So the
//        size at the end of each live resize is remembered, and any later resize that does not
//        come from the user is undone, keeping the top edge where it is.

import AppKit
import SwiftUI

// MARK: - Public API

extension View {
    /// Allows the sheet window this view is presented in to be user-resized by dragging.
    func resizableSheet() -> some View {
        background(ResizableWindowHelper())
    }
}

// MARK: - Implementation

private struct ResizableWindowHelper: NSViewRepresentable {
    func makeCoordinator() -> SizeKeeper { SizeKeeper() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer until after the sheet window has been created and the view is attached.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.resizable)
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-apply in case the window changes (e.g. full-screen toggle).
        nsView.window?.styleMask.insert(.resizable)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: SizeKeeper) {
        coordinator.detach()
    }

    /// Remembers the user's size and restores it when SwiftUI resizes the sheet on its own.
    @MainActor
    final class SizeKeeper {
        private weak var window: NSWindow?
        private var userSize: NSSize?
        private var restoring = false
        private var observers: [NSObjectProtocol] = []

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.userSize = self?.window?.frame.size }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreIfNeeded() }
            })
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            window = nil
        }

        private func restoreIfNeeded() {
            guard !restoring, let window, !window.inLiveResize, let size = userSize,
                  window.frame.size != size else { return }
            restoring = true
            var frame = window.frame
            frame.origin.y += frame.height - size.height  // keep the top edge in place
            frame.size = size
            // Deferred: SwiftUI is mid-layout when it resizes; setting the frame inside that
            // pass would be overwritten again.
            DispatchQueue.main.async { [weak self] in
                window.setFrame(frame, display: true)
                self?.restoring = false
            }
        }
    }
}
