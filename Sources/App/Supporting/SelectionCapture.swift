// Purpose: SelectionCapture, reads what the user has selected in the frontmost app (and which app
//          and window that is) when they call the voice assistant, and tells whether the cursor
//          sits in a text field, so an answer can be inserted there or shown in a card instead.
// Dependencies: ApplicationServices (Accessibility), AppKit (pasteboard, frontmost app)
// Used by: Sources/App/Supporting/QuickDictationController.swift (assistant requests)
// Notes: User request 2026-10-13: selected text goes to Claude as context. Decisions:
//        - Accessibility first (the focused element's selected text): no side effects. The app
//          already has the permission, it pastes dictations the same way.
//        - Fallback for apps that do not expose it (some browsers, Electron): a simulated Cmd+C,
//          read the pasteboard if it changed within 0.3 s, then put every item and type of the
//          previous pasteboard back, so the user's clipboard is untouched.
//        - "Editable" means the focused element's value can be set or it has a text role.

import AppKit
import ApplicationServices

@MainActor
enum SelectionCapture {
    /// The selection, app and window title of the frontmost app.
    static func capture() async -> ClaudeAssistantContext {
        let app = NSWorkspace.shared.frontmostApplication
        var context = ClaudeAssistantContext(appName: app?.localizedName)
        if let pid = app?.processIdentifier {
            let appElement = AXUIElementCreateApplication(pid)
            if let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute) {
                context.windowTitle = attribute(window, kAXTitleAttribute)
            }
        }
        if let element = focusedElement() {
            // nil: the element does not offer the attribute; "": nothing selected.
            if let selected: String = attribute(element, kAXSelectedTextAttribute) {
                context.selection = selected.isEmpty ? nil : selected
                return context
            }
        }
        context.selection = await copiedSelection()
        return context
    }

    /// Whether the cursor sits in an editable text element of the frontmost app.
    static func focusedTextIsEditable() -> Bool {
        guard let element = focusedElement() else { return false }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        let role: String? = attribute(element, kAXRoleAttribute)
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].map { $0 as String }.contains(role ?? "")
    }

    // MARK: - Accessibility

    private static func focusedElement() -> AXUIElement? {
        attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! T)
        }
        return value as? T
    }

    // MARK: - Cmd+C fallback

    /// Copies the selection with a simulated Cmd+C and restores the previous pasteboard.
    private static func copiedSelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        postCommandC()
        var waited = 0
        while pasteboard.changeCount == before, waited < 300 {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        restore(saved, to: pasteboard)
        return text?.isEmpty == false ? text : nil
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ items: [[(NSPasteboard.PasteboardType, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 8
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
