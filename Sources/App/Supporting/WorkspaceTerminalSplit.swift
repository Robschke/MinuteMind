// Purpose: WorkspaceTerminalSplit, the panes of one tab strip: a tree of side by side and
//          stacked splits whose leaves each show one session, with the geometry for drawing it
//          (pane frames, dividers) and for dropping a dragged tab on it (VS Code style zones).
// Dependencies: Foundation, CoreGraphics only (pure logic on IDs and rectangles, unit tested in
//               Tests/WorkspaceTerminalSplitTests.swift)
// Used by: Sources/App/Supporting/WorkspaceTerminalLayout.swift (one per strip, kept consistent
//          with the strip's tabs), Sources/App/Supporting/WorkspaceTerminalStore.swift (drop
//          targets), Sources/App/Views/WorkspaceTerminalPane.swift (draws it)
// Notes: User request 2026-10-13: one pane by default, more only when the user splits (a button,
//        a tab's menu, or dragging a tab onto a pane's edge). Decisions:
//        - A session is shown in at most one pane (its terminal view can only sit in one place),
//          so showing it in a pane takes it out of the pane it was in, and that pane closes.
//        - A pane closing hands its room to its sibling; focus goes to the sibling pane nearest
//          to it (the first pane of a following sibling, the last of a preceding one).
//        - Panes are at least 280 x 160 pt (about 40 columns and 10 rows of SF Mono 12); a split
//          that would leave any pane smaller in the strip's current size is refused. When the
//          window later shrinks below that, panes share what is there in proportion.
//        - Drop zones: the outer 30 percent of a pane on each side splits it there (corners go
//          to the nearer edge, relative to the pane's size), the middle shows the tab in that
//          pane. The highlight is the half the new pane will take, or the whole pane.
//        - Coordinates are y down (SwiftUI's), with the strip's content area at the origin.
//        - Fractions are stored as dragged (5 to 95 percent) and clamped to the minimum sizes
//          when frames are computed, so a divider never strands a pane under its minimum.

import CoreGraphics
import Foundation

struct WorkspaceTerminalSplit: Equatable {
    enum Axis: Equatable, Sendable {
        /// Side by side (Split Right).
        case horizontal
        /// One above the other (Split Down).
        case vertical
    }

    /// Where a dragged tab would land on a pane.
    enum DropZone: Equatable, Sendable {
        case center, left, right, top, bottom

        /// The split an edge makes; nil for the centre.
        var axis: Axis? {
            switch self {
            case .center: nil
            case .left, .right: .horizontal
            case .top, .bottom: .vertical
            }
        }

        /// The new pane goes before (left of, above) the one split.
        var isLeading: Bool { self == .left || self == .top }
    }

    struct Pane: Equatable, Identifiable, Sendable {
        let id: UUID
        var sessionID: UUID
    }

    /// A divider between the two sides of a split: the line, and the split's whole area (to
    /// turn a pointer position back into a fraction).
    struct Divider: Equatable, Identifiable {
        let id: UUID
        let axis: Axis
        let frame: CGRect
        let bounds: CGRect
    }

    indirect enum Node: Equatable {
        case pane(Pane)
        case split(id: UUID, axis: Axis, fraction: Double, first: Node, second: Node)
    }

    static let minPaneSize = CGSize(width: 280, height: 160)
    static let dividerThickness: CGFloat = 1
    /// Share of a pane's width or height, from each edge, that splits instead of replacing.
    static let edgeShare: CGFloat = 0.3

    private(set) var root: Node?

    init() {}

    init(sessionID: UUID, paneID: UUID = UUID()) {
        root = .pane(Pane(id: paneID, sessionID: sessionID))
    }

    // MARK: - Reading

    /// The panes in reading order (left to right, top to bottom).
    var panes: [Pane] { root.map(Self.leaves) ?? [] }
    var isEmpty: Bool { root == nil }
    /// More than one pane.
    var isSplit: Bool {
        if case .split = root { return true }
        return false
    }

    var visibleSessionIDs: [UUID] { panes.map(\.sessionID) }

    func paneID(showing sessionID: UUID) -> UUID? { panes.first { $0.sessionID == sessionID }?.id }

    func sessionID(inPane paneID: UUID) -> UUID? { panes.first { $0.id == paneID }?.sessionID }

    // MARK: - Changing

