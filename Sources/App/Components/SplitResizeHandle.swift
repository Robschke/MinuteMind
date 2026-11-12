// Purpose: SplitResizeHandle, the draggable line between two resizable areas (Claude and terminal
//          panes, file and Claude, file tree and the rest): a hairline with an optional small
//          grabber pill in the middle, a grab area around it, the resize cursor and double click.
// Dependencies: AppKit (cursor, mouse events), SwiftUI
// Used by: Sources/App/Views/WorkspaceTerminalPane.swift (split dividers),
//          Sources/App/Views/ProjectWorkspaceView.swift (tree, file and Claude dividers)
// Notes: The grab area is an AppKit view, not a SwiftUI hover area with NSCursor.push/pop: the
//        terminal and editor views next to it set their own cursors, and the push/pop pairs got
//        out of step, so the resize cursor came and went. Tracking areas with cursorUpdate set
//        it reliably, and AppKit keeps sending a drag to the view it started in, so the drag
//        never drops when the pointer runs ahead of the line.
//        The line keeps its 1 pt layout size; the grab area and the pill overhang it, so the
//        areas on either side do not move. The grab area reaches 7 pt to each side by default;
//        callers shorten a side where a scroller or a tab strip sits right next to the line, so
//        the handle never takes their clicks. Around the pill it widens to 10 pt on each side
//        that was not shortened, the easy target. Outside that shape the view lets clicks through (hitTest).
//        Look (after the iPadOS and Stage Manager grabbers): a flat pill, always shown (finding
//        the edge was the problem), quiet at rest, darker and a little larger on hover, darkest
//        while dragging; no accent colour, since status colours frame the panes. Its base is
//        the pane background so it does not read as a halo. Dimmed in inactive windows, darker
//        with Increase Contrast; Reduce Motion drops the size and double click animations.
//        Translations are measured in window coordinates from the mouse down, so a line that
//        moves under the pointer does not feed back into the drag. They reach the caller at
//        most 60 times a second (plus the last one on mouse up): every change resizes the
//        terminals beside the line, and Claude Code redraws its whole screen for each.
//        The drag only "begins" with the first mouse dragged event, so the first click of a
//        double click does not flash the dragging look.

import AppKit
import SwiftUI

struct SplitResizeHandle: View {
    /// The direction the line moves in: .horizontal for a vertical line between areas side by
    /// side, .vertical for a horizontal line between areas stacked.
    let axis: Axis
    var showsGrabber = true
    /// How far the grab area reaches to the left of (or above) the line, and to the right of
    /// (or below) it.
    var grabLeading: CGFloat = 7
    var grabTrailing: CGFloat = 7
    /// The colour under the pill: the background of the areas beside the line.
    var pillBase = Color(nsColor: .textBackgroundColor)
    var accessibilityLabel = "Resize"
    var accessibilityValue = ""
    /// The drag starts.
    var onBegan: () -> Void = {}
    /// Points moved along `axis` since the drag started (right and down are positive).
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void = {}
    /// Double click, typically back to the default or an even split.
    var onDoubleClick: (() -> Void)?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var isHovered = false
    @State private var isDragging = false

    /// Half the grab area's width around the pill.
    static let pillReach: CGFloat = 10
    /// Keyboard and VoiceOver adjustments move the line by this much.
    private static let adjustStep: CGFloat = 24

    var body: some View {
        let isVertical = axis == .horizontal
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .overlay {
                if showsGrabber { grabber(isVertical: isVertical) }
            }
            .overlay {
                SplitResizeGrabArea(
                    axis: axis,
                    leading: grabLeading,
                    trailing: grabTrailing,
                    pillZone: showsGrabber ? Pill.maxLength + 12 : 0,
                    onHover: { isHovered = $0 },
                    onBegan: {
                        isDragging = true
                        onBegan()
                    },
                    onChanged: onChanged,
                    onEnded: {
                        isDragging = false
                        onEnded()
                    },
                    onDoubleClick: onDoubleClick.map { action in
                        { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { action() } }
                    })
                    .frame(
                        width: isVertical ? Self.pillReach * 2 : nil,
                        height: isVertical ? nil : Self.pillReach * 2)
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                let step: CGFloat
                switch direction {
                case .increment: step = Self.adjustStep
                case .decrement: step = -Self.adjustStep
                @unknown default: return
                }
                onBegan()
                onChanged(step)
                onEnded()
            }
    }

    private enum Pill {
        static let maxLength: CGFloat = 40
    }

    private func grabber(isVertical: Bool) -> some View {
        let active = isHovered || isDragging
        let thickness: CGFloat = active ? 5 : 4
        let length: CGFloat = active ? Pill.maxLength : 32
        var strength: Double = isDragging ? 0.45 : (isHovered ? 0.35 : 0.18)
        if contrast == .increased { strength += 0.25 }
        if activeState == .inactive { strength *= 0.6 }
        return Capsule()
            .fill(pillBase)
            .overlay(Capsule().fill(Color.primary.opacity(min(1, strength))))
            .frame(width: isVertical ? thickness : length, height: isVertical ? length : thickness)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: active)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDragging)
            .allowsHitTesting(false)
    }
}

