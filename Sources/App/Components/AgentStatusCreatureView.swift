// Purpose: AgentStatusCreatureView, a project's creature that shows what its Claude sessions do
//          with the desktop companions' poses: typing on its laptop while one works, waving while
//          one waits, the error face, a thumb up with a green check while a finished turn is
//          still unseen, and asleep with a drifting "z" while its sessions idle. Used where the
//          app lists projects' agents (Home tiles, the Agents list).
// Dependencies: Sources/App/Supporting/AssistantMascotPose.swift (moods, frames),
//               Sources/App/Views/CompanionView.swift (MascotCanvas, MascotBubbleView),
//               Sources/App/Supporting/WorkspaceTerminalStore.swift (status, finishedUnseen),
//               Sources/App/ViewModels/AppViewModel+Companion.swift (projectAvatar)
// Used by: Sources/App/Views/HomeView.swift, Sources/App/Views/ProjectAgentsSection.swift
// Notes: The mood follows the desktop companion's priority (`MascotMood.resolve`): waiting, then
//        error, then a finished turn, then working. A finished turn counts only while unseen:
//        the done sign stays until the user focuses that session, not for a few seconds as on the
//        desktop, so a later glance still tells. Sessions with nothing to show (idle, or a done
//        turn already seen) sleep; a project without sessions stands still and awake exactly like
//        ProjectAvatarView.
//        Frames are sampled four times a second while it types or waves, twice while it sleeps;
//        Reduce Motion gives the still pose of the mood. Waiting keeps waving until answered, as
//        the sidekicks do, and the mouth never flaps (`moodAge` past the talk time).
//        The check and the "z" are the desktop companion's bubbles, top left so the check clears
//        the raised thumb (top right), the tail pointing at the head. They may overhang the
//        creature's frame; both callers leave padding there.

import SwiftUI

enum AgentCreatureMood {
    /// One mood for a project's sessions; `finishedUnseen` marks a done turn not looked at yet.
    static func mood(_ sessions: [(status: TerminalSessionStatus, finishedUnseen: Bool)]) -> MascotMood {
        var signals = MascotMood.Signals()
        signals.claudeStatuses = sessions.map(\.status)
        signals.isCelebrating = sessions.contains { $0.status == .done && $0.finishedUnseen }
        switch MascotMood.resolve(signals) {
        case .celebrating: return .thumbsUp
        case .idle: return sessions.isEmpty ? .idle : .sleeping
        case let mood: return mood
        }
    }
}

struct AgentStatusCreatureView: View {
    let projectID: UUID
    /// The Claude sessions it stands for (plain terminals left out by the caller).
    let sessions: [WorkspaceTerminalSession]
    /// Side of one creature pixel in points; the view is 12 by 16 pixels.
    var pixelSize: CGFloat
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = viewModel.projectAvatar(for: projectID)
        let mood = AgentCreatureMood.mood(sessions.map { (status: $0.status, finishedUnseen: $0.finishedUnseen) })
        AgentCreature(avatar: look.avatar, color: look.color, mood: mood, pixelSize: pixelSize, animated: !reduceMotion)
            .accessibilityHidden(true)
    }
}

private struct AgentCreature: View {
    let avatar: MascotAvatar
    let color: Color?
    let mood: MascotMood
    let pixelSize: CGFloat
    let animated: Bool

    /// Past `AssistantMascotPose.talkDuration`, so the mouth stays still.
    private static let settledMoodAge: TimeInterval = 60

    /// Seconds between frames: typing and waving step four times a second, the sleeping "z"
    /// twice; nil for a still pose.
    private var frameInterval: TimeInterval? {
        guard animated else { return nil }
        switch mood {
        case .working, .waiting: return 0.25
        case .sleeping: return 0.5
        default: return nil
        }
    }

    /// The bubble's pixel: three quarters of the creature's, whole points so it stays crisp.
    private var bubblePixel: CGFloat { max(1, (pixelSize * 3 / 4).rounded()) }

    var body: some View {
        if let interval = frameInterval {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                creature(time: context.date.timeIntervalSinceReferenceDate, animated: true)
            }
        } else {
            creature(time: 0.05, animated: false)
        }
    }

    private func creature(time: TimeInterval, animated: Bool) -> some View {
        let frame = AssistantMascotPose.frame(.init(
            mood: mood, time: time, look: nil, moodAge: Self.settledMoodAge,
            avatar: avatar, animated: animated, keepsWaving: true))
        // Only the check and the "z": typing and waving speak through the pose alone.
        let bubble: MascotBubble? = switch mood {
        case .thumbsUp: .done
        case .sleeping: frame.bubble
        default: nil
        }
        return ZStack(alignment: .topLeading) {
            MascotCanvas(frame: frame, avatar: avatar, pixelSize: pixelSize, bodyColor: color)
            if let bubble {
                // The bubble's tail tip (bubble pixel 5, 6) lands at creature pixel (2, 3), above
                // the head's left edge.
                MascotBubbleView(bubble: bubble, pixelSize: bubblePixel)
                    .offset(x: 2 * pixelSize - 5 * bubblePixel, y: 3 * pixelSize - 7 * bubblePixel)
            }
        }
    }
}
