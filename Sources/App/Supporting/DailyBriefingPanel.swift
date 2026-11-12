// Purpose: Shows the "record today?" briefing as a floating panel in the bottom-right corner, once
//          per day, the first time the app is opened.
// Dependencies: AppKit (NSPanel), Sources/App/Views/DailyBriefingView.swift,
//               Sources/App/ViewModels/AppViewModel.swift (todaysDecidableEvents)
// RBAC: None.
// Dependents: Sources/App/MinuteMindApp.swift (AppDelegate, on launch and on activation)
// Notes: Modelled on the former quick dictation HUD, with one deliberate difference: this panel *is* interactive,
//        so it must be able to become key. The HUD is the opposite — it ignores mouse events on
//        purpose so the frontmost app keeps focus while dictating.
//        "Once per day" is stored as a day stamp rather than a timestamp, so quitting and reopening
//        the app in the afternoon does not ask again, but tomorrow morning does.
//        Nothing is shown when calendar access is missing or the day holds no decidable meetings —
//        an empty prompt is worse than no prompt.

import AppKit
import SwiftUI

@MainActor
final class DailyBriefingPanel {

    private static let lastShownKey = "mm.dailyBriefingLastShown"

    private var panel: NSPanel?
    private weak var viewModel: AppViewModel?

    func configure(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Entry points

    /// Shows the briefing if it has not been shown today and there is something to decide.
    func showIfDue() {
        guard !hasShownToday else { return }
        guard let viewModel, !viewModel.todaysDecidableEvents().isEmpty else { return }

        markShownToday()
        show()
    }

    /// Shows the briefing regardless of the once-a-day rule — for a menu command.
    func showNow() {
        markShownToday()
        show()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Once a day

    private var hasShownToday: Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastShownKey) as? Date
        else { return false }
        return Calendar.current.isDateInToday(last)
    }

    private func markShownToday() {
        UserDefaults.standard.set(Date(), forKey: Self.lastShownKey)
    }

    // MARK: - Panel

    private func show() {
        guard let viewModel else { return }
        hide()

        let content = DailyBriefingView(onClose: { [weak self] in self?.hide() })
            .environment(viewModel)

        let panel = InteractivePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: content)
        // Let the list decide the height instead of forcing every day into the same box.
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        self.panel = panel
        reposition()
        panel.orderFrontRegardless()
    }

    /// Bottom-right, inset from the screen's visible frame so it clears the Dock and the menu bar.
    private func reposition() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: visible.maxX - size.width - 20, y: visible.minY + 20))
    }

    /// Unlike the dictation HUD, this panel takes clicks — it exists to be answered.
    private final class InteractivePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}
