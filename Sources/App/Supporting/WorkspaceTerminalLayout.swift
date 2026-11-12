// Purpose: WorkspaceTerminalLayout, which Claude session sits in which tab strip: a project's
//          workspace pane, the "Claude (General)" window, or a window a tab was dragged out into.
// Dependencies: Sources/App/Supporting/WorkspaceTerminalSplit.swift (each strip's panes); pure
//               logic on IDs, unit tested in Tests/WorkspaceTerminalLayoutTests.swift and
//               Tests/WorkspaceTerminalSplitTests.swift
// Used by: Sources/App/Supporting/WorkspaceTerminalStore.swift (owns one layout and the live
//          terminal views behind the session IDs)
// Notes: User request 2026-10-13: tabs can be dragged out into their own windows, those windows
//        start tabs of their own and can be torn apart further. Closing a window sends its tabs
//        back to the window they came from; closing its last tab closes it for good.
//        A group is a tab strip. Roots (a project's workspace, keyed by the project ID, and the
//        Claude (General) window, keyed by `WorkspaceTerminalStore.assistantKey`) always exist
//        once created; window groups have a parent and disappear when emptied or closed. A closed
//        window's parent is remembered (`retiredParents`), so a window whose parent closed first
//        returns its tabs to the nearest one still open, ultimately the root.
//        Panes (user request 2026-10-13, VS Code style): each strip keeps a split tree
//        (`Group.split`) of the sessions it shows; the other tabs wait in the strip. The focused
//        session is always shown. A new or returning tab shows in the focused pane (a new editor
//        opens in the active group in VS Code). Focusing a hidden tab shows it in the focused
//        pane; focusing a shown one only moves focus to its pane. Closing or moving away a shown
//        session closes its pane when the strip is split, else the single pane shows the
//        neighbouring tab. Close Pane hides a pane; its session stays a tab. Dragging a tab onto
//        the edge of its own pane moves it into a new pane there and the next hidden tab takes
//        the old one (refused when there is none). Not persisted across launches.
//        Moving tabs into a window takes their panes along as arranged (the others close), and a
//        window's tabs returning to an empty strip (closing it, Move All Back, Bring Back) bring
//        the arrangement back; into a strip with tabs they only line up as tabs.

import CoreGraphics
import Foundation

struct WorkspaceTerminalLayout: Equatable {
    struct Group: Equatable, Identifiable {
        let id: UUID
        /// The project whose repo new sessions in this strip run in.
        let projectID: UUID
        /// The strip a window's tabs return to when it closes; nil for roots.
        let parentID: UUID?
        /// The workspace (or Claude window) the strip descends from.
        let rootID: UUID
        var sessionIDs: [UUID] = []
        /// The session last clicked into, where typed references go; always shown in a pane.
        var focusedID: UUID?
        /// The panes and the session each shows.
        var split = WorkspaceTerminalSplit()

        var isWindow: Bool { parentID != nil }

        /// The pane showing the focused session.
        var focusedPaneID: UUID? { focusedID.flatMap(split.paneID(showing:)) ?? split.panes.first?.id }

        /// The next tab after `sessionID` (wrapping) that no pane shows.
        func nextHiddenSession(after sessionID: UUID?) -> UUID? {
            guard !sessionIDs.isEmpty else { return nil }
            let visible = Set(split.visibleSessionIDs)
            let start = sessionID.flatMap(sessionIDs.firstIndex(of:)) ?? -1
            for step in 1...sessionIDs.count {
                let id = sessionIDs[(start + step) % sessionIDs.count]
                if !visible.contains(id) { return id }
            }
            return nil
        }
    }

    private(set) var groups: [UUID: Group] = [:]
    /// Order windows were opened in, so lists of them stay stable.
    private(set) var windowOrder: [UUID] = []
    private var retiredParents: [UUID: UUID] = [:]

    func group(_ id: UUID) -> Group? { groups[id] }

    func groupID(containing sessionID: UUID) -> UUID? {
        groups.values.first { $0.sessionIDs.contains(sessionID) }?.id
    }

    /// The windows descending from a root, oldest first.
    func windows(rootedAt rootID: UUID) -> [Group] {
        windowOrder.compactMap { groups[$0] }.filter { $0.rootID == rootID }
    }

    /// Every session of a root: its own strip first, then its windows'.
    func sessionIDs(rootedAt rootID: UUID) -> [UUID] {
        (groups[rootID]?.sessionIDs ?? []) + windows(rootedAt: rootID).flatMap(\.sessionIDs)
    }

    mutating func ensureRoot(_ id: UUID, projectID: UUID) {
        if groups[id] == nil { groups[id] = Group(id: id, projectID: projectID, parentID: nil, rootID: id) }
    }

    /// Adds a session at the end of a strip, shows it in the focused pane and focuses it.
    mutating func append(_ sessionID: UUID, to groupID: UUID) {
        guard groups[groupID] != nil else { return }
        groups[groupID]?.sessionIDs.append(sessionID)
        focus(sessionID, in: groupID)
    }

