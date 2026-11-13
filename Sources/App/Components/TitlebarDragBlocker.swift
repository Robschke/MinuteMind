// Purpose: TitlebarDragBlocker, keeps drags that start on a view inside the title bar band from
//          moving the window, so tabs, terminal text and dividers up there still take their drags.
// Dependencies: AppKit (NSControl), SwiftUI
// Used by: Sources/App/Views/WorkspaceTerminalPane.swift (tabs, terminal panes),
//          Sources/App/Views/WorkspaceEditorPane.swift (file content),
//          Sources/App/Components/SplitResizeHandle.swift (grab area)
// Notes: The main window's pages reach up under the title bar (ContentView). In that band macOS
//        moves the window on any drag that starts over plain views: SwiftUI content of every
//        kind (buttons, gestures, scroll views) and AppKit views that are not controls. The
//        window server decides this before the app sees the drag, so mouseDownCanMoveWindow
//        does not help. Controls (NSControl and its subclasses, text views) keep their drags,
//        so the blocker is an empty, invisible NSControl laid behind the view: hitTest returns
//        nil, every click still reaches the view in front. Below the band it has no effect.
//        Buttons and headers in the band stay draggable on purpose: a click still works, and
//        they give the window its handle.

import AppKit
import SwiftUI

extension View {
    /// Drags that start on this view never move the window, also inside the title bar band.
    func excludedFromWindowDrag() -> some View {
        background(TitlebarDragBlocker())
    }
}

private struct TitlebarDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> BlockerControl { BlockerControl() }
    func updateNSView(_ view: BlockerControl, context: Context) {}

    final class BlockerControl: NSControl {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            refusesFirstResponder = true
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
