// Purpose: MeetingMinutesSettingsView, the Settings sheet. A segmented control picks the page: Automation, Audio, Appearance, AI, Dictionary, Integrations, Storage, and Help.
// Dependencies: Sources/App/Views/AutomationSettingsView.swift (Automation tab),
//               Sources/App/Views/IntegrationsSettingsView.swift (Integrations tab, MCP server),
//               Sources/App/Views/AudioSettingsView.swift (Audio tab, microphone),
//               Sources/App/Views/AppearanceSettingsView.swift (Appearance tab, themes),
//               Sources/App/Views/AISettingsView.swift (AI tab: Claude model, summary prompts),
//               Sources/App/Config/AutomationSettings.swift (injected as environmentObject),
//               Sources/App/ViewModels/AppViewModel.swift (requestedSettingsTab: a page Claude opens over MCP)
// Dependents: ContentView.swift (.sheet(isPresented:) trigger unchanged)
// Notes: AutomationSettings is injected as .environmentObject so AutomationSettingsView and
//        AISettingsView can bind to it via @EnvironmentObject var settings: AutomationSettings.
//        The page switch is a plain segmented Picker, not a TabView: inside the sheet's NavigationStack
//        the TabView's own tab strip collapsed to a sliver with all names drawn on top of each other.

import SwiftUI

struct MeetingMinutesSettingsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var tab: Tab = .automation

    enum Tab: String, CaseIterable, Identifiable {
        case automation = "Automation", audio = "Audio", appearance = "Appearance", ai = "AI"
        case dictionary = "Dictionary", integrations = "Integrations", storage = "Storage", help = "Help"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("Settings", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 900, minHeight: 700)
        .onAppear(perform: applyRequestedTab)
        .onChange(of: viewModel.requestedSettingsTab) { _, _ in applyRequestedTab() }
    }

    /// A page Claude asked to open (AppViewModel+AppControl.swift).
    private func applyRequestedTab() {
        guard let requested = viewModel.requestedSettingsTab else { return }
        tab = requested
        viewModel.requestedSettingsTab = nil
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .automation: AutomationSettingsView().environmentObject(viewModel.automationSettings)
        case .audio: AudioSettingsView()
        case .appearance: AppearanceSettingsView()
        case .ai: AISettingsView().environmentObject(viewModel.automationSettings)
        case .dictionary: DictionarySettingsView()
        case .integrations: IntegrationsSettingsView()
        case .storage: StorageManagementSettingsView()
        case .help: HelpSettingsView()
        }
    }
}
