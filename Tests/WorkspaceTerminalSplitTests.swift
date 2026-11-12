// Purpose: Tests for a tab strip's split panes: splitting right and down, nested splits and their
//          frames, closing a pane collapses its split, showing a tab in a pane, the minimum pane
//          size, drop zones, and how the strip layout keeps panes and tabs consistent (focus,
//          close, move between strips, Close Pane, dragging a tab onto its own pane's edge), and
//          windows keeping the panes' arrangement when tabs pop out and come back.
// Dependencies: Sources/App/Supporting/WorkspaceTerminalSplit.swift,
//               Sources/App/Supporting/WorkspaceTerminalLayout.swift

import CoreGraphics
import Foundation
import Testing

@testable import MinuteMindApp

@Suite("WorkspaceTerminalSplit Tests")
struct WorkspaceTerminalSplitTests {
    private let project = UUID()
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let big = CGSize(width: 1200, height: 800)

    /// A workspace strip holding the given sessions (the last one shown and focused).
    private func workspace(_ sessions: [UUID]) -> WorkspaceTerminalLayout {
        var layout = WorkspaceTerminalLayout()
        layout.ensureRoot(project, projectID: project)
        sessions.forEach { layout.append($0, to: project) }
        return layout
    }

    // MARK: - Tree

    @Test func splitRightPutsTheNewPaneBesideTheOld() throws {
        var split = WorkspaceTerminalSplit(sessionID: a)
        let pane = try #require(split.panes.first?.id)
        let did1 = split.split(pane, .right, with: b)
        #expect(did1)
        #expect(split.visibleSessionIDs == [a, b])
        let frames = split.paneFrames(in: CGSize(width: 801, height: 400))
        let left = try #require(frames[pane])
        let right = try #require(split.paneID(showing: b).flatMap { frames[$0] })
        #expect(left == CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(right == CGRect(x: 401, y: 0, width: 400, height: 400))
        #expect(split.dividers(in: CGSize(width: 801, height: 400)).first?.axis == .horizontal)
    }

    @Test func splitDownAndLeftAndTopPlaceTheNewPaneOnThatSide() throws {
        var down = WorkspaceTerminalSplit(sessionID: a)
        let firstPane2 = try #require(down.panes.first?.id)
        let did2 = down.split(firstPane2, .bottom, with: b)
        try #require(did2)
        let frames = down.paneFrames(in: CGSize(width: 600, height: 401))
        let top = try #require(down.paneID(showing: a).flatMap { frames[$0] })
        let bottom = try #require(down.paneID(showing: b).flatMap { frames[$0] })
        #expect(top.maxY < bottom.minY)
        #expect(bottom.height == 200)

        var left = WorkspaceTerminalSplit(sessionID: a)
        let firstPane3 = try #require(left.panes.first?.id)
        let did3 = left.split(firstPane3, .left, with: b)
        try #require(did3)
        #expect(left.visibleSessionIDs == [b, a])

        var above = WorkspaceTerminalSplit(sessionID: a)
        let firstPane4 = try #require(above.panes.first?.id)
        let did4 = above.split(firstPane4, .top, with: b)
        try #require(did4)
        #expect(above.visibleSessionIDs == [b, a])
    }

    @Test func nestedSplitsLayOutInsideTheirPane() throws {
        var split = WorkspaceTerminalSplit(sessionID: a)
        let first = try #require(split.panes.first?.id)
        let did5 = split.split(first, .right, with: b)
        try #require(did5)
        let second = try #require(split.paneID(showing: b))
        let did6 = split.split(second, .bottom, with: c)
        try #require(did6)
        #expect(split.visibleSessionIDs == [a, b, c])
        #expect(split.minimumSize == CGSize(width: 561, height: 321))

        let frames = split.paneFrames(in: CGSize(width: 1001, height: 601))
        let rightTop = try #require(frames[second])
        let rightBottom = try #require(split.paneID(showing: c).flatMap { frames[$0] })
        #expect(frames[first] == CGRect(x: 0, y: 0, width: 500, height: 601))
        #expect(rightTop == CGRect(x: 501, y: 0, width: 500, height: 300))
        #expect(rightBottom == CGRect(x: 501, y: 301, width: 500, height: 300))
        #expect(split.dividers(in: CGSize(width: 1001, height: 601)).count == 2)
    }

