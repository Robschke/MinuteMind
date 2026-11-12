// Purpose: The onboarding's setup pages around the permissions and the tour: Welcome, Claude
//          (Claude Code check + one-click MCP), the speech models (Parakeet and Nemotron 3) and the
//          finish page with what is still missing and the restart.
// Dependencies: Sources/App/Supporting/OnboardingFlow.swift (downloads, finish, restart),
//               Sources/App/Supporting/OnboardingClaudeSetup.swift (CLI and MCP),
//               Sources/App/Supporting/OnboardingPermissions.swift (missing permissions),
//               Sources/App/Views/OnboardingView.swift (page layout, creature),
//               Sources/App/ViewModels/AppViewModel.swift (Parakeet progress, MCP server)
// Used by: Sources/App/Views/OnboardingView.swift
// Notes: The finish page waits for running downloads before it offers the restart, so the one
//        restart settles permissions, models and the Claude lookup together. A failed or skipped
//        download does not block it: the models can be installed later in Settings, Automation.
//        Only a rerun from the Help menu may close without restarting.

import AppKit
import SwiftUI

// MARK: - Welcome

struct OnboardingWelcomePage: View {
    var body: some View {
        OnboardingPage(
            title: "Welcome to MinuteMind",
            subtitle: "Your meetings, recorded, transcribed and summarised on your Mac, with Claude at your side.",
            illustration: {
                TimelineView(.animation(minimumInterval: 1.0 / 8)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    OnboardingCreature(mood: .celebrating, time: time,
                                       moodAge: time.truncatingRemainder(dividingBy: 6))
                }
            }
        ) {
            OnboardingPoint(symbol: "lock.shield", text: "First the permissions macOS asks for, one at a time, each with the reason.")
            OnboardingPoint(symbol: "sparkles", text: "Then Claude Code and the speech models, which download while you read on.")
            OnboardingPoint(symbol: "keyboard", text: "A short tour of the keys, the companion and projects.")
            OnboardingPoint(symbol: "arrow.clockwise", text: "At the end MinuteMind restarts once, and everything is ready.")
        }
    }
}

// MARK: - Claude

struct OnboardingClaudePage: View {
    @Environment(AppViewModel.self) private var viewModel
    private var setup: OnboardingClaudeSetup { OnboardingFlow.shared.claude }
    @State private var copied = false

    var body: some View {
        OnboardingPage(
            symbol: "sparkles", title: "Connect Claude",
            subtitle: "Summaries, tasks, knowledge and the Claude key run on Claude Code with your Claude subscription."
        ) {
            switch setup.cli {
            case .checking:
                HStack { Spacer(); ProgressView().controlSize(.small); Text("Looking for Claude Code\u{2026}"); Spacer() }
            case .missing:
                missingCLI
            case .found:
                OnboardingStatusLabel(text: "Claude Code is installed", symbol: "checkmark.circle.fill",
                                      color: DesignSystem.Colors.success)
                mcpSection
            }
        }
        .task { await setup.checkCLI(server: viewModel.mcpServer) }
    }