    /// Shows a session in a pane. A session already shown in another pane leaves it, and that
    /// pane closes.
    mutating func show(_ sessionID: UUID, inPane paneID: UUID) {
        guard let current = self.sessionID(inPane: paneID), current != sessionID else { return }
        if let other = self.paneID(showing: sessionID) { removePane(other) }
        root = root.map { Self.replacingPane(paneID, in: $0) { .pane(Pane(id: $0.id, sessionID: sessionID)) } }
    }

    /// Splits a pane at an edge and shows the session in the new pane there. A session shown
    /// elsewhere leaves its pane. Refused (false) for the centre, an unknown pane, or the
    /// session the pane already shows.
    @discardableResult
    mutating func split(_ paneID: UUID, _ zone: DropZone, with sessionID: UUID, newPaneID: UUID = UUID()) -> Bool {
        guard let axis = zone.axis, let shown = self.sessionID(inPane: paneID), shown != sessionID else { return false }
        if let other = self.paneID(showing: sessionID) { removePane(other) }
        let new = Node.pane(Pane(id: newPaneID, sessionID: sessionID))
        root = root.map {
            Self.replacingPane(paneID, in: $0) { old in
                let kept = Node.pane(old)
                return .split(
                    id: UUID(), axis: axis, fraction: 0.5,
                    first: zone.isLeading ? new : kept, second: zone.isLeading ? kept : new)
            }
        }
        return true
    }

    /// Closes a pane; its sibling takes the room. Returns the pane nearest to it in that
    /// sibling (where focus goes), nil when it was the last pane.
    @discardableResult
    mutating func removePane(_ paneID: UUID) -> UUID? {
        guard let root, sessionID(inPane: paneID) != nil else { return nil }
        let (node, heir) = Self.removing(paneID, from: root)
        self.root = node
        return heir
    }

    /// The same arrangement with only the panes showing these sessions; the others close as
    /// Close Pane would (their siblings take the room). Empty when none of them is shown.
    func keeping(_ sessionIDs: Set<UUID>) -> WorkspaceTerminalSplit {
        var kept = self
        for pane in panes where !sessionIDs.contains(pane.sessionID) { kept.removePane(pane.id) }
        return kept
    }

    /// A divider was dragged: the first side's share of the split.
    mutating func setFraction(_ splitID: UUID, to fraction: Double) {
        let clamped = min(0.95, max(0.05, fraction))
        root = root.map { Self.settingFraction(splitID, clamped, in: $0) }
    }

    // MARK: - Geometry

    /// The smallest size every pane keeps its minimum in.
    var minimumSize: CGSize { root.map(Self.minimumSize) ?? .zero }

    func fits(in size: CGSize) -> Bool {
        let minimum = minimumSize
        return minimum.width <= size.width + 0.5 && minimum.height <= size.height + 0.5
    }

    /// Each pane's rectangle in a content area of this size.
    func paneFrames(in size: CGSize) -> [UUID: CGRect] {
        var frames: [UUID: CGRect] = [:]
        var dividers: [Divider] = []
        if let root { Self.layout(root, in: CGRect(origin: .zero, size: size), frames: &frames, dividers: &dividers) }
        return frames
    }

    func dividers(in size: CGSize) -> [Divider] {
        var frames: [UUID: CGRect] = [:]
        var dividers: [Divider] = []
        if let root { Self.layout(root, in: CGRect(origin: .zero, size: size), frames: &frames, dividers: &dividers) }
        return dividers
    }

    /// The pane under a point of the content area, with its frame.
    func pane(at point: CGPoint, in size: CGSize) -> (id: UUID, frame: CGRect)? {
        paneFrames(in: size).first { $0.value.contains(point) }.map { ($0.key, $0.value) }
    }

