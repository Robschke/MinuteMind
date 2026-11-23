// Purpose: Tests for when a cockpit creature bounces (a session that needs the user) and for the
//          shape of its hop.
// Dependencies: Sources/App/Components/AgentAttentionJump.swift (AgentAttention, AgentAttentionJump),
//               Sources/App/Supporting/TerminalSessionStatus.swift

import Testing

@testable import MinuteMindApp

@Suite("AgentAttention Tests")
struct AgentAttentionTests {
    @Test("Waiting and error need the user until answered")
    func waiting() {
        #expect(AgentAttention.needsUser(status: .waiting, finishedUnseen: false))
        #expect(AgentAttention.needsUser(status: .error, finishedUnseen: false))
    }

    @Test("A finished turn needs the user only while unseen")
    func finished() {
        #expect(AgentAttention.needsUser(status: .done, finishedUnseen: true))
        #expect(!AgentAttention.needsUser(status: .done, finishedUnseen: false))
    }

    @Test("Working and idle sessions do not")
    func quiet() {
        #expect(!AgentAttention.needsUser(status: .working, finishedUnseen: false))
        #expect(!AgentAttention.needsUser(status: .idle, finishedUnseen: false))
    }
}

@Suite("AgentAttentionJump Tests")
struct AgentAttentionJumpTests {
    @Test("Each hop starts and lands on the ground, peaks at 3 pt halfway, twice a second")
    func hop() {
        #expect(AgentAttentionJump.lift(at: 0) == 0)
        #expect(abs(AgentAttentionJump.lift(at: 0.25) - 3) < 0.0001)
        #expect(AgentAttentionJump.lift(at: 0.5) < 0.0001)
        #expect(abs(AgentAttentionJump.lift(at: 0.75) - 3) < 0.0001)
    }

    @Test("It never sinks below rest or rises above its peak")
    func bounds() {
        for step in 0..<100 {
            let lift = AgentAttentionJump.lift(at: Double(step) * 0.013)
            #expect(lift >= 0 && lift <= 3.0001)
        }
    }
}
