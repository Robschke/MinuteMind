// Purpose: FullScreenToolbarAutoHide, lets the window toolbar slide away in full screen (as in
//          Safari and Xcode) so the page and the terminals reach the top of the screen; moving
//          the pointer to the top edge brings toolbar and menu bar back.
// Dependencies: AppKit (NSWindowDelegate.window(_:willUseFullScreenPresentationOptions:)),
//               ObjectiveC runtime
// Used by: Sources/App/MinuteMindApp.swift (AppDelegate starts it)
// Notes: By default macOS keeps a window's toolbar band on screen in full screen, an empty bar
//        above the page here. The only switch macOS honours is the window delegate's
//        willUseFullScreenPresentationOptions: adding .autoHideToolbar to
//        NSApp.presentationOptions while in full screen is silently ignored (measured on
//        macOS 26: the options stay unchanged and the band stays). SwiftUI owns the delegates
//        of its windows and implements that method itself, so its implementation is wrapped
//        once per delegate class: SwiftUI's answer is kept and .autoHideToolbar added.
//        The method is asked before the window enters full screen, so the wrap is installed as
//        soon as any window becomes key or main (and for the windows open at start).
//        autoHideToolbar is only valid together with fullScreen and autoHideMenuBar; returning
//        it without them raises, hence the guard.

import AppKit
import ObjectiveC

@MainActor
final class FullScreenToolbarAutoHide {
    private var observers: [NSObjectProtocol] = []
    private static var wrappedClasses: Set<ObjectIdentifier> = []

    func start() {
        guard observers.isEmpty else { return }
        NSApp.windows.forEach(Self.install)
        let center = NotificationCenter.default
        let names = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willEnterFullScreenNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { window.map(Self.install) }
            })
        }
    }

    private static func install(on window: NSWindow) {
        guard let delegate = window.delegate else { return }
        let cls: AnyClass = type(of: delegate)
        let key = ObjectIdentifier(cls)
        guard !wrappedClasses.contains(key) else { return }
        wrappedClasses.insert(key)

        let selector = #selector(NSWindowDelegate.window(_:willUseFullScreenPresentationOptions:))
        typealias Original = @convention(c) (AnyObject, Selector, NSWindow, UInt) -> UInt
        let original: Original?
        let types: UnsafePointer<CChar>?
        if let method = class_getInstanceMethod(cls, selector) {
            original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            types = method_getTypeEncoding(method)
        } else {
            original = nil
            types = nil
        }
        let wrapped: @convention(block) (AnyObject, NSWindow, UInt) -> UInt = { owner, window, proposed in
            let options = original.map { $0(owner, selector, window, proposed) } ?? proposed
            return withAutoHideToolbar(options)
        }
        let implementation = imp_implementationWithBlock(wrapped)
        if let types {
            class_replaceMethod(cls, selector, implementation, types)
        } else {
            class_replaceMethod(cls, selector, implementation, "Q@:@Q")
        }
    }

    private static func withAutoHideToolbar(_ raw: UInt) -> UInt {
        let options = NSApplication.PresentationOptions(rawValue: raw)
        guard options.contains(.fullScreen), options.contains(.autoHideMenuBar) else { return raw }
        return options.union(.autoHideToolbar).rawValue
    }
}
