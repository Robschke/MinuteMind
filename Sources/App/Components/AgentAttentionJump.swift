// Purpose: AgentAttentionJump, the bounce of a creature whose Claude session needs the user: one
//          waiting for an answer (or stopped on an error), or one whose finished turn has not been
//          looked at yet. Used by the agent cockpit's sidebar.
// Dependencies: Sources/App/Views/ProjectAgentsSection.swift (AgentSessionState),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (status, finishedUnseen)
// Used by: Sources/App/Views/AgentCockpitSidebar.swift; tested in Tests/AgentAttentionJumpTests.swift
// Notes: The bounce lasts exactly as long as the state does: a waiting session until it is
//        answered, a finished one until the user focuses it (`finishedUnseen`). It adds to the
//        creature's pose (waving, thumb up), it does not replace it.
//        The hop is computed from the clock in a TimelineView, like ArrangeWiggle, because
//        repeatForever animations do not reliably stop and a paused TimelineView costs nothing.
//        It stays in the view tree when inactive so the creature keeps its identity and its own
//        frame timer. Every creature hops in step; two hops a second, a few points high, which
//        fits inside the 26 pt sidebar row. No motion with Reduce Motion on.

import SwiftUI

enum AgentAttention {
    /// Whether the session needs the user: waiting (or errored) or finished and still unseen.
    @MainActor
    static func needsUser(_ session: WorkspaceTerminalSession) -> Bool {
        needsUser(status: session.status, finishedUnseen: session.finishedUnseen)
    }

    static func needsUser(status: TerminalSessionStatus, finishedUnseen: Bool) -> Bool {
        switch AgentSessionState(status, finishedUnseen: finishedUnseen) {
        case .waiting, .finished: true
        case .working, .idle: false
        }
    }
}

struct AgentAttentionJump: ViewModifier {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds per hop.
    private static let period: TimeInterval = 0.5
    /// Peak height in points.
    private static let height: CGFloat = 3

    func body(content: Content) -> some View {
        let moving = active && !reduceMotion
        TimelineView(.animation(minimumInterval: nil, paused: !moving)) { context in
            content.offset(y: moving ? -Self.lift(at: context.date.timeIntervalSinceReferenceDate) : 0)
        }
    }

    /// Height above rest at `time`: a parabola per hop, so it lands and leaves the ground quickly
    /// and hangs briefly at the top.
    static func lift(at time: TimeInterval) -> CGFloat {
        let phase = (time / period).truncatingRemainder(dividingBy: 1)
        return height * CGFloat(4 * phase * (1 - phase))
    }
}

extension View {
    /// Bounces the view while `active`; see AgentAttentionJump.
    func agentAttentionJump(_ active: Bool) -> some View {
        modifier(AgentAttentionJump(active: active))
    }
}