/// The AppKit grab area: cursor, hover, drag and double click. Its frame is centred on the
/// line, `SplitResizeHandle.pillReach` to each side; only the shape inside takes the mouse.
private struct SplitResizeGrabArea: NSViewRepresentable {
    let axis: Axis
    let leading: CGFloat
    let trailing: CGFloat
    /// Length along the line, centred, where the area widens to its full frame (0 for none).
    let pillZone: CGFloat
    let onHover: (Bool) -> Void
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        update(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        update(view)
    }

    private func update(_ view: GrabView) {
        let shapeChanged = view.axis != axis || view.leading != leading || view.trailing != trailing
            || view.pillZone != pillZone
        view.axis = axis
        view.leading = leading
        view.trailing = trailing
        view.pillZone = pillZone
        view.onHover = onHover
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onDoubleClick = onDoubleClick
        if shapeChanged { view.updateTrackingAreas() }
    }

    final class GrabView: NSView {
        var axis: Axis = .horizontal
        var leading: CGFloat = 7
        var trailing: CGFloat = 7
        var pillZone: CGFloat = 0
        var onHover: (Bool) -> Void = { _ in }
        var onBegan: () -> Void = {}
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: () -> Void = {}
        var onDoubleClick: (() -> Void)?

        private var mouseDownPoint: NSPoint?
        private var didBegin = false
        private var isHovered = false
        private var pendingTranslation: CGFloat?
        private var lastSent: TimeInterval = 0
        private var flushScheduled = false
        private var trackingAreasAdded: [NSTrackingArea] = []

        private static let minInterval: TimeInterval = 1.0 / 60

        private var cursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// The parts of the view that take the mouse: a band along the line, and the whole
        /// width around the pill.
        private var grabRects: [NSRect] {
            let isVertical = axis == .horizontal
            let middle = (isVertical ? bounds.width : bounds.height) / 2
            let length = isVertical ? bounds.height : bounds.width
            var rects: [NSRect] = []
            let bandStart = middle - leading, bandWidth = leading + trailing + 1
            rects.append(isVertical
                ? NSRect(x: bandStart - 0.5, y: 0, width: bandWidth, height: length)
                : NSRect(x: 0, y: bandStart - 0.5, width: length, height: bandWidth))
            if pillZone > 0 {
                // A shortened side stays short: something next to it needs its clicks.
                let reach = SplitResizeHandle.pillReach
                let before = leading < 7 ? leading : reach, after = trailing < 7 ? trailing : reach
                let along = min(pillZone, length), start = (length - along) / 2
                let crossStart = middle - before - 0.5, crossWidth = before + after + 1
                rects.append(isVertical
                    ? NSRect(x: crossStart, y: start, width: crossWidth, height: along)
                    : NSRect(x: start, y: crossStart, width: along, height: crossWidth))
            }
            return rects
        }

        private func grabs(_ point: NSPoint) -> Bool {
            grabRects.contains { $0.contains(point) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview else { return nil }
            return grabs(convert(point, from: superview)) ? self : nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreasAdded.forEach(removeTrackingArea)
            trackingAreasAdded = grabRects.map {
                NSTrackingArea(rect: $0, options: [.cursorUpdate, .activeAlways], owner: self)
            }
            trackingAreasAdded.append(NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
            trackingAreasAdded.forEach(addTrackingArea)
        }

        override func cursorUpdate(with event: NSEvent) {
            cursor.set()
        }

        override func mouseMoved(with event: NSEvent) {
            setHovered(grabs(convert(event.locationInWindow, from: nil)))
        }

        override func mouseEntered(with event: NSEvent) {
            setHovered(grabs(convert(event.locationInWindow, from: nil)))
        }

        override func mouseExited(with event: NSEvent) {
            // Stays "hovered" while a drag runs ahead of the line; mouseUp settles it.
            if mouseDownPoint == nil { setHovered(false) }
        }

        private func setHovered(_ hovered: Bool) {
            guard hovered != isHovered else { return }
            isHovered = hovered
            onHover(hovered)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                mouseDownPoint = nil
                onDoubleClick()
                return
            }
            mouseDownPoint = event.locationInWindow
            didBegin = false
            cursor.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownPoint else { return }
            if !didBegin {
                didBegin = true
                lastSent = 0
                onBegan()
            }
            cursor.set()
            let location = event.locationInWindow
            // Window coordinates run up; the callers' run down.
            pendingTranslation = axis == .horizontal ? location.x - start.x : start.y - location.y
            let wait = Self.minInterval - (ProcessInfo.processInfo.systemUptime - lastSent)
            if wait <= 0 {
                flush()
            } else if !flushScheduled {
                flushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.flushScheduled = false
                    self?.flush()
                }
            }
        }

        private func flush() {
            guard let translation = pendingTranslation else { return }
            pendingTranslation = nil
            lastSent = ProcessInfo.processInfo.systemUptime
            onChanged(translation)
        }

        override func mouseUp(with event: NSEvent) {
            guard mouseDownPoint != nil else { return }
            mouseDownPoint = nil
            if didBegin {
                flush()
                didBegin = false
                onEnded()
            }
            setHovered(grabs(convert(event.locationInWindow, from: nil)))
            window?.invalidateCursorRects(for: self)
        }
    }
}
