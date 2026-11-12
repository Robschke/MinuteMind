// Purpose: Tests for dragging workspace Claude tabs into windows and back: tear-off, moving
//          between strips, closing windows (tabs return to the nearest open ancestor), closing a
//          window's last tab, Bring Back.
// Dependencies: Sources/App/Supporting/WorkspaceTerminalLayout.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("WorkspaceTerminalLayout Tests")
struct WorkspaceTerminalLayoutTests {
    private let project = UUID()
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    /// A workspace strip holding the given sessions.
    private func workspace(_ sessions: [UUID]) -> WorkspaceTerminalLayout {
        var layout = WorkspaceTerminalLayout()
        layout.ensureRoot(project, projectID: project)
        sessions.forEach { layout.append($0, to: project) }
        return layout
    }

    @Test func tearOffMovesOnlyThatTabIntoANewWindow() throws {
        var layout = workspace([a, b, c])
        let windowTorn = layout.tearOff([b], from: project)
        let window = try #require(windowTorn)
        #expect(layout.group(project)?.sessionIDs == [a, c])
        #expect(layout.group(window)?.sessionIDs == [b])
        #expect(layout.group(window)?.parentID == project)
        #expect(layout.group(window)?.projectID == project)
        #expect(layout.windows(rootedAt: project).map(\.id) == [window])
        #expect(layout.sessionIDs(rootedAt: project) == [a, c, b])
    }

    @Test func closingAWindowReturnsItsTabsToWhereTheyCameFrom() throws {
        var layout = workspace([a, b])
        let firstTorn = layout.tearOff([b], from: project)
        let first = try #require(firstTorn)
        layout.append(c, to: first)
        let secondTorn = layout.tearOff([c], from: first)
        let second = try #require(secondTorn)
        #expect(layout.group(second)?.parentID == first)

        layout.closeWindow(second)
        #expect(layout.group(second) == nil)
        #expect(layout.group(first)?.sessionIDs == [b, c])
        #expect(layout.group(first)?.focusedID == c)
    }

    @Test func aWindowWhoseParentClosedReturnsToTheNearestOpenAncestor() throws {
        var layout = workspace([a, b])
        let firstTorn = layout.tearOff([b], from: project)
        let first = try #require(firstTorn)
        layout.append(c, to: first)
        let secondTorn = layout.tearOff([c], from: first)
        let second = try #require(secondTorn)

        layout.closeWindow(first)
        #expect(layout.group(project)?.sessionIDs == [a, b])
        layout.closeWindow(second)
        #expect(layout.group(project)?.sessionIDs == [a, b, c])
        #expect(layout.windows(rootedAt: project).isEmpty)
    }

    @Test func closingTheLastTabOfAWindowRemovesTheWindow() throws {
        var layout = workspace([a, b])
        let windowTorn = layout.tearOff([b], from: project)
        let window = try #require(windowTorn)
        layout.remove(b)
        #expect(layout.group(window) == nil)
        #expect(layout.group(project)?.sessionIDs == [a])

        // The workspace strip itself stays, even empty.
        layout.remove(a)
        #expect(layout.group(project)?.sessionIDs == [])
    }

    @Test func movingTheLastTabOutOfAWindowClosesIt() throws {
        var layout = workspace([a, b, c])
        let firstTorn = layout.tearOff([b], from: project)
        let first = try #require(firstTorn)
        let secondTorn = layout.tearOff([c], from: project)
        let second = try #require(secondTorn)
        layout.move(b, to: second)
        #expect(layout.group(first) == nil)
        #expect(layout.group(second)?.sessionIDs == [c, b])
        #expect(layout.group(second)?.focusedID == b)
    }

    @Test func tearingOffAWindowsOnlyTabParentsTheNewWindowToItsParent() throws {
        var layout = workspace([a, b])
        let firstTorn = layout.tearOff([b], from: project)
        let first = try #require(firstTorn)
        let secondTorn = layout.tearOff([b], from: first)
        let second = try #require(secondTorn)
        #expect(layout.group(first) == nil)
        #expect(layout.group(second)?.parentID == project)
    }

    @Test func bringBackReturnsEveryWindowOfTheRoot() throws {
        var layout = workspace([a, b, c])
        let assistant = UUID()
        layout.ensureRoot(assistant, projectID: project)
        layout.append(d, to: assistant)
        let fromAssistantTorn = layout.tearOff([d], from: assistant)
        let fromAssistant = try #require(fromAssistantTorn)
        let windowTorn = layout.tearOff([a, b, c], from: project)
        let window = try #require(windowTorn)
        #expect(layout.group(project)?.sessionIDs == [])

        layout.bringBack(rootID: project)
        #expect(layout.group(window) == nil)
        #expect(layout.group(project)?.sessionIDs == [a, b, c])
        // Windows of another root are left alone.
        #expect(layout.group(fromAssistant)?.sessionIDs == [d])
    }

    @Test func closingARootDoesNothing() {
        var layout = workspace([a])
        layout.closeWindow(project)
        #expect(layout.group(project)?.sessionIDs == [a])
    }

    @Test func focusFollowsRemoval() {
        var layout = workspace([a, b, c])
        layout.setFocused(b)
        layout.remove(b)
        #expect(layout.group(project)?.focusedID == c)
        layout.remove(c)
        #expect(layout.group(project)?.focusedID == a)
    }
}
