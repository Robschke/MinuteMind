// Purpose: OnboardingView, the first-launch setup shown in place of the main window's content:
//          one step at a time with Back, a progress row of dots and Continue, plus the building
//          blocks every page uses (page layout, points, key caps, the pixel creature).
// Dependencies: Sources/App/Supporting/OnboardingFlow.swift (steps and progress),
//               Sources/App/Views/OnboardingPermissionPage.swift, OnboardingSetupPages.swift,
//               OnboardingTourPages.swift (the pages),
//               Sources/App/Supporting/AssistantMascotPose.swift + Views/CompanionView.swift
//               (MascotCanvas), Sources/App/Components/DesignSystem.swift
// Used by: Sources/App/Views/ContentView.swift
// Notes: The Continue button's label comes from OnboardingFlow.continueLabel ("Not now" while a
//        step is still open, none on the finish page, which has its own buttons). Content is
//        capped at 620 pt wide and scrolls on small windows.

import SwiftUI

struct OnboardingView: View {
    @Environment(AppViewModel.self) private var viewModel
    private var flow: OnboardingFlow { OnboardingFlow.shared }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                page
                    .id(flow.step.id)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DesignSystem.Dimensions.spacingXXXL)
                    .padding(.top, 56)
                    .padding(.bottom, DesignSystem.Dimensions.spacingXXL)
                    .transition(.opacity)
            }
            .animation(DesignSystem.Animation.gentle, value: flow.index)
            Divider()
            footer
        }
        .background(DesignSystem.Colors.surface)
        .onAppear { flow.refreshModelState(viewModel) }
    }

    @ViewBuilder
    private var page: some View {
        switch flow.step {
        case .welcome: OnboardingWelcomePage()
        case .permission(let permission): OnboardingPermissionPage(permission: permission)
        case .claude: OnboardingClaudePage()
        case .models: OnboardingModelsPage()
        case .tour(let topic): OnboardingTourPage(topic: topic)
        case .finish: OnboardingFinishPage()
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { flow.back() }
                .opacity(flow.isFirst ? 0 : 1)
                .disabled(flow.isFirst)
                .frame(width: 120, alignment: .leading)
            Spacer()
            OnboardingProgressDots(count: OnboardingFlow.steps.count, current: flow.index)
            Spacer()
            HStack {
                if let continueLabel = flow.continueLabel {
                    Button(continueLabel) { flow.next() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingXXL)
        .padding(.vertical, DesignSystem.Dimensions.spacingL)
    }
}

// MARK: - Building blocks

/// A page: illustration, title, subtitle, then the page's rows.
struct OnboardingPage<Illustration: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let illustration: () -> Illustration
    @ViewBuilder let content: () -> Content

    init(title: String, subtitle: String,
         @ViewBuilder illustration: @escaping () -> Illustration,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.illustration = illustration
        self.content = content
    }

    var body: some View {
        VStack(spacing: DesignSystem.Dimensions.spacingXXL) {
            VStack(spacing: DesignSystem.Dimensions.spacingL) {
                illustration()
                    .frame(height: 96)
                Text(title)
                    .font(DesignSystem.Typography.title1)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DesignSystem.Dimensions.spacingM) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension OnboardingPage where Illustration == OnboardingSymbol {
    init(symbol: String, title: String, subtitle: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, illustration: { OnboardingSymbol(name: symbol) }, content: content)
    }
}

/// A large SF Symbol in a tinted circle, the illustration of most pages.
struct OnboardingSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 38, weight: .medium))
            .foregroundStyle(DesignSystem.Colors.accent)
            .frame(width: 88, height: 88)
            .background(Circle().fill(DesignSystem.Colors.accent.opacity(0.12)))
    }
}

/// One explanation line with a small symbol in front.
struct OnboardingPoint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Dimensions.spacingM) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 22)
            Text(text)
                .font(DesignSystem.Typography.callout)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A shortcut line: drawn keys (with an optional "hold" / "tap twice" under them) and what it does.
struct OnboardingShortcutRow: View {
    let keys: [String]
    var caption: String?
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Dimensions.spacingM) {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        OnboardingKeyCap(label: key)
                    }
                }
                if let caption {
                    Text(caption)
                        .font(DesignSystem.Typography.caption2)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }
            .frame(minWidth: 110, alignment: .center)
            Text(text)
                .font(DesignSystem.Typography.callout)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DesignSystem.Dimensions.spacingS)
        .padding(.horizontal, DesignSystem.Dimensions.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                .fill(DesignSystem.Colors.card)
        )
    }
}

/// A keyboard key drawn as a small raised cap.
struct OnboardingKeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(DesignSystem.Colors.card)
                    .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
            )
    }
}

/// The user's companion creature, drawn large in one mood.
struct OnboardingCreature: View {
    let mood: MascotMood
    let time: TimeInterval
    var moodAge: TimeInterval = 0

    var body: some View {
        let avatar = CompanionAppearance.shared.avatar
        let frame = AssistantMascotPose.frame(
            .init(mood: mood, time: time, look: nil, moodAge: moodAge, avatar: avatar, keepsWaving: true))
        MascotCanvas(frame: frame, avatar: avatar, pixelSize: 5)
            .frame(width: 80, height: 96)
            .accessibilityHidden(true)
    }
}

/// The step dots in the footer: done steps filled, the current one wide.
struct OnboardingProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { position in
                Capsule()
                    .fill(position <= current ? DesignSystem.Colors.accent : DesignSystem.Colors.border)
                    .frame(width: position == current ? 16 : 6, height: 6)
            }
        }
        .animation(DesignSystem.Animation.quick, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}
