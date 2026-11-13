// Purpose: Tests for the main window's navigation: back and forward history between places and
//          the Cmd+K switcher's order and stepping.
// Dependencies: Sources/App/Supporting/AppNavigation.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("AppNavigation Tests")
struct AppNavigationTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let all: (NavigationPlace) -> Bool = { _ in true }

    // MARK: - History

    @Test func backAndForwardRetraceVisits() {
        var history = NavigationHistory()
        history.visit(from: .home, to: .project(a, .workspaces))
        history.visit(from: .project(a, .workspaces), to: .calendar)

        #expect(history.goBack(from: .calendar, isValid: all) == .project(a, .workspaces))
        #expect(history.goBack(from: .project(a, .workspaces), isValid: all) == .home)
        #expect(history.goBack(from: .home, isValid: all) == nil)
        #expect(history.goForward(from: .home, isValid: all) == .project(a, .workspaces))
        #expect(history.goForward(from: .project(a, .workspaces), isValid: all) == .calendar)
        #expect(history.goForward(from: .calendar, isValid: all) == nil)
    }

    @Test func aNewVisitDropsTheWayForward() {
        var history = NavigationHistory()
        history.visit(from: .home, to: .inbox)
        _ = history.goBack(from: .inbox, isValid: all)
        #expect(history.canGoForward)
        history.visit(from: .home, to: .calendar)
        #expect(!history.canGoForward)
        #expect(history.goBack(from: .calendar, isValid: all) == .home)
    }

    @Test func sectionsCountAsPlaces() {
        var history = NavigationHistory()
        history.visit(from: .project(a, .overview), to: .project(a, .workspaces))
        #expect(history.goBack(from: .project(a, .workspaces), isValid: all) == .project(a, .overview))
    }

    @Test func goneProjectsAreSkipped() {
        var history = NavigationHistory()
        history.visit(from: .home, to: .project(a, .overview))
        history.visit(from: .project(a, .overview), to: .project(b, .jobs))
        let withoutA: (NavigationPlace) -> Bool = { $0.projectID != a }
        #expect(history.goBack(from: .project(b, .jobs), isValid: withoutA) == .home)
    }

    @Test func historyIsCapped() {
        var history = NavigationHistory()
        for step in 0..<(NavigationHistory.limit + 20) {
            history.visit(from: step.isMultiple(of: 2) ? .home : .inbox, to: step.isMultiple(of: 2) ? .inbox : .home)
        }
        #expect(history.back.count == NavigationHistory.limit)
    }

    @Test func standingStillIsNoVisit() {
        var history = NavigationHistory()
        history.visit(from: .home, to: .home)
        #expect(!history.canGoBack)
    }

    // MARK: - Switcher

    @Test func recentProjectsLeadThenTheRestInSidebarOrder() {
        #expect(ProjectSwitcherOrder.items(recent: [c, a], all: [a, b, c], shown: [a, b, c]) == [c, a, b])
    }

    @Test func deletedProjectsLeaveTheList() {
        let gone = UUID()
        #expect(ProjectSwitcherOrder.items(recent: [gone, b], all: [a, b], shown: [gone, a, b]) == [b, a])
    }

    @Test func onlyShownProjectsAreListed() {
        // b is neither starred nor running a session: it stays out, even when used recently.
        #expect(ProjectSwitcherOrder.items(recent: [b, c], all: [a, b, c], shown: [a, c]) == [c, a])
        #expect(ProjectSwitcherOrder.items(recent: [a], all: [a, b], shown: []).isEmpty)
    }

    @Test func touchingMovesToTheFront() {
        #expect(ProjectSwitcherOrder.touched([a, b, c], c) == [c, a, b])
        #expect(ProjectSwitcherOrder.touched([], a) == [a])
    }

    @Test func highlightStartsOnThePreviousProject() {
        // Inside a: one Cmd+K goes back to b.
        #expect(ProjectSwitcherOrder.startIndex(items: [a, b, c], current: a) == 1)
        // On Home (or the current one is not first): the most recent one.
        #expect(ProjectSwitcherOrder.startIndex(items: [a, b, c], current: nil) == 0)
        #expect(ProjectSwitcherOrder.startIndex(items: [a], current: a) == 0)
    }

    @Test func steppingWraps() {
        #expect(ProjectSwitcherOrder.stepped(2, by: 1, count: 3) == 0)
        #expect(ProjectSwitcherOrder.stepped(0, by: -1, count: 3) == 2)
        #expect(ProjectSwitcherOrder.stepped(0, by: 1, count: 0) == 0)
    }
}