    @Test func removingAPaneCollapsesItsSplitAndNamesTheNearestHeir() throws {
        var split = WorkspaceTerminalSplit(sessionID: a)
        let first = try #require(split.panes.first?.id)
        let did7 = split.split(first, .right, with: b)
        try #require(did7)
        let second = try #require(split.paneID(showing: b))
        let did8 = split.split(second, .bottom, with: c)
        try #require(did8)

        // The bottom right pane goes: the top right pane takes its room.
        let third = try #require(split.paneID(showing: c))
        let heir = split.removePane(third)
        #expect(heir == second)
        #expect(split.visibleSessionIDs == [a, b])

        // The left pane goes: the right one is all that is left, filling the area.
        let heirOfFirst = split.removePane(first)
        #expect(heirOfFirst == second)
        #expect(!split.isSplit)
        #expect(split.paneFrames(in: big)[second] == CGRect(origin: .zero, size: big))

        let heirOfLast = split.removePane(second)
        #expect(heirOfLast == nil)
        #expect(split.isEmpty)
    }

    @Test func showReplacesWhatAPaneShowsAndTakesItFromAnotherPane() throws {
        var split = WorkspaceTerminalSplit(sessionID: a)
        let first = try #require(split.panes.first?.id)
        let did9 = split.split(first, .right, with: b)
        try #require(did9)

        split.show(c, inPane: first)
        #expect(split.visibleSessionIDs == [c, b])

        // b moves into the first pane; its own pane closes.
        split.show(b, inPane: first)
        #expect(split.visibleSessionIDs == [b])
        #expect(split.panes.map(\.id) == [first])
    }

    @Test func splitRefusesTheCentreAndThePanesOwnSession() throws {
        var split = WorkspaceTerminalSplit(sessionID: a)
        let pane = try #require(split.panes.first?.id)
        let did10 = split.split(pane, .center, with: b)
        #expect(!did10)
        let did11 = split.split(pane, .right, with: a)
        #expect(!did11)
        let did12 = split.split(UUID(), .right, with: b)
        #expect(!did12)
        #expect(split.visibleSessionIDs == [a])
    }

    @Test func minimumSizeDecidesWhetherASplitFits() throws {
        var split = WorkspaceTerminalSplit(sessionID: a)
        let firstPane13 = try #require(split.panes.first?.id)
        let did13 = split.split(firstPane13, .right, with: b)
        try #require(did13)
        #expect(split.fits(in: CGSize(width: 561, height: 160)))
        #expect(!split.fits(in: CGSize(width: 500, height: 800)))
    }

    @Test func dividerFractionsKeepEachSideItsMinimum() throws {
        var split = WorkspaceTerminalSplit(sessionID: a)
        let first = try #require(split.panes.first?.id)
        let did14 = split.split(first, .right, with: b)
        try #require(did14)
        let divider = try #require(split.dividers(in: CGSize(width: 1001, height: 400)).first)

        split.setFraction(divider.id, to: 0.1)
        #expect(split.paneFrames(in: CGSize(width: 1001, height: 400))[first]?.width == 280)
        split.setFraction(divider.id, to: 0.7)
        #expect(split.paneFrames(in: CGSize(width: 1001, height: 400))[first]?.width == 700)
        // Less room than both minimums: shared in proportion.
        #expect(split.paneFrames(in: CGSize(width: 401, height: 400))[first]?.width == 200)
    }

