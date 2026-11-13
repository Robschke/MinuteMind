// Purpose: Tests for the three states the project sidebar's Agents section shows per Claude
//          session, folded from the five terminal statuses.
// Dependencies: Sources/App/Views/ProjectAgentsSection.swift (AgentSessionState),
//               Sources/App/Supporting/TerminalSessionStatus.swift

import Testing

@testable import MinuteMindApp

@Suite("AgentSessionState Tests")
struct AgentSessionStateTests {
    @Test("Working stays working")
    func working() {
        #expect(AgentSessionState(.working) == .working)
    }

    @Test("Waiting and error need the user")
    func needsUser() {
        #expect(AgentSessionState(.waiting) == .waiting)
        #expect(AgentSessionState(.error) == .waiting)
    }

    @Test("Idle and a finished turn are idle")
    func idle() {
        #expect(AgentSessionState(.idle) == .idle)
        #expect(AgentSessionState(.done) == .idle)
    }
}
