// Purpose: Settings for Claude mini tasks (dictation key held with Control): on/off, the model,
//          and the user's standing instructions that go with every task.
// Dependencies: Sources/App/Config/AutomationSettings.swift (claudeTask* keys),
//               Sources/App/Services/ClaudeTaskService.swift (model list),
//               Sources/App/Services/ClaudeCodeService.swift (installed check)
// RBAC: None.
// Dependents: Sources/App/Views/AutomationSettingsView.swift (inside the Quick Dictation section)
// Notes: Lives inside Quick Dictation because the trigger is the dictation key. Only offered for
//        the hold modes; the ⌃⌥D toggle mode has no key to hold.

import SwiftUI

struct ClaudeTaskSettingsView: View {
    @EnvironmentObject var settings: AutomationSettings
    private let claudeInstalled = ClaudeCodeService.locate() != nil

    private var keyName: String {
        settings.quickDictationMode == "holdFn" ? "fn" : "right \u{2325}"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude mini tasks")
                .font(.subheadline)

            if settings.quickDictationMode == "toggle" {
                Text("Choose a hold key above to use Claude mini tasks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Hold \(keyName) and Control, say a small task (\u{201C}write a short email to the team that the meeting moves to Friday\u{201D}), then let go. Claude's answer is inserted where your cursor is, like a dictation, and stays on the clipboard. Open Chat in the pill continues in the Claude app instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !claudeInstalled {
                    Label("Needs Claude Code installed and logged in (claude.com/code).", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Enable Claude mini tasks", isOn: $settings.claudeTaskEnabled)
                    .disabled(!settings.quickDictationEnabled)

                Picker("Model", selection: $settings.claudeTaskModel) {
                    ForEach(ClaudeTaskService.models, id: \.alias) { model in
                        Text(model.name).tag(model.alias)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)
                .disabled(!settings.claudeTaskEnabled || !settings.quickDictationEnabled)

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Let Claude run terminal commands", isOn: $settings.claudeTaskAllowsTerminal)
                    Text("Claude always uses MinuteMind (todos, calendar, notes, reminders, meetings) and the web without asking. With this on it may also run shell commands on your Mac. Deleting in MinuteMind always asks first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!settings.claudeTaskEnabled || !settings.quickDictationEnabled)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your instructions for every task")
                        .font(.caption)
                    TextEditor(text: $settings.claudeTaskPrompt)
                        .font(.body)
                        .frame(minHeight: 70, maxHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    Text("For example your name for signatures, your usual tone, or the language to write in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.claudeTaskEnabled || !settings.quickDictationEnabled)
            }
        }
    }
}
