// Purpose: One onboarding page per macOS permission: why MinuteMind needs it, a button that asks
//          for it (or opens System Settings once it was refused), and its live state.
// Dependencies: Sources/App/Supporting/OnboardingPermissions.swift (texts, state, request),
//               Sources/App/Views/OnboardingView.swift (page layout),
//               Sources/App/Supporting/OnboardingFlow.swift (permissionStates for the Continue label)
// Used by: Sources/App/Views/OnboardingView.swift
// Notes: Every permission can be skipped ("Not now"); the finish page lists what is still missing.
//        The state is polled once a second while the page shows, because grants made in System
//        Settings arrive without any callback.

import SwiftUI

struct OnboardingPermissionPage: View {
    let permission: OnboardingPermission
    @Environment(AppViewModel.self) private var viewModel
    @State private var state: OnboardingPermissionState?
    @State private var isRequesting = false

    var body: some View {
        OnboardingPage(symbol: permission.symbol, title: permission.headline, subtitle: permission.title) {
            ForEach(permission.points, id: \.self) { point in
                OnboardingPoint(symbol: "checkmark", text: point)
            }
            HStack {
                Spacer()
                action
                Spacer()
            }
            .padding(.top, DesignSystem.Dimensions.spacingM)
        }
        .task(id: permission) {
            while !Task.isCancelled {
                record(await OnboardingPermissionCheck.state(of: permission))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Keeps the page and the flow (which names the footer's button) on the same state.
    private func record(_ newState: OnboardingPermissionState) {
        state = newState
        OnboardingFlow.shared.permissionStates[permission] = newState
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .granted:
            OnboardingStatusLabel(text: "Allowed", symbol: "checkmark.circle.fill", color: DesignSystem.Colors.success)
        case .pendingRestart:
            VStack(spacing: DesignSystem.Dimensions.spacingS) {
                OnboardingStatusLabel(text: "Takes effect after the restart", symbol: "arrow.clockwise.circle.fill",
                                      color: DesignSystem.Colors.accent)
                Button("Open System Settings") { OnboardingPermissionCheck.openSettings(for: permission) }
                    .buttonStyle(.link)
                Text("Make sure MinuteMind is switched on there.")
                    .font(DesignSystem.Typography.footnote)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        case .denied:
            VStack(spacing: DesignSystem.Dimensions.spacingS) {
                Button("Open System Settings") { OnboardingPermissionCheck.openSettings(for: permission) }
                    .controlSize(.large)
                Text("It was turned off earlier. Switch MinuteMind on in System Settings, Privacy & Security.")
                    .font(DesignSystem.Typography.footnote)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        case .notDetermined, nil:
            Button {
                Task {
                    isRequesting = true
                    record(await OnboardingPermissionCheck.request(permission, calendarService: viewModel.calendarService))
                    isRequesting = false
                }
            } label: {
                Text("Allow \(permission.title)")
                    .padding(.horizontal, DesignSystem.Dimensions.spacingS)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRequesting || state == nil)
        }
    }
}

/// A coloured status line with a symbol, used for granted permissions and finished downloads.
struct OnboardingStatusLabel: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(DesignSystem.Typography.callout.weight(.medium))
            .foregroundStyle(color)
    }
}
