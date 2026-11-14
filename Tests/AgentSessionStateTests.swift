// Purpose: Tests for the states the project sidebar's Agents section names per Claude session,
//          folded from the five terminal statuses, and for the mood the agents' creatures show.
// Dependencies: Sources/App/Views/ProjectAgentsSection.swift (AgentSessionState),
//               Sources/App/Components/AgentStatusCreatureView.swift (AgentCreatureMood),
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
        #expect(AgentSessionState(.done, finishedUnseen: false) == .idle)
    }

    @Test("A finished turn not looked at yet is finished")
    func finished() {
        #expect(AgentSessionState(.done, finishedUnseen: true) == .finished)
        #expect(AgentSessionState(.working, finishedUnseen: true) == .working)
    }
}

@Suite("AgentCreatureMood Tests")
struct AgentCreatureMoodTests {
    @Test("No sessions or idle ones stand still")
    func idle() {
        #expect(AgentCreatureMood.mood([]) == .idle)
        #expect(AgentCreatureMood.mood([(.idle, false)]) == .idle)
    }

    @Test("A finished turn shows a thumb up only while unseen")
    func finished() {
        #expect(AgentCreatureMood.mood([(.done, true)]) == .thumbsUp)
        #expect(AgentCreatureMood.mood([(.done, false)]) == .idle)
    }

    @Test("Working types, waiting waves, error shows the error face")
    func statuses() {
        #expect(AgentCreatureMood.mood([(.working, false)]) == .working)
        #expect(AgentCreatureMood.mood([(.waiting, false)]) == .waiting)
        #expect(AgentCreatureMood.mood([(.error, false)]) == .error)
    }

    @Test("Several sessions follow the desktop companion's priority")
    func priority() {
        #expect(AgentCreatureMood.mood([(.working, false), (.waiting, false)]) == .waiting)
        #expect(AgentCreatureMood.mood([(.error, false), (.waiting, false)]) == .waiting)
        #expect(AgentCreatureMood.mood([(.working, false), (.done, true)]) == .thumbsUp)
        #expect(AgentCreatureMood.mood([(.done, true), (.error, false)]) == .error)
    }
}