    @Test func dropZonesFollowTheNearestEdge() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 200)
        #expect(WorkspaceTerminalSplit.zone(at: CGPoint(x: 300, y: 200), in: frame) == .center)
        #expect(WorkspaceTerminalSplit.zone(at: CGPoint(x: 480, y: 200), in: frame) == .right)
        #expect(WorkspaceTerminalSplit.zone(at: CGPoint(x: 120, y: 200), in: frame) == .left)
        #expect(WorkspaceTerminalSplit.zone(at: CGPoint(x: 300, y: 290), in: frame) == .bottom)
        #expect(WorkspaceTerminalSplit.zone(at: CGPoint(x: 300, y: 110), in: frame) == .top)
        // Bottom right corner, relatively closer to the bottom.
        #expect(WorkspaceTerminalSplit.zone(at: CGPoint(x: 460, y: 295), in: frame) == .bottom)
        #expect(WorkspaceTerminalSplit.highlight(for: .right, in: frame) == CGRect(x: 300, y: 100, width: 200, height: 200))
        #expect(WorkspaceTerminalSplit.highlight(for: .bottom, in: frame) == CGRect(x: 100, y: 200, width: 400, height: 100))
    }

    // MARK: - Strip layout

    @Test func aStripShowsOnlyTheFocusedTabByDefault() throws {
        var layout = workspace([a, b, c])
        let group = try #require(layout.group(project))
        #expect(group.split.visibleSessionIDs == [c])
        #expect(group.focusedID == c)

        // Clicking a hidden tab shows it in the focused pane.
        layout.setFocused(a)
        #expect(layout.group(project)?.split.visibleSessionIDs == [a])
        #expect(layout.group(project)?.focusedID == a)
    }

    @Test func focusingAShownTabOnlyMovesFocusToItsPane() throws {
        var layout = workspace([a, b, c])
        let pane = try #require(layout.group(project)?.split.panes.first?.id)
        let did15 = layout.place(a, in: project, pane: pane, zone: .right, size: big)
        #expect(did15)
        #expect(layout.group(project)?.split.visibleSessionIDs == [c, a])
        #expect(layout.group(project)?.focusedID == a)

        layout.setFocused(c)
        #expect(layout.group(project)?.split.visibleSessionIDs == [c, a])
        #expect(layout.group(project)?.focusedID == c)

        // A hidden tab replaces the focused pane's session, not the other pane's.
        layout.setFocused(b)
        #expect(layout.group(project)?.split.visibleSessionIDs == [b, a])
    }

    @Test func closingAShownSessionCollapsesTheSplitAndMovesFocus() throws {
        var layout = workspace([a, b, c])
        let pane = try #require(layout.group(project)?.split.panes.first?.id)
        let did16 = layout.place(a, in: project, pane: pane, zone: .bottom, size: big)
        #expect(did16)
        layout.remove(a)
        let group = try #require(layout.group(project))
        #expect(!group.split.isSplit)
        #expect(group.split.visibleSessionIDs == [c])
        #expect(group.focusedID == c)
        #expect(group.sessionIDs == [b, c])

        // Unsplit, the single pane shows the neighbouring tab.
        layout.remove(c)
        #expect(layout.group(project)?.split.visibleSessionIDs == [b])
        layout.remove(b)
        #expect(layout.group(project)?.split.isEmpty == true)
        #expect(layout.group(project)?.focusedID == nil)
    }

    @Test func closePaneKeepsTheSessionAsAHiddenTab() throws {
        var layout = workspace([a, b])
        let pane = try #require(layout.group(project)?.split.panes.first?.id)
        let did17 = layout.place(a, in: project, pane: pane, zone: .right, size: big)
        #expect(did17)
        let aPane = try #require(layout.group(project)?.split.paneID(showing: a))
        layout.closePane(aPane, in: project)
        let group = try #require(layout.group(project))
        #expect(group.sessionIDs == [a, b])
        #expect(group.split.visibleSessionIDs == [b])
        #expect(group.focusedID == b)

        // The last pane never closes.
        layout.closePane(pane, in: project)
        #expect(layout.group(project)?.split.visibleSessionIDs == [b])
    }

    @Test func draggingATabOntoItsOwnPanesEdgeNeedsAnotherTabToFillIt() throws {
        var single = workspace([a])
        let onlyPane = try #require(single.group(project)?.split.panes.first?.id)
        let did18 = single.place(a, in: project, pane: onlyPane, zone: .right, size: big)
        #expect(!did18)
        let did19 = single.place(a, in: project, pane: onlyPane, zone: .center, size: big)
        #expect(!did19)

        var layout = workspace([a, b, c])
        let pane = try #require(layout.group(project)?.split.panes.first?.id)
        // c is shown; dragged to its own right edge it moves there and the next hidden tab (a)
        // takes the left pane.
        let did20 = layout.place(c, in: project, pane: pane, zone: .right, size: big)
        #expect(did20)
        #expect(layout.group(project)?.split.visibleSessionIDs == [a, c])
        #expect(layout.group(project)?.focusedID == c)
    }

    @Test func aSplitThatDoesNotFitIsRefusedAndChangesNothing() throws {
        var layout = workspace([a, b])
        let before = layout
        let pane = try #require(layout.group(project)?.split.panes.first?.id)
        let did21 = layout.place(a, in: project, pane: pane, zone: .right, size: CGSize(width: 500, height: 800))
        #expect(!did21)
        #expect(layout == before)
        let did22 = layout.append(c, to: project, splitting: pane, .bottom, size: CGSize(width: 800, height: 300))
        #expect(!did22)
        #expect(layout == before)
        let did23 = layout.append(c, to: project, splitting: pane, .bottom, size: big)
        #expect(did23)
        #expect(layout.group(project)?.split.visibleSessionIDs == [b, c])
        #expect(layout.group(project)?.sessionIDs == [a, b, c])
    }

    @Test func droppingOnAnotherStripsPaneEdgeMovesAndSplits() throws {
        var layout = workspace([a, b])
        let windowTorn = layout.tearOff([a], from: project)
        let window = try #require(windowTorn)
        layout.append(c, to: window)
        #expect(layout.group(window)?.split.visibleSessionIDs == [c])

        // c goes from the window to the right of the workspace's pane; the window keeps a.
        let pane = try #require(layout.group(project)?.split.panes.first?.id)
        let did24 = layout.place(c, in: project, pane: pane, zone: .right, size: big)
        #expect(did24)
        #expect(layout.group(project)?.sessionIDs == [b, c])
        #expect(layout.group(project)?.split.visibleSessionIDs == [b, c])
        #expect(layout.group(window)?.sessionIDs == [a])
        #expect(layout.group(window)?.split.visibleSessionIDs == [a])
        #expect(layout.group(window)?.focusedID == a)

        // Moving a shown session of a split strip away collapses that split.
        layout.move(c, to: window)
        #expect(layout.group(project)?.split.visibleSessionIDs == [b])
        #expect(layout.group(window)?.split.visibleSessionIDs == [c])
        #expect(layout.group(window)?.sessionIDs == [a, c])
    }

    @Test func tearOffAndReturnKeepPanesConsistent() throws {
        var layout = workspace([a, b, c])
        let pane = try #require(layout.group(project)?.split.panes.first?.id)
        let did25 = layout.place(a, in: project, pane: pane, zone: .right, size: big)
        #expect(did25)
        let windowTorn = layout.tearOff([a], from: project)
        let window = try #require(windowTorn)
        #expect(layout.group(window)?.split.visibleSessionIDs == [a])
        #expect(layout.group(project)?.split.visibleSessionIDs == [c])

        layout.closeWindow(window)
        // Back in the workspace, a is focused and shown in the focused pane.
        #expect(layout.group(project)?.focusedID == a)
        #expect(layout.group(project)?.split.visibleSessionIDs == [a])
        #expect(layout.group(project)?.sessionIDs == [b, c, a])
    }

    @Test func nextHiddenTabWrapsAround() throws {
        var layout = workspace([a, b, c, d])
        layout.setFocused(c)
        let group = try #require(layout.group(project))
        #expect(group.nextHiddenSession(after: c) == d)
        #expect(group.nextHiddenSession(after: d) == a)
        let single = workspace([a])
        #expect(single.group(project)?.nextHiddenSession(after: a) == nil)
    }

    // MARK: - Windows keep the arrangement

    /// Tabs d, a, b, c: a | (b over c), d hidden, c focused.
    private func arranged() throws -> WorkspaceTerminalLayout {
        var layout = workspace([d, a])
        let paneA = try #require(layout.group(project)?.split.paneID(showing: a))
        layout.append(b, to: project, splitting: paneA, .right, size: big)
        let paneB = try #require(layout.group(project)?.split.paneID(showing: b))
        layout.append(c, to: project, splitting: paneB, .bottom, size: big)
        return layout
    }

    @Test func poppingAllTabsOutKeepsThePanesAndBringingThemBackRestoresThem() throws {
        var layout = try arranged()
        let before = try #require(layout.group(project))
        let torn = layout.tearOff([a, b, c, d], from: project)
        let window = try #require(torn)
        let popped = try #require(layout.group(window))
        #expect(popped.split == before.split)
        #expect(popped.focusedID == before.focusedID)
        #expect(popped.sessionIDs == [d, a, b, c])

        layout.bringBack(rootID: project)
        let back = try #require(layout.group(project))
        #expect(back.split == before.split)
        #expect(back.focusedID == before.focusedID)
        #expect(back.sessionIDs == [d, a, b, c])
    }

    @Test func closingAPoppedOutWindowOrMovingAllBackRestoresThePanes() throws {
        var layout = try arranged()
        let split = layout.group(project)?.split
        let firstTorn = layout.tearOff([a, b, c, d], from: project)
        let first = try #require(firstTorn)
        layout.closeWindow(first)
        #expect(layout.group(project)?.split == split)

        let secondTorn = layout.tearOff([a, b, c, d], from: project)
        let second = try #require(secondTorn)
        layout.moveToRoot(second)
        #expect(layout.group(second) == nil)
        #expect(layout.group(project)?.split == split)
    }

    @Test func tearingOffSomeTabsTakesOnlyTheirPanes() throws {
        var layout = try arranged()
        let torn = layout.tearOff([b, c], from: project)
        let window = try #require(torn)
        let popped = try #require(layout.group(window))
        #expect(popped.split.visibleSessionIDs == [b, c])
        #expect(popped.split.dividers(in: big).map(\.axis) == [.vertical])
        #expect(popped.focusedID == c)
        #expect(layout.group(project)?.split.visibleSessionIDs == [a])
    }

    @Test func tabsReturningToAStripWithTabsLineUpAsTabs() throws {
        var layout = try arranged()
        let torn = layout.tearOff([b, c], from: project)
        let window = try #require(torn)
        layout.closeWindow(window)
        let back = try #require(layout.group(project))
        #expect(back.sessionIDs == [d, a, b, c])
        #expect(back.split.visibleSessionIDs == [c])
        #expect(back.focusedID == c)
    }
}
