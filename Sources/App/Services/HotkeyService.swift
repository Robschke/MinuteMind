// Purpose: Registers global + local keyboard event monitors for app-wide hotkeys.
// Dependencies: AppKit (NSEvent)
// Used by: Sources/App/MinuteMindApp.swift (AppDelegate)
// Notes: Global monitor requires Accessibility permission to work when app is in background.
//        Local monitor handles events when app is in foreground. Both are needed for full coverage,
//        for keyDown hotkeys and for the flagsChanged hold keys (fn, right Option) alike.
//        A hold key also reports Control, pressed with it or while it is held, so hold key +
//        Control can mean something other than the hold key alone.

import AppKit

@MainActor
final class HotkeyService {
    struct Hotkey {
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let handler: () -> Void
    }

    /// A modifier-only key usable for hold-to-talk. These never produce `keyDown` events, so they
    /// are watched through `flagsChanged` instead.
    enum HoldKey: UInt16, CaseIterable {
        /// The fn / globe key.
        case fn = 63
        case rightOption = 61

        /// The modifier flag that is set while this key is held.
        var flag: NSEvent.ModifierFlags {
            switch self {
            case .fn: return .function
            case .rightOption: return .option
            }
        }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var hotkeys: [Hotkey] = []

    private var holdHandlers: [HoldKey: HoldHandlers] = [:]
    private var heldKeys: Set<HoldKey> = []

    private struct HoldHandlers {
        let down: (_ withControl: Bool) -> Void
        let up: () -> Void
        let control: () -> Void
    }

    /// Left and right Control.
    private static let controlKeyCodes: Set<UInt16> = [59, 62]

    func register(key: String, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        hotkeys.append(Hotkey(key: key, modifiers: modifiers, handler: handler))
    }

    /// Registers hold-to-talk on a modifier-only key. `onDown` learns whether Control was already
    /// held; `onControl` fires when Control goes down while the key is held.
    func registerHold(
        _ key: HoldKey,
        onDown: @escaping (_ withControl: Bool) -> Void,
        onUp: @escaping () -> Void,
        onControl: @escaping () -> Void
    ) {
        holdHandlers[key] = HoldHandlers(down: onDown, up: onUp, control: onControl)
    }

    func install() {
        let relevantModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event, relevantModifiers: relevantModifiers)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var handled = false
            // Local monitor is synchronous on main thread, safe to access directly
            if let self {
                handled = self.handleEvent(event, relevantModifiers: relevantModifiers)
            }
            return handled ? nil : event
        }

        // Modifier-only shortcuts arrive as flagsChanged, never keyDown. The global monitor never
        // sees events aimed at MinuteMind itself, so hold keys need a local monitor as well.
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Passed on unchanged: other views still need to see modifier changes.
            self?.handleFlagsChanged(event)
            return event
        }
    }

    func uninstall() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        globalMonitor = nil
        localMonitor = nil
        flagsMonitor = nil
        localFlagsMonitor = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        if Self.controlKeyCodes.contains(event.keyCode) {
            guard event.modifierFlags.contains(.control) else { return }
            for key in heldKeys { holdHandlers[key]?.control() }
            return
        }
        guard let key = HoldKey(rawValue: event.keyCode), let handlers = holdHandlers[key] else {
            return
        }

        // flagsChanged fires for both press and release; the modifier flag tells which it was.
        // Filtering on the key code first matters: `.function` is also set by arrow and F-keys.
        let isDown = event.modifierFlags.contains(key.flag)
        guard isDown != heldKeys.contains(key) else { return }

        if isDown {
            heldKeys.insert(key)
            handlers.down(event.modifierFlags.contains(.control))
        } else {
            heldKeys.remove(key)
            handlers.up()
        }
    }

    @discardableResult
    private func handleEvent(_ event: NSEvent, relevantModifiers: NSEvent.ModifierFlags) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let eventMods = event.modifierFlags.intersection(relevantModifiers)

        for hotkey in hotkeys {
            let requiredMods = hotkey.modifiers.intersection(relevantModifiers)
            if chars == hotkey.key && eventMods == requiredMods {
                hotkey.handler()
                return true
            }
        }
        return false
    }
}
