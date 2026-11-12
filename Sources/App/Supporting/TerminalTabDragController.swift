// Purpose: TerminalTabDragController, dragging a workspace Claude tab out of its strip: a ghost
//          (snapshot of the terminal under its title) follows the pointer across windows and
//          screens; on release the tab lands in a pane under the pointer (shown there or split
//          beside it), moves into the strip under the pointer, or gets a new window.
// Dependencies: Sources/App/Supporting/WorkspaceTerminalStore.swift (drop zones, dropTarget,
//               pendingWindowFrames), Sources/App/Supporting/WorkspaceTerminalSplit.swift
//               (DropZone), AppKit
// Used by: Sources/App/Views/WorkspaceTerminalPane.swift (the tab's drag gesture)
// Notes: User request 2026-10-13. A SwiftUI DragGesture drives it (the window that got the mouse
//        down keeps receiving drags outside its bounds); an AppKit dragging session would need
//        drop destinations inside SwiftTerm's views. Design review decisions: the tab stays put
//        inside its strip (no reordering yet); the drag starts once the pointer is 24 pt outside
//        the tab strip; only panes of the same project are targets (a session is tied to its
//        repo folder); Esc cancels; the new window gets the source pane's size and is placed so
//        the pointer sits on its tab strip, clamped to the screen. Reduce Motion: the ghost
//        appears without fading.
//        Split panes (user request 2026-10-13, VS Code style): over the panes of any strip of the
//        project, its own included, the pane under the pointer shows its drop zone (edge: split
//        there, centre: show it there; the pane draws the highlight). Releasing over its own
//        strip where no zone applies does nothing (earlier it opened a window); outside every
//        strip it still opens a window.

import AppKit
import SwiftUI

@MainActor
final class TerminalTabDragController {
    enum Outcome {
        /// Released inside its strip or cancelled.
        case none
        /// Dropped onto another strip's tab strip (same project).
        case move(to: UUID)
        /// Dropped on a pane (any strip of the project, its own included): show it there or split.
        case place(groupID: UUID, paneID: UUID, zone: WorkspaceTerminalSplit.DropZone)
        /// Dropped elsewhere: a new window at this frame (screen coordinates).
        case newWindow(frame: NSRect)
        /// The only tab of a window was dragged: the window itself goes to this top-left point.
        case moveWindow(topLeft: NSPoint)
    }

    static let shared = TerminalTabDragController()

    private var session: WorkspaceTerminalSession?
    private var sourceGroupID: UUID?
    private weak var store: WorkspaceTerminalStore?
    private var tornOut = false
    private var cancelled = false
    private var ghost: NSPanel?
    private var escapeMonitor: Any?

    /// Distance the pointer leaves the strip by before the tab tears off.
    private static let tearOffDistance: CGFloat = 24
    private static let ghostSize = NSSize(width: 260, height: 170)

    /// Called on every drag change of a tab.
    func update(session: WorkspaceTerminalSession, from groupID: UUID, store: WorkspaceTerminalStore) {
        if self.session?.id != session.id { begin(session: session, groupID: groupID, store: store) }
        guard !cancelled else { return }
        let point = NSEvent.mouseLocation
        if !tornOut, let strip = sourceStripFrame(), !strip.insetBy(dx: -Self.tearOffDistance, dy: -Self.tearOffDistance).contains(point) {
            tornOut = true
            showGhost()
        }
        guard tornOut else { return }
        ghost?.setFrameTopLeftPoint(NSPoint(x: point.x - 30, y: point.y + 12))
        let target = store.dropTarget(
            at: point, session: session.id, projectID: session.projectID, source: groupID, below: ghost?.windowNumber ?? 0)
        if store.dropTarget != target { store.dropTarget = target }
    }

    /// Called when the drag ends; says what the pane should do.
    func end() -> Outcome {
        defer { reset() }
        guard let session, let sourceGroupID, let store, tornOut, !cancelled else { return .none }
        let point = NSEvent.mouseLocation
        switch store.dropTarget(
            at: point, session: session.id, projectID: session.projectID, source: sourceGroupID, below: ghost?.windowNumber ?? 0)
        {
        case .strip(let target): return .move(to: target)
        case .pane(let groupID, let paneID, let zone): return .place(groupID: groupID, paneID: paneID, zone: zone)
        case .ownStrip: return .none
        case nil: break
        }
        let source = store.group(sourceGroupID)
        let size = paneSize(of: sourceGroupID, in: store)
        // Pointer on the new window's tab strip: below the title bar, a little into the first tab.
        var frame = NSRect(x: point.x - 60, y: point.y + 44 - size.height, width: size.width, height: size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            frame = Self.clamp(frame, to: screen.visibleFrame)
        }
        if source?.isWindow == true, source?.sessionIDs.count == 1 {
            return .moveWindow(topLeft: NSPoint(x: frame.minX, y: frame.maxY))
        }
        return .newWindow(frame: frame)
    }

    private func begin(session: WorkspaceTerminalSession, groupID: UUID, store: WorkspaceTerminalStore) {
        reset()
        self.session = session
        self.sourceGroupID = groupID
        self.store = store
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
    }

    private func cancel() {
        cancelled = true
        ghost?.orderOut(nil)
        store?.dropTarget = nil
    }

    private func reset() {
        ghost?.orderOut(nil)
        ghost = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if store?.dropTarget != nil { store?.dropTarget = nil }
        session = nil
        sourceGroupID = nil
        store = nil
        tornOut = false
        cancelled = false
    }

    /// The source pane's tab strip on screen (the top of its drop zone).
    private func sourceStripFrame() -> NSRect? {
        guard let sourceGroupID, let view = store?.dropZoneView(for: sourceGroupID), let window = view.window else { return nil }
        let pane = window.convertToScreen(view.convert(view.bounds, to: nil))
        let height = WorkspaceTerminalPane.tabStripHeight
        return NSRect(x: pane.minX, y: pane.maxY - height, width: pane.width, height: height)
    }

    private func paneSize(of groupID: UUID, in store: WorkspaceTerminalStore) -> NSSize {
        let pane = store.dropZoneView(for: groupID)?.bounds.size ?? NSSize(width: 760, height: 560)
        // Plus the window's title bar; never below the window's minimum.
        return NSSize(width: max(520, pane.width), height: max(360, pane.height + 28))
    }

    static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var result = frame
        result.size.width = min(frame.width, visible.width)
        result.size.height = min(frame.height, visible.height)
        result.origin.x = min(max(frame.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(frame.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    // MARK: - Ghost

    private func showGhost() {
        guard let session else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.ghostSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        let content = TabGhostView(title: session.displayName, snapshot: Self.snapshot(of: session.view))
        panel.contentView = NSHostingView(rootView: content.frame(width: Self.ghostSize.width, height: Self.ghostSize.height))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 0.9 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 0.9 }
        }
        ghost = panel
    }

    private static func snapshot(of view: NSView) -> NSImage? {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The dragged tab: its title over a scaled-down picture of the terminal.
private struct TabGhostView: View {
    let title: String
    let snapshot: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(.bar)
            Group {
                if let snapshot {
                    Image(nsImage: snapshot).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .textBackgroundColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
    }
}
