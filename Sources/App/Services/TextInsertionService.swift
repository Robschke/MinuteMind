// Purpose: Inserts text at the cursor of whatever app is frontmost — the "it just appears where I'm
//          typing" half of quick dictation.
// Dependencies: AppKit (NSPasteboard), CoreGraphics (CGEvent key synthesis),
//               ApplicationServices (AXIsProcessTrusted).
// Used by: Sources/App/Supporting/QuickDictationController.swift,
//          Sources/App/Supporting/MeetingPillController.swift (Insert in the companion's Clipboard list)
// Notes: Works by putting the text on the pasteboard and synthesizing ⌘V, which is the only
//        approach that works reliably across arbitrary apps (the Accessibility API's value-setting
//        is unsupported by many editors). Consequences handled here:
//        - Requires Accessibility permission; `isTrusted` reports it and `requestPermission()`
//          opens the system prompt.
//        - The user's clipboard is saved and restored afterwards, so dictating does not silently
//          eat what they had copied.
//        - Key events are posted to the HID tap so they reach the frontmost app, not ours.

import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
enum TextInsertionService {

    enum InsertionError: Error, LocalizedError {
        case notTrusted
        case emptyText

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return
                    "MinuteMind needs Accessibility permission to type into other apps. Enable it in System Settings → Privacy & Security → Accessibility."
            case .emptyText:
                return "Nothing was dictated."
            }
        }
    }

    /// Virtual key code for "v".
    private static let keyCodeV: CGKeyCode = 9

    /// True when the app may synthesize keystrokes into other apps.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Opens the system Accessibility prompt. Returns the trust state at call time.
    @discardableResult
    static func requestPermission() -> Bool {
        // The literal key rather than `kAXTrustedCheckOptionPrompt`: that symbol is a global `var`,
        // which Swift 6 rejects as shared mutable state. The string value is part of the API.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Pastes `text` into the frontmost app at the current cursor position. Dictation trims the
    /// text; the clipboard list passes `trimming: false` to give back exactly what was copied.
    static func insertAtCursor(_ text: String, trimming: Bool = true) async throws {
        let trimmed = trimming ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InsertionError.emptyText }
        try await paste { $0.setString(trimmed, forType: .string) }
    }

    /// Pastes image bytes (PNG or TIFF) into the frontmost app, for the companion's Clipboard list.
    static func insertImageAtCursor(_ data: Data, type: NSPasteboard.PasteboardType) async throws {
        try await paste { $0.setData(data, forType: type) }
    }

    /// Puts what `write` adds on the pasteboard, sends ⌘V, then restores the user's clipboard.
    private static func paste(_ write: (NSPasteboard) -> Void) async throws {
        guard isTrusted else { throw InsertionError.notTrusted }

        let pasteboard = NSPasteboard.general
        let saved = savedContents(of: pasteboard)

        pasteboard.clearContents()
        write(pasteboard)
        // Marked transient, so clipboard histories (ClipboardHistory, other apps) skip this buffer.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        // Give the frontmost app a moment to see the new pasteboard before ⌘V arrives.
        try? await Task.sleep(for: .milliseconds(50))
        synthesizeCommandV()

        // Restore only after the paste has been consumed, otherwise we race the target app.
        try? await Task.sleep(for: .milliseconds(250))
        restore(saved, to: pasteboard)
    }

    // MARK: - Key synthesis

    private static func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else {
            NSLog("TextInsertionService: could not create key events")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard preservation

    /// A snapshot of the pasteboard's current items, so dictation can put it back.
    private struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func savedContents(of pasteboard: NSPasteboard) -> Snapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let value = item.data(forType: type) { data[type] = value }
            }
            return data
        }
        return Snapshot(items: items)
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let items: [NSPasteboardItem] = snapshot.items.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
