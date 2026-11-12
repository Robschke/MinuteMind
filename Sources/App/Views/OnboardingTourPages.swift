// Purpose: The onboarding's introduction: one illustrated card per topic (recording, dictation and
//          the Claude key, Claude, the desktop companion, projects) with drawn key caps for the
//          shortcuts.
// Dependencies: Sources/App/Views/OnboardingView.swift (page layout, key caps, creature),
//               Sources/App/Config/AutomationSettings.swift (which dictation key is set)
// Used by: Sources/App/Supporting/OnboardingFlow.swift (tour steps),
//          Sources/App/Views/OnboardingView.swift (page switch)
// Notes: The shortcuts shown are the ones registered in MinuteMindApp.setupHotkeys and the
//        workspace strip; when one changes there, change it here too. The dictation key follows the
//        user's setting (fn by default); the toggle mode has no hold key, so the Claude key and
//        quick recording are described as needing a hold key.

import SwiftUI

enum OnboardingTourTopic: String, CaseIterable, Identifiable, Sendable {
    case recording, voice, claude, companion, projects
    var id: String { rawValue }
}

struct OnboardingTourPage: View {
    let topic: OnboardingTourTopic
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        switch topic {
        case .recording: recording
        case .voice: voice
        case .claude: claude
        case .companion: companion
        case .projects: projects
        }
    }

    // MARK: - Pages

    private var recording: some View {
        OnboardingPage(
            symbol: "record.circle", title: "Record your meetings",
            subtitle: "MinuteMind notices calls and turns them into transcripts, summaries and tasks."
        ) {
            OnboardingPoint(symbol: "dot.radiowaves.left.and.right",
                            text: "When Teams, Zoom, Meet or another call app uses your microphone, the companion offers to record. Calendar meetings are offered too.")
            OnboardingShortcutRow(keys: ["\u{21E7}", "\u{2318}", "R"], text: "Start recording, or record the meeting on offer")
            OnboardingPoint(symbol: "stop.circle",
                            text: "A recording only ends when you stop it. When the call is over, the companion asks.")
            OnboardingPoint(symbol: "folder",
                            text: "Afterwards pick the project. Transcript, summary, tasks and knowledge follow on their own.")
            OnboardingShortcutRow(keys: ["\u{2303}", "\u{2325}", "P"], text: "Process the meeting just saved")
        }
    }

    private var voice: some View {
        let mode = viewModel.automationSettings.quickDictationMode
        let key = mode == "holdFn" ? "fn" : "right \u{2325}"
        return OnboardingPage(
            symbol: "waveform", title: "Talk instead of typing",
            subtitle: "One key for dictation, Claude and quick voice notes, in every app."
        ) {
            if mode == "toggle" {
                OnboardingShortcutRow(keys: ["\u{2303}", "\u{2325}", "D"], text: "Start dictating, press again to put the text at your cursor")
                OnboardingPoint(symbol: "info.circle",
                                text: "The Claude key and quick recordings need a hold key (fn or right Option), set in Settings, Automation.")
            } else {
                OnboardingShortcutRow(keys: [key], caption: "hold", text: "Dictate: speak, let go, the text lands at your cursor")
                OnboardingShortcutRow(keys: [key, "\u{2303}"], caption: "hold", text: "Ask Claude: it acts or answers. Selected text goes along, so \u{201C}translate this\u{201D} just works.")
                OnboardingShortcutRow(keys: [key], caption: "tap twice", text: "Quick recording for a thought or a hallway chat; press once more to stop")
            }
            OnboardingPoint(symbol: "character.book.closed",
                            text: "Names it gets wrong go into the Dictionary (Settings), and every transcript uses them.")
        }
    }

    private var claude: some View {
        OnboardingPage(
            symbol: "sparkles", title: "Claude does the thinking",
            subtitle: "Claude Code runs on your own Claude subscription; MinuteMind needs no API key."
        ) {
            OnboardingPoint(symbol: "doc.text.magnifyingglass",
                            text: "Cleans up transcripts and writes summaries, titles, tasks and the project knowledge.")
            OnboardingPoint(symbol: "terminal",
                            text: "Every project's Workspace tab has Claude sessions that know its meetings and knowledge.")
            OnboardingShortcutRow(keys: ["\u{2325}", "\u{2318}", "N"], text: "New Claude session in the open workspace")
            OnboardingPoint(symbol: "cursorarrow.click",
                            text: "The Claude button on the companion's card opens Claude (General), your assistant outside any project.")
            OnboardingPoint(symbol: "point.3.connected.trianglepath.dotted",
                            text: "Through MCP, any Claude Code session on this Mac can read and change your meetings, tasks and notes.")
        }
    }

    private var companion: some View {
        OnboardingPage(
            title: "Meet your companion",
            subtitle: "It lives in the corner of the window and shows what is going on.",
            illustration: { OnboardingCompanionCycle() }
        ) {
            OnboardingPoint(symbol: "cursorarrow.click",
                            text: "Click: Record, Claude and the clipboard. Right click: everything else.")
            OnboardingPoint(symbol: "cursorarrow.click.2",
                            text: "Double click: every Claude window comes to you; double click again puts them back.")
            OnboardingPoint(symbol: "scroll",
                            text: "Scroll over it while recording to pick the project.")
            OnboardingPoint(symbol: "person.3",
                            text: "Projects can wear their own avatar. Their little creatures stand behind it: typing while Claude works, waving when it needs you. Double click one to open that session.")
            OnboardingPoint(symbol: "hand.wave",
                            text: "Drag it anywhere. Shake the mouse and it runs to the pointer.")
        }
    }

    private var projects: some View {
        OnboardingPage(
            symbol: "folder.fill", title: "Projects hold everything",
            subtitle: "A project is where a topic's meetings, tasks and knowledge come together."
        ) {
            OnboardingPoint(symbol: "tray.full",
                            text: "Each project has an overview of its tasks and recordings, and a Workspace: a folder with every transcript and summary plus knowledge files Claude keeps up to date.")
            OnboardingPoint(symbol: "square.stack",
                            text: "General takes meetings that belong to no project, and is your Claude's home folder.")
            OnboardingPoint(symbol: "calendar.badge.clock",
                            text: "Link a recurring calendar meeting to a project once, and every recording of it is filed there.")
            OnboardingPoint(symbol: "star",
                            text: "Star a project (right click in the sidebar) to put it first when you scroll over the companion.")
            OnboardingPoint(symbol: "clock.arrow.circlepath",
                            text: "Jobs are prompts Claude runs on a schedule inside a project, such as a Monday status report.")
        }
    }
}

/// The companion on its tour page: it idles, works, waves and gives a thumb up in turn.
struct OnboardingCompanionCycle: View {
    private static let moods: [(MascotMood, String)] = [
        (.idle, "Idle"), (.working, "Claude works"), (.waiting, "Claude needs you"), (.thumbsUp, "Done"),
    ]
    private static let moodLength: TimeInterval = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let slot = Int(time / Self.moodLength) % Self.moods.count
            let (mood, label) = Self.moods[slot]
            VStack(spacing: DesignSystem.Dimensions.spacingS) {
                OnboardingCreature(mood: mood, time: time, moodAge: time.truncatingRemainder(dividingBy: Self.moodLength))
                Text(label)
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }
}
