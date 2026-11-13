// Purpose: MainWindowEventMonitor, the main window's own input outside any view: the mouse's back
//          and forward buttons step through the navigation history, and Option+Tab drives the
//          project switcher (hold Option, Tab steps, releasing Option enters, Esc cancels, the
//          arrow keys step back and forth, Return enters), and Cmd+K opens and closes the global search.
// Dependencies: Sources/App/ViewModels/AppViewModel+Navigation.swift (goBack, goForward,
//               switcherProjectIDs, enterProject), Sources/App/ViewModels/AppViewModel+Companion.swift
//               (mainWindow), Sources/App/Views/ProjectSwitcherView.swift (ProjectSwitcherModel),
//               Sources/App/Views/GlobalSearchView.swift (GlobalSearchModel)
// Used by: Sources/App/Views/ContentView.swift
// Notes: An AppKit local monitor rather than SwiftUI shortcuts: the switcher needs the release of
//        Option (flagsChanged), and the mouse buttons, Option+Tab and Cmd+K must work while a
//        terminal or the editor has focus, which take keys and clicks before SwiftUI sees them.
//        Option+Tab, not Shift+Tab: Claude Code cycles its modes (plan, auto, ...) with Shift+Tab,
//        so that key must reach the terminal. With no project to list Option+Tab is left alone.
//        Only the main window reacts, and not while it shows a sheet; Claude's own windows keep
//        every event.
//        The back and forward buttons are buttons 4 and 5 (AppKit numbers 3 and 4); other
//        shortcuts for back (Cmd+[, swipes) are left out on purpose. Leaving the app while the
//        switcher is open cancels it, since the release of Option would never arrive.

import AppKit

@MainActor
final class MainWindowEventMonitor {
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    private static let keyTab: UInt16 = 48
    private static let keyK: UInt16 = 40
    private static let keyEscape: UInt16 = 53
    private static let keyReturn: UInt16 = 36
    private static let keyLeft: UInt16 = 123
    private static let keyRight: UInt16 = 124

    /// The input one event carries, read off the event before handing it to the main actor.
    private struct Input: Sendable {
        let type: NSEvent.EventType
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags
        let button: Int
        let windowNumber: Int
    }

    func start(viewModel: AppViewModel, switcher: ProjectSwitcherModel, search: GlobalSearchModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .keyDown, .flagsChanged]) {
            [weak viewModel, weak switcher, weak search] event in
            let input = Input(
                type: event.type,
                keyCode: event.type == .flagsChanged || event.type == .keyDown ? event.keyCode : 0,
                flags: event.modifierFlags,
                button: event.type == .otherMouseDown ? event.buttonNumber : -1,
                windowNumber: event.windowNumber)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let viewModel, let switcher, let search else { return false }
                return Self.handle(input, viewModel: viewModel, switcher: switcher, search: search)
            }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak switcher] _ in
            MainActor.assumeIsolated { switcher?.cancel() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// True when the event was used and must not reach the window.
    private static func handle(
        _ input: Input, viewModel: AppViewModel, switcher: ProjectSwitcherModel, search: GlobalSearchModel
    ) -> Bool {
        // The switcher, once open, takes every key until it closes.
        if switcher.isShown {
            switch input.type {
            case .flagsChanged:
                if !input.flags.contains(.option) { enter(switcher.finish(), viewModel: viewModel) }
                return false
            case .keyDown:
                switch input.keyCode {
                case keyTab: switcher.step(by: 1)
                case keyRight: switcher.step(by: 1)
                case keyLeft: switcher.step(by: -1)
                case keyReturn: enter(switcher.finish(), viewModel: viewModel)
                case keyEscape: switcher.cancel()
                default: break
                }
                return true
            default:
                return true
            }
        }

        guard let window = viewModel.mainWindow, window.windowNumber == input.windowNumber,
              window.attachedSheet == nil
        else { return false }

        switch input.type {
        case .otherMouseDown:
            switch input.button {
            case 3: viewModel.goBack(); return true
            case 4: viewModel.goForward(); return true
            default: return false
            }
        case .keyDown:
            let modifiers = input.flags.intersection([.shift, .command, .control, .option])
            if input.keyCode == keyK, modifiers == .command, window.isKeyWindow {
                search.toggle(viewModel: viewModel)
                return true
            }
            guard input.keyCode == keyTab, modifiers == .option, window.isKeyWindow
            else { return false }
            let items = viewModel.switcherProjectIDs
            guard !items.isEmpty else { return false }
            switcher.show(items: items, current: viewModel.currentPlace.projectID)
            return true
        default:
            return false
        }
    }

    private static func enter(_ id: UUID?, viewModel: AppViewModel) {
        guard let id, viewModel.currentPlace.projectID != id else { return }
        viewModel.enterProject(id)
    }
}