    /// Adds a session at the end of a strip in a new pane at an edge of `paneID`. Nothing
    /// changes (false) when the split leaves a pane under its minimum in `size`.
    @discardableResult
    mutating func append(
        _ sessionID: UUID, to groupID: UUID, splitting paneID: UUID, _ zone: WorkspaceTerminalSplit.DropZone,
        size: CGSize? = nil
    ) -> Bool {
        guard var group = groups[groupID] else { return false }
        var split = group.split
        guard split.split(paneID, zone, with: sessionID), Self.fits(split, size) else { return false }
        group.sessionIDs.append(sessionID)
        group.split = split
        group.focusedID = sessionID
        groups[groupID] = group
        return true
    }

    /// Focuses a session: a hidden one is shown in the focused pane first.
    mutating func setFocused(_ sessionID: UUID) {
        guard let id = groupID(containing: sessionID) else { return }
        focus(sessionID, in: id)
    }

    /// A tab dropped on a pane, or Split Right / Split Down from its menu: the centre shows it in
    /// that pane, an edge splits the pane with it on that side. A tab of another strip moves
    /// here. False (nothing changed) when there is nothing to do, when the tab would leave its
    /// own pane with no hidden tab to take it, or when a split leaves a pane under its minimum
    /// in `size`.
    @discardableResult
    mutating func place(
        _ sessionID: UUID, in groupID: UUID, pane paneID: UUID, zone: WorkspaceTerminalSplit.DropZone,
        size: CGSize? = nil
    ) -> Bool {
        guard let target = groups[groupID], let shown = target.split.sessionID(inPane: paneID),
              let sourceID = self.groupID(containing: sessionID)
        else { return false }
        var split = target.split
        if zone == .center {
            guard shown != sessionID else { return false }
            split.show(sessionID, inPane: paneID)
        } else {
            if shown == sessionID {
                // The tab leaves its pane for the new one; the next hidden tab takes the old one.
                guard let heir = target.nextHiddenSession(after: sessionID) else { return false }
                split.show(heir, inPane: paneID)
            }
            guard split.split(paneID, zone, with: sessionID), Self.fits(split, size) else { return false }
        }
        if sourceID != groupID { detach(sessionID, from: sourceID) }
        guard var group = groups[groupID] else { return false }
        if sourceID != groupID { group.sessionIDs.append(sessionID) }
        group.split = split
        group.focusedID = sessionID
        groups[groupID] = group
        return true
    }

    /// Hides a pane; its session stays a tab and focus goes to the pane that takes the room.
    /// The last pane does not close.
    mutating func closePane(_ paneID: UUID, in groupID: UUID) {
        guard var group = groups[groupID], group.split.isSplit,
              let sessionID = group.split.sessionID(inPane: paneID)
        else { return }
        let heir = group.split.removePane(paneID)
        if group.focusedID == sessionID { group.focusedID = heir.flatMap(group.split.sessionID(inPane:)) }
        groups[groupID] = group
    }

    /// A divider between panes was dragged.
    mutating func setSplitFraction(_ splitID: UUID, to fraction: Double, in groupID: UUID) {
        groups[groupID]?.split.setFraction(splitID, to: fraction)
    }

    /// Takes a session out of its strip (it was closed). A window left without tabs is gone.
    @discardableResult
    mutating func remove(_ sessionID: UUID) -> UUID? {
        guard let id = groupID(containing: sessionID) else { return nil }
        detach(sessionID, from: id)
        return id
    }

    /// Moves a session into another strip (dropped on its tab strip) and focuses it there.
    mutating func move(_ sessionID: UUID, to targetID: UUID) {
        guard groups[targetID] != nil, let sourceID = groupID(containing: sessionID), sourceID != targetID else { return }
        detach(sessionID, from: sourceID)
        append(sessionID, to: targetID)
    }

    /// Puts sessions of one strip into a new window whose tabs return there on close.
    /// Returns the window's group ID, or nil when there was nothing to move.
    @discardableResult
    mutating func tearOff(_ sessionIDs: [UUID], from sourceID: UUID, windowID: UUID = UUID()) -> UUID? {
        guard let source = groups[sourceID] else { return nil }
        let moving = source.sessionIDs.filter(sessionIDs.contains)
        guard !moving.isEmpty else { return nil }
        // The window's parent is the strip the tabs came from, unless that strip empties and
        // disappears with this move; then its own parent takes the tabs back later.
        let emptiesSource = source.isWindow && moving.count == source.sessionIDs.count
        let parentID = emptiesSource ? (source.parentID ?? source.rootID) : sourceID
        var window = Group(id: windowID, projectID: source.projectID, parentID: parentID, rootID: source.rootID)
        window.sessionIDs = moving
        // The panes of the moving tabs keep their arrangement; focus stays with a shown one.
        let split = source.split.keeping(Set(moving))
        let shown = split.visibleSessionIDs
        let focused: UUID?
        if let current = source.focusedID, moving.contains(current), split.isEmpty || shown.contains(current) {
            focused = current
        } else {
            focused = shown.last ?? moving.last
        }
        window.focusedID = focused
        if !split.isEmpty {
            window.split = split
        } else if let focused {
            window.split = WorkspaceTerminalSplit(sessionID: focused)
        }
        for id in moving { detach(id, from: sourceID) }
        groups[windowID] = window
        windowOrder.append(windowID)
        return windowID
    }

