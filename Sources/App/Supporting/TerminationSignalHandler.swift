// Purpose: TerminationSignalHandler, turns SIGTERM into a normal Quit, so MinuteMind saves its
//          pending changes (applicationWillTerminate) instead of ending on the spot.
// Dependencies: Sources/App/MinuteMindApp.swift (AppDelegate installs it at launch)
// Used by: install.sh, which sends SIGTERM to the MinuteMind that started an in-app update
// Notes: SIGTERM's default action is ignored first, otherwise the process would still end before
//        the dispatch source sees the signal.

import AppKit

@MainActor
enum TerminationSignalHandler {
    private static var source: DispatchSourceSignal?

    static func install() {
        guard source == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        self.source = source
    }
}
