// Purpose: The onboarding's introduction: one illustrated card per topic (dictation and the Claude
//          key, the desktop companion, projects) with drawn key caps for the dictation keys and
//          the main window's search and project switcher keys.
// Dependencies: Sources/App/Views/OnboardingView.swift (page layout, key caps, creature),
//               Sources/App/Config/AutomationSettings.swift (which dictation key is set)
// Used by: Sources/App/Supporting/OnboardingFlow.swift (tour steps),
//          Sources/App/Views/OnboardingView.swift (page switch)
// Notes: The keys shown are the ones registered in MinuteMindApp.setupHotkeys and in
//        MainWindowEventMonitor (Cmd+K, Shift+Tab); when one changes there, change it here too. The dictation key follows the user's setting (fn by default);
//        the toggle mode has no hold key, so the Claude key and quick recording are described as
//        needing a hold key.

import SwiftUI

enum OnboardingTourTopic: String, CaseIterable, Identifiable, Sendable {
    case voice, companion, projects
    var id: String { rawValue }
}

struct OnboardingTourPage: View {
    let topic: OnboardingTourTopic
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        switch topic {
        case .voice: voice
        case .companion: companion
        case .projects: projects
        }
    }

    // MARK: - Pages

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
                            text: "Star a project (right click in the sidebar) to put it first when you scroll over the companion and keep it in the project switcher.")
            OnboardingShortcutRow(keys: ["\u{21E7}", "\u{21E5}"], caption: "hold \u{21E7}",
                                  text: "Switch between your starred projects and those with Claude running")
            OnboardingShortcutRow(keys: ["\u{2318}", "K"],
                                  text: "Search everything: pages, projects, Claude sessions, meetings and what was said in them, knowledge")
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