    /// The zone of a pane a point is in: an edge within `edgeShare` of it, else the centre.
    static func zone(at point: CGPoint, in frame: CGRect) -> DropZone {
        guard frame.width > 0, frame.height > 0 else { return .center }
        let x = (point.x - frame.minX) / frame.width
        let y = (point.y - frame.minY) / frame.height
        let edges: [(DropZone, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        guard let nearest = edges.min(by: { $0.1 < $1.1 }), nearest.1 < edgeShare else { return .center }
        return nearest.0
    }

    /// What a drop in this zone would occupy: the pane's half on that side, or all of it.
    static func highlight(for zone: DropZone, in frame: CGRect) -> CGRect {
        switch zone {
        case .center: frame
        case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }

    /// The first side's length along a split: the fraction, but never under either side's
    /// minimum; with too little room for both, shared in proportion to the minimums.
    static func leadingExtent(_ extent: CGFloat, fraction: Double, minFirst: CGFloat, minSecond: CGFloat) -> CGFloat {
        guard extent > 0 else { return 0 }
        if minFirst + minSecond > extent { return (extent * minFirst / (minFirst + minSecond)).rounded() }
        return min(max((extent * CGFloat(fraction)).rounded(), minFirst), extent - minSecond)
    }

    // MARK: - Tree helpers

    private static func leaves(_ node: Node) -> [Pane] {
        switch node {
        case .pane(let pane): [pane]
        case .split(_, _, _, let first, let second): leaves(first) + leaves(second)
        }
    }

    private static func replacingPane(_ paneID: UUID, in node: Node, with make: (Pane) -> Node) -> Node {
        switch node {
        case .pane(let pane):
            return pane.id == paneID ? make(pane) : node
        case let .split(id, axis, fraction, first, second):
            return .split(
                id: id, axis: axis, fraction: fraction,
                first: replacingPane(paneID, in: first, with: make),
                second: replacingPane(paneID, in: second, with: make))
        }
    }

    private static func removing(_ paneID: UUID, from node: Node) -> (node: Node?, heir: UUID?) {
        switch node {
        case .pane(let pane):
            return pane.id == paneID ? (nil, nil) : (node, nil)
        case let .split(id, axis, fraction, first, second):
            let (newFirst, heirInFirst) = removing(paneID, from: first)
            guard let newFirst else { return (second, leaves(second).first?.id) }
            let (newSecond, heirInSecond) = removing(paneID, from: second)
            guard let newSecond else { return (newFirst, leaves(newFirst).last?.id) }
            return (.split(id: id, axis: axis, fraction: fraction, first: newFirst, second: newSecond), heirInFirst ?? heirInSecond)
        }
    }

    private static func settingFraction(_ splitID: UUID, _ value: Double, in node: Node) -> Node {
        guard case let .split(id, axis, fraction, first, second) = node else { return node }
        return .split(
            id: id, axis: axis, fraction: id == splitID ? value : fraction,
            first: settingFraction(splitID, value, in: first),
            second: settingFraction(splitID, value, in: second))
    }

    private static func minimumSize(_ node: Node) -> CGSize {
        switch node {
        case .pane:
            return minPaneSize
        case let .split(_, axis, _, first, second):
            let a = minimumSize(first), b = minimumSize(second)
            return axis == .horizontal
                ? CGSize(width: a.width + b.width + dividerThickness, height: max(a.height, b.height))
                : CGSize(width: max(a.width, b.width), height: a.height + b.height + dividerThickness)
        }
    }

    private static func layout(_ node: Node, in rect: CGRect, frames: inout [UUID: CGRect], dividers: inout [Divider]) {
        switch node {
        case .pane(let pane):
            frames[pane.id] = rect
        case let .split(id, axis, fraction, first, second):
            let minFirst = minimumSize(first), minSecond = minimumSize(second)
            let firstRect: CGRect, line: CGRect, secondRect: CGRect
            if axis == .horizontal {
                let lead = leadingExtent(
                    max(0, rect.width - dividerThickness), fraction: fraction,
                    minFirst: minFirst.width, minSecond: minSecond.width)
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: lead, height: rect.height)
                line = CGRect(x: firstRect.maxX, y: rect.minY, width: dividerThickness, height: rect.height)
                secondRect = CGRect(x: line.maxX, y: rect.minY, width: max(0, rect.maxX - line.maxX), height: rect.height)
            } else {
                let lead = leadingExtent(
                    max(0, rect.height - dividerThickness), fraction: fraction,
                    minFirst: minFirst.height, minSecond: minSecond.height)
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lead)
                line = CGRect(x: rect.minX, y: firstRect.maxY, width: rect.width, height: dividerThickness)
                secondRect = CGRect(x: rect.minX, y: line.maxY, width: rect.width, height: max(0, rect.maxY - line.maxY))
            }
            dividers.append(Divider(id: id, axis: axis, frame: line, bounds: rect))
            layout(first, in: firstRect, frames: &frames, dividers: &dividers)
            layout(second, in: secondRect, frames: &frames, dividers: &dividers)
        }
    }
}
