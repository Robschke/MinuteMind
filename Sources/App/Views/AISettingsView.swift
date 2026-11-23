// Purpose: AISettingsView, the "AI" tab of Settings: whether Claude Code is installed, which Claude
//          model the background jobs use, and the summary prompts.
// Dependencies: Sources/App/ViewModels/AppViewModel.swift (summaryPrompts and prompt CRUD),
//               Sources/App/Config/AutomationSettings.swift
//               (claudeModel), Sources/App/Services/AIClient.swift (models),
//               Sources/App/Store/SummaryPromptStore.swift (SystemPrompt)
// RBAC: None.
// Used by: Sources/App/Views/MeetingMinutesSettingsView.swift (AI tab)
// Notes: Replaces the AI Profiles tab. Claude Code is the only AI, so there are no keys, endpoints
//        or providers to configure: one model choice, and the prompts that used to sit inside each
//        profile. Transcript cleanup and Claude mini tasks keep their own model (Sonnet, and
//        Automation, Quick Dictation), which the caption says, so the choice here is not mistaken
//        for a global one. One prompt is in use at a time, chosen like a radio button; there is
//        no separate on/off switch (it only ever decided which prompt could be chosen). Rebuilding
//        the search index is data upkeep and lives in the Storage tab.

import SwiftUI

struct AISettingsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @EnvironmentObject private var settings: AutomationSettings
    @State private var newPromptTitle = ""
    @State private var newPromptContent = ""
    @State private var claudeInstalled = AIClient.isAvailable

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .space(20)) {
                claudeSection
                Divider()
                promptsSection
                Spacer(minLength: 20)
            }
            .padding(.space(24))
        }
        .onAppear { claudeInstalled = AIClient.isAvailable }
    }

    // MARK: - Claude

    private var claudeSection: some View {
        GroupBox(label: sectionLabel("Claude", systemImage: "sparkles")) {
            VStack(alignment: .leading, spacing: .space(12)) {
                if claudeInstalled {
                    Label("Uses your installed Claude Code and your Claude subscription. No API key needed.",
                          systemImage: "checkmark.circle.fill")
                        .font(.themed(.caption))
                        .foregroundStyle(DesignSystem.Colors.success)
                } else {
                    VStack(alignment: .leading, spacing: .space(8)) {
                        Label("Claude Code is not installed. Summaries, titles, todos and transcript correction need it.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.themed(.caption))
                            .foregroundStyle(DesignSystem.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: .space(8)) {
                            Button("Get Claude Code") {
                                if let url = URL(string: "https://claude.com/code") { NSWorkspace.shared.open(url) }
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Check Again") { claudeInstalled = AIClient.isAvailable }
                        }
                        .controlSize(.small)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: .space(6)) {
                    Text("Model")
                        .font(.themed(.subheadline))
                    Picker("Model", selection: $settings.claudeModel) {
                        ForEach(AIClient.models, id: \.self) { model in
                            Text(model.capitalized).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    Text("Haiku is fastest, Opus is most thorough, Sonnet is the balance (recommended). Used for summaries, titles, todos and project knowledge. Transcript correction always uses Sonnet. Claude mini tasks have their own model (Automation, Quick Dictation).")
                        .font(.themed(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, .space(8))
        }
    }

    // MARK: - Summary prompts

    private var promptsSection: some View {
        GroupBox(label: sectionLabel("Summary Prompts", systemImage: "text.quote")) {
            VStack(alignment: .leading, spacing: .space(12)) {
                Text("Claude follows the prompt in use for every meeting summary.")
                    .font(.themed(.caption))
                    .foregroundStyle(.secondary)

                if viewModel.summaryPrompts.isEmpty {
                    Text("No prompts yet. Without one, the built-in prompt is used.")
                        .font(.themed(.subheadline))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.summaryPrompts) { prompt in
                        PromptRow(
                            prompt: prompt,
                            canDelete: viewModel.summaryPrompts.count > 1,
                            onSelect: { viewModel.selectPrompt(prompt) },
                            onDelete: { viewModel.deletePrompt(prompt) }
                        )
                    }
                }

                newPromptForm
            }
            .padding(.top, .space(8))
        }
    }

    private var newPromptForm: some View {
        VStack(alignment: .leading, spacing: .space(8)) {
            Text("Add a prompt")
                .font(.themed(.subheadline))

            TextField("Prompt title", text: $newPromptTitle)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $newPromptContent)
                .frame(minHeight: 100)
                .font(.themed(.body))
                .overlay(
                    RoundedRectangle(cornerRadius: .corner(6))
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            Button {
                viewModel.addPrompt(title: newPromptTitle, content: newPromptContent)
                newPromptTitle = ""
                newPromptContent = ""
            } label: {
                Label("Add Prompt", systemImage: "plus.circle")
            }
            .disabled(
                newPromptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || newPromptContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.themed(.headline))
    }
}

// MARK: - Prompt Row

private struct PromptRow: View {
    let prompt: SystemPrompt
    let canDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: .space(8)) {
            HStack(alignment: .top, spacing: .space(12)) {
                VStack(alignment: .leading, spacing: .space(4)) {
                    Text(prompt.title)
                        .font(.themed(.subheadline).bold())
                    Text(prompt.content)
                        .font(.themed(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                HStack(spacing: .space(8)) {
                    Button(action: onSelect) {
                        Label(
                            prompt.isSelected ? "In use" : "Use",
                            systemImage: prompt.isSelected ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(prompt.isSelected)

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canDelete)
                    .help("Delete this prompt")
                }
            }
            Divider()
        }
        .padding(.vertical, .space(4))
    }
}