    /// The window was closed: its tabs go back to the strip they came from, or the nearest
    /// one still open. Closing a root does nothing (the Claude window only hides).
    mutating func closeWindow(_ id: UUID) {
        guard let window = groups[id], window.isWindow else { return }
        let target = liveAncestor(of: id)
        groups[id] = nil
        windowOrder.removeAll { $0 == id }
        if let parentID = window.parentID { retiredParents[id] = parentID }
        receive(window, into: target)
    }

    /// Every window of the root closes and its tabs return to the root's strip.
    mutating func bringBack(rootID: UUID) {
        for window in windows(rootedAt: rootID) {
            groups[window.id] = nil
            windowOrder.removeAll { $0 == window.id }
            retiredParents[window.id] = rootID
            receive(window, into: rootID)
        }
    }

    /// Every tab of a window moves to its root's strip and the window is gone.
    mutating func moveToRoot(_ id: UUID) {
        guard let window = groups[id], window.isWindow else { return }
        groups[id] = nil
        windowOrder.removeAll { $0 == id }
        retiredParents[id] = window.rootID
        receive(window, into: window.rootID)
    }

    /// A closed window's tabs join a strip. An empty strip takes over the window's panes as
    /// they were (popping all tabs out and back in keeps the arrangement); otherwise they line
    /// up as tabs and the window's focused one shows in the focused pane.
    private mutating func receive(_ window: Group, into target: UUID) {
        guard var group = groups[target], !window.sessionIDs.isEmpty else { return }
        if group.sessionIDs.isEmpty, !window.split.isEmpty {
            group.sessionIDs = window.sessionIDs
            group.split = window.split
            group.focusedID = window.focusedID ?? window.split.visibleSessionIDs.last
            groups[target] = group
            return
        }
        groups[target]?.sessionIDs.append(contentsOf: window.sessionIDs)
        if let focused = window.focusedID ?? window.sessionIDs.last { focus(focused, in: target) }
    }

    /// The closest strip up the chain that still exists.
    func liveAncestor(of id: UUID) -> UUID {
        guard let group = groups[id] else { return id }
        var current = group.parentID ?? group.rootID
        var seen: Set<UUID> = []
        while groups[current] == nil, let parent = retiredParents[current], seen.insert(current).inserted {
            current = parent
        }
        return groups[current] == nil ? group.rootID : current
    }

    /// Shows a session of the strip in its focused pane (unless shown already) and focuses it.
    private mutating func focus(_ sessionID: UUID, in groupID: UUID) {
        guard var group = groups[groupID], group.sessionIDs.contains(sessionID) else { return }
        if group.split.paneID(showing: sessionID) == nil {
            if let pane = group.focusedPaneID {
                group.split.show(sessionID, inPane: pane)
            } else {
                group.split = WorkspaceTerminalSplit(sessionID: sessionID)
            }
        }
        group.focusedID = sessionID
        if groups[groupID] != group { groups[groupID] = group }
    }

    private static func fits(_ split: WorkspaceTerminalSplit, _ size: CGSize?) -> Bool {
        guard let size else { return true }
        return split.fits(in: size)
    }

    private mutating func detach(_ sessionID: UUID, from groupID: UUID) {
        guard var group = groups[groupID], let index = group.sessionIDs.firstIndex(of: sessionID) else { return }
        group.sessionIDs.remove(at: index)
        if let pane = group.split.paneID(showing: sessionID) {
            if group.split.isSplit {
                // Its pane closes and the split collapses; focus goes to the pane taking the room.
                let heir = group.split.removePane(pane)
                if group.focusedID == sessionID { group.focusedID = heir.flatMap(group.split.sessionID(inPane:)) }
            } else if !group.sessionIDs.isEmpty {
                // The only pane shows the neighbouring tab instead.
                let neighbour = group.sessionIDs[min(index, group.sessionIDs.count - 1)]
                group.split.show(neighbour, inPane: pane)
                group.focusedID = neighbour
            } else {
                group.split = WorkspaceTerminalSplit()
                group.focusedID = nil
            }
        }
        if group.isWindow, group.sessionIDs.isEmpty {
            groups[groupID] = nil
            windowOrder.removeAll { $0 == groupID }
            if let parentID = group.parentID { retiredParents[groupID] = parentID }
        } else {
            groups[groupID] = group
        }
    }
}
