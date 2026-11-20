// Purpose: Tests for the agent cockpit's choice of spaces: which are listed, which the "+" menu
//          offers and which one is shown.
// Dependencies: Sources/App/Supporting/AgentCockpitSpaces.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("AgentCockpitSpaces Tests")
struct AgentCockpitSpacesTests {
    private let general = UUID()
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    @Test func listsRunningSpacesInSidebarOrder() {
        let order = [general, a, b, c]
        #expect(AgentCockpitSpaces.listed(order: order, running: [c, a]) == [a, c])
        #expect(AgentCockpitSpaces.listed(order: order, running: []) == [])
    }

    @Test func offersTheOthersInSidebarOrder() {
        let order = [general, a, b, c]
        #expect(AgentCockpitSpaces.addable(order: order, running: [a, c]) == [general, b])
        #expect(AgentCockpitSpaces.addable(order: order, running: Set(order)) == [])
    }

    @Test func runningIDsOutsideTheOrderAreIgnored() {
        #expect(AgentCockpitSpaces.listed(order: [a], running: [a, UUID()]) == [a])
    }

    @Test func showsTheChosenSpaceWhileItIsListed() {
        #expect(AgentCockpitSpaces.shown(chosen: b, listed: [a, b]) == b)
    }

    @Test func fallsBackToTheFirstListedSpace() {
        #expect(AgentCockpitSpaces.shown(chosen: c, listed: [a, b]) == a)
        #expect(AgentCockpitSpaces.shown(chosen: nil, listed: [b]) == b)
        #expect(AgentCockpitSpaces.shown(chosen: a, listed: []) == nil)
    }
}
