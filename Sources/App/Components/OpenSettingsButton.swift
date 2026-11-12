// Purpose: The ways into the one Settings window: the app menu's "Settings…" (Cmd+,) and the
//          gear row at the bottom of the sidebar.
// Dependencies: Sources/App/MinuteMindApp.swift (Window scene id "settings")
// Used by: Sources/App/MinuteMindApp.swift (CommandGroup .appSettings),
//          Sources/App/Views/ProjectsSidebarView.swift (footer)
// Notes: Settings is a window of its own, not a sheet on one page, so it opens the same way from
//        every page and can stay open beside the app. Opening it activates MinuteMind, since the
//        menu item can be reached while another app's window is in front.

import AppKit
import SwiftUI

/// Opens (or brings forward) the Settings window.
struct OpenSettingsAction {
    let openWindow: OpenWindowAction

    func callAsFunction() {
        NSApp.activate()
        openWindow(id: "settings")
    }
}

/// The app menu item, "Settings…" with Cmd+,.
struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings\u{2026}") { OpenSettingsAction(openWindow: openWindow)() }
            .keyboardShortcut(",", modifiers: .command)
    }
}

/// The sidebar's footer row, styled like the sidebar's destinations but never selected.
struct SidebarSettingsRow: View {
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    var body: some View {
        Button {
            OpenSettingsAction(openWindow: openWindow)()
        } label: {
            HStack(spacing: DesignSystem.Dimensions.spacingS) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 18)
                Text("Settings")
                    .font(DesignSystem.Typography.callout)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, DesignSystem.Dimensions.spacingM)
            .padding(.vertical, DesignSystem.Dimensions.spacingS)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                    .fill(isHovered ? DesignSystem.Colors.textPrimary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open Settings (\u{2318},)")
    }
}