    private var missingCLI: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingM) {
            OnboardingPoint(symbol: "exclamationmark.triangle",
                            text: "Claude Code is not installed yet. Without it MinuteMind still records and transcribes, but writes no summaries.")
            OnboardingPoint(symbol: "terminal", text: "Install it from Terminal, then run `claude` once there to log in:")
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Text(OnboardingClaudeSetup.installCommand)
                    .font(DesignSystem.Typography.monoCaption)
                    .textSelection(.enabled)
                    .padding(DesignSystem.Dimensions.spacingS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DesignSystem.Colors.card))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(OnboardingClaudeSetup.installCommand, forType: .string)
                    copied = true
                }
            }
            HStack {
                Spacer()
                Button("Check Again") { Task { await setup.checkCLI(server: viewModel.mcpServer) } }
                    .controlSize(.large)
                Spacer()
            }
        }
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingM) {
            OnboardingPoint(symbol: "point.3.connected.trianglepath.dotted",
                            text: "Add MinuteMind to Claude Code, so every Claude Code session on this Mac can look up your meetings, tasks, notes and knowledge, and add to them.")
            OnboardingPoint(symbol: "lock",
                            text: "It stays on this Mac (127.0.0.1) and is protected by a token only Claude Code receives.")
            HStack {
                Spacer()
                switch setup.mcp {
                case .added:
                    OnboardingStatusLabel(text: "MinuteMind is added to Claude Code", symbol: "checkmark.circle.fill",
                                          color: DesignSystem.Colors.success)
                case .working:
                    ProgressView().controlSize(.small)
                    Text("Adding\u{2026}")
                case .unknown, .failed:
                    Button {
                        Task { await setup.registerMCP(server: viewModel.mcpServer) }
                    } label: {
                        Text("Add MinuteMind to Claude Code").padding(.horizontal, DesignSystem.Dimensions.spacingS)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Spacer()
            }
            if case .failed(let message) = setup.mcp {
                Text(message)
                    .font(DesignSystem.Typography.footnote)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Speech models

struct OnboardingModelsPage: View {
    @Environment(AppViewModel.self) private var viewModel
    private var flow: OnboardingFlow { OnboardingFlow.shared }

    var body: some View {
        OnboardingPage(
            symbol: "waveform.badge.mic", title: "Download the speech models",
            subtitle: "Both run on your Mac, so audio never leaves it. The download keeps going while you continue."
        ) {
            OnboardingModelRow(
                name: "Parakeet (NVIDIA)", detail: "Transcription in 25 languages",
                isReady: viewModel.parakeetModelInstalled,
                isBusy: viewModel.isInstallingParakeet,
                progress: viewModel.isInstallingParakeet && viewModel.parakeetDownloadProgress > 0
                    ? viewModel.parakeetDownloadProgress : nil)
            OnboardingModelRow(
                name: "Nemotron 3 (NVIDIA)", detail: "Who said what: tells up to 8 speakers apart",
                isReady: viewModel.speakerDiarizationModels.isNemotronInstalled,
                isBusy: viewModel.speakerDiarizationModels.isDownloadingNemotron
                    || viewModel.speakerDiarizationModels.isDownloading,
                progress: nil)
            OnboardingDownloadControls()
                .padding(.top, DesignSystem.Dimensions.spacingS)
        }
    }
}

/// Start, progress, retry: shared by the models page and the finish page.
struct OnboardingDownloadControls: View {
    @Environment(AppViewModel.self) private var viewModel
    private var flow: OnboardingFlow { OnboardingFlow.shared }

    var body: some View {
        HStack {
            Spacer()
            switch flow.downloads {
            case .notStarted:
                Button {
                    flow.startDownloads(viewModel)
                } label: {
                    Text("Download Models").padding(.horizontal, DesignSystem.Dimensions.spacingS)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            case .downloading:
                Text("Downloading\u{2026} you can continue meanwhile.")
                    .font(DesignSystem.Typography.footnote)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            case .done:
                OnboardingStatusLabel(text: "Models ready, speaker detection is on", symbol: "checkmark.circle.fill",
                                      color: DesignSystem.Colors.success)
            case .failed(let message):
                VStack(spacing: DesignSystem.Dimensions.spacingS) {
                    Text(message)
                        .font(DesignSystem.Typography.footnote)
                        .foregroundStyle(DesignSystem.Colors.error)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { flow.retryDownloads(viewModel) }
                }
            }
            Spacer()
        }
    }
}

struct OnboardingModelRow: View {
    let name: String
    let detail: String
    let isReady: Bool
    let isBusy: Bool
    let progress: Double?

    var body: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(DesignSystem.Typography.callout.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.footnote)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
            if isReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DesignSystem.Colors.success)
            } else if isBusy {
                if let progress {
                    ProgressView(value: progress).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Text("Not installed")
                    .font(DesignSystem.Typography.footnote)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
        .padding(DesignSystem.Dimensions.spacingM)
        .background(RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius).fill(DesignSystem.Colors.card))
    }
}

// MARK: - Finish

struct OnboardingFinishPage: View {
    @Environment(AppViewModel.self) private var viewModel
    private var flow: OnboardingFlow { OnboardingFlow.shared }
    @State private var missing: [OnboardingPermission] = []

    var body: some View {
        OnboardingPage(
            title: flow.downloads == .downloading ? "Almost there" : "You\u{2019}re all set",
            subtitle: "MinuteMind restarts once so macOS applies the permissions. It opens on General, ready to record.",
            illustration: {
                TimelineView(.animation(minimumInterval: 1.0 / 8)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    OnboardingCreature(mood: flow.downloads == .downloading ? .working : .celebrating, time: time,
                                       moodAge: time.truncatingRemainder(dividingBy: 6))
                }
            }
        ) {
            checklist
            HStack(spacing: DesignSystem.Dimensions.spacingM) {
                Spacer()
                if flow.isRerun {
                    Button("Close Without Restart") { flow.finish(restart: false, viewModel: viewModel) }
                        .controlSize(.large)
                }
                Button {
                    flow.finish(restart: true, viewModel: viewModel)
                } label: {
                    Text(flow.downloads == .downloading ? "Waiting for Downloads\u{2026}" : "Restart MinuteMind")
                        .padding(.horizontal, DesignSystem.Dimensions.spacingS)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(flow.downloads == .downloading)
                Spacer()
            }
            .padding(.top, DesignSystem.Dimensions.spacingM)
        }
        .task {
            while !Task.isCancelled {
                var still: [OnboardingPermission] = []
                for permission in OnboardingPermission.allCases {
                    let state = await OnboardingPermissionCheck.state(of: permission)
                    if state == .notDetermined || state == .denied { still.append(permission) }
                }
                missing = still
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var checklist: some View {
        OnboardingChecklistRow(
            title: missing.isEmpty ? "Permissions allowed" : "Still missing: \(missing.map(\.title).joined(separator: ", "))",
            isDone: missing.isEmpty
        ) {
            if let first = missing.first {
                Button("Allow \(first.title)") {
                    Task { _ = await OnboardingPermissionCheck.request(first, calendarService: viewModel.calendarService) }
                }
            }
        }
        OnboardingChecklistRow(title: speechModelsTitle, isDone: flow.downloads == .done) {
            if flow.downloads == .downloading {
                ProgressView().controlSize(.small)
            } else if flow.downloads != .done {
                Button(flow.downloads == .notStarted ? "Download" : "Try Again") {
                    flow.downloads == .notStarted ? flow.startDownloads(viewModel) : flow.retryDownloads(viewModel)
                }
            }
        }
        OnboardingChecklistRow(title: claudeTitle, isDone: flow.claude.mcp == .added) {
            if flow.claude.mcp != .added {
                Button("Set Up") { flow.jump(to: .claude) }
            }
        }
        OnboardingChecklistRow(title: "General workspace ready for meetings without a project", isDone: true) {}
    }

    private var speechModelsTitle: String {
        switch flow.downloads {
        case .done: "Parakeet and Nemotron 3 installed, speaker detection on"
        case .downloading: "Downloading the speech models\u{2026}"
        case .failed: "Speech models not installed (also possible later in Settings, Automation)"
        case .notStarted: "Speech models not downloaded (also possible later in Settings, Automation)"
        }
    }

    private var claudeTitle: String {
        switch flow.claude.cli {
        case .missing: "Claude Code not installed: summaries stay off until it is"
        case .checking, .found:
            flow.claude.mcp == .added ? "Claude Code connected to MinuteMind" : "MinuteMind not yet added to Claude Code"
        }
    }
}

struct OnboardingChecklistRow<Trailing: View>: View {
    let title: String
    let isDone: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingM) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isDone ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
            Text(title)
                .font(DesignSystem.Typography.callout)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing()
        }
        .padding(DesignSystem.Dimensions.spacingM)
        .background(RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius).fill(DesignSystem.Colors.card))
    }
}
