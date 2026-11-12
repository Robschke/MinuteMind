// Purpose: Hide and show the main sidebar in full screen without the toolbar: a sidebar button
//          beside Settings in the sidebar's footer, and a corner button at the page's bottom left
//          while the sidebar is hidden.
// Dependencies: AppKit (NSWindow full screen notifications), SwiftUI NavigationSplitView
// Used by: Sources/App/Views/ContentView.swift (state, corner button, full screen reader),
//          Sources/App/Views/ProjectsSidebarView.swift (footer button),
//          Sources/App/Views/WorkspaceGitBranchBar.swift (leaves room for the corner button)
// Notes: In full screen the toolbar slides away (FullScreenToolbarAutoHide), and with it the
//        system sidebar button, so these two stand in for it. In a window the toolbar button is
//        always there and they stay hidden, so nothing shows twice. View > Show/Hide Sidebar
//        (Ctrl+Cmd+S, SidebarCommands) works in both.
//        The corner button floats over the page. On the Workspace tab that corner is the file
//        tree's branch row, which reads `sidebarCornerButtonInset` and starts after the button
//        instead of under it.

import AppKit
import SwiftUI

/// What the sidebar's footer needs to offer its hide button.
struct FullScreenSidebarControl: Sendable {
    var isFullScreen = false
    var hideSidebar: @MainActor @Sendable () -> Void = {}
}

private struct FullScreenSidebarControlKey: EnvironmentKey {
    static let defaultValue = FullScreenSidebarControl()
}

private struct SidebarCornerButtonInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Set by ContentView on the sidebar.
    var fullScreenSidebarControl: FullScreenSidebarControl {
        get { self[FullScreenSidebarControlKey.self] }
        set { self[FullScreenSidebarControlKey.self] = newValue }
    }

    /// The width the corner button takes at the page's bottom left while it shows, else 0.
    var sidebarCornerButtonInset: CGFloat {
        get { self[SidebarCornerButtonInsetKey.self] }
        set { self[SidebarCornerButtonInsetKey.self] = newValue }
    }
}

/// The sidebar symbol to the right of Settings in the sidebar's footer.
struct SidebarHideButton: View {
    let action: @MainActor () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                        .fill(isHovered ? DesignSystem.Colors.textPrimary.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Hide Sidebar (\u{2303}\u{2318}S)")
        .accessibilityLabel("Hide Sidebar")
    }
}

/// The sidebar symbol in the page's bottom left corner while the sidebar is hidden.
struct SidebarShowCornerButton: View {
    static let inset: CGFloat = 30

    let action: @MainActor () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 12))
                .foregroundStyle(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.leading, 4)
        .help("Show Sidebar (\u{2303}\u{2318}S)")
        .accessibilityLabel("Show Sidebar")
    }
}

/// Reports whether the window holding this view is in full screen.
struct WindowFullScreenReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { value in
            if isFullScreen != value { isFullScreen = value }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        // Leaving the window calls viewDidMoveToWindow with nil, which removes the observers.
        private func report() {
            onChange(window?.styleMask.contains(.fullScreen) ?? false)
        }
    }
}
