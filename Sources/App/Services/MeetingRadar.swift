// Purpose: MeetingRadar, detects that a call is running in any known meeting app (Teams, Zoom,
//          Meet in a browser, Webex, Slack huddles, FaceTime, Discord), notices when it ends, and
//          detects when the user is sharing their screen. It only reports; the pill decides.
// Dependencies: CoreAudio (per-process input state, macOS 14.4+), AppKit (NSWorkspace for
//               app names/icons), CoreGraphics (window titles for call titles and share detection).
// Used by: Sources/App/Supporting/MeetingPillController.swift (drives the pill states),
//          Sources/App/ViewModels/AppViewModel.swift (owner, lifecycle)
// Notes: The signal is "a call app holds the microphone", read from the HAL process list
//        (kAudioProcessPropertyIsRunningInput). It needs no microphone permission and does not
//        light the orange indicator. Teams and Zoom keep the mic open while muted, so a muted
//        participant still counts as in a call. A call counts as started after the app held the
//        mic for `startDelay` seconds (filters short voice notes), and as ended once the app
//        released it for `endDelay` seconds or quit: that is the "confident" end. MinuteMind's own
//        process and Apple's speech service are ignored.
//        Browsers are call apps too, because Meet, Teams web and Zoom web run there. Their helper
//        processes are matched by bundle-ID prefix.
//        Screen sharing is detected from window titles (Zoom, Teams, browser sharing bars in
//        English and German). Reading other apps' window titles needs Screen Recording
//        permission, which MinuteMind already holds for system audio.
//        Before macOS 14.4 the per-process API does not exist and the radar stays silent.

import AppKit
import CoreAudio
import CoreGraphics
import Foundation

@MainActor
final class MeetingRadar {
    struct CallInfo: Equatable {
        let bundleID: String
        let appName: String
        let pid: pid_t
        /// Best-effort meeting title from the call window, nil when none is readable.
        var windowTitle: String?

        var icon: NSImage? {
            NSRunningApplication(processIdentifier: pid)?.icon
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }

    var onCallStarted: ((CallInfo) -> Void)?
    var onCallEnded: ((CallInfo) -> Void)?
    var onScreenSharingChanged: ((Bool) -> Void)?

    private(set) var activeCall: CallInfo?
    private(set) var isScreenSharing = false

    var startDelay: TimeInterval = 5
    var endDelay: TimeInterval = 8

    /// Known call apps. Browsers are included for web calls (Meet, Teams web, Zoom web).
    private static let callApps: [(prefix: String, name: String)] = [
        ("com.microsoft.teams", "Microsoft Teams"),
        ("us.zoom.xos", "Zoom"),
        ("com.apple.FaceTime", "FaceTime"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.webex", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.google.Chrome", "Google Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),
        ("company.thebrowser", "Arc"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
    ]

    /// Window titles that mean "you are sharing your screen right now".
    private static let sharingTitleMarkers = [
        "zoom share", "sharing toolbar", "sharing control bar", "is sharing your screen",
        "is sharing a window", "teilt ihren bildschirm", "teilt ein fenster", "bildschirmfreigabe",
        "you are screen sharing", "you're sharing", "sie geben ihren bildschirm frei",
        "screen sharing meeting controls", "webex share",
    ]

    private var timer: Timer?
    private var candidate: (info: CallInfo, since: Date)?
    private var releasedSince: Date?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        candidate = nil
        releasedSince = nil
        if let call = activeCall {
            activeCall = nil
            onCallEnded?(call)
        }
        setSharing(false)
    }

    // MARK: - Polling

    private func tick() {
        let callers = Self.processesUsingMicrophone().filter { $0.pid != ownPID }
        let callApps = callers.compactMap(Self.callInfo(for:))
        let now = Date()

        if let call = activeCall {
            let stillThere = callApps.contains { $0.bundleID == call.bundleID }
                && NSRunningApplication(processIdentifier: call.pid) != nil
            if stillThere {
                releasedSince = nil
            } else {
                releasedSince = releasedSince ?? now
                let appQuit = NSWorkspace.shared.runningApplications.allSatisfy { !$0.bundleIdentifier.map { $0.hasPrefix(Self.appPrefix(call.bundleID)) }.orFalse }
                if appQuit || now.timeIntervalSince(releasedSince!) >= endDelay {
                    activeCall = nil
                    releasedSince = nil
                    onCallEnded?(call)
                }
            }
        } else if let app = callApps.first {
            if let current = candidate, current.info.bundleID == app.bundleID {
                if now.timeIntervalSince(current.since) >= startDelay {
                    var info = app
                    info.windowTitle = Self.meetingTitle(pid: app.pid, bundleID: app.bundleID)
                    activeCall = info
                    candidate = nil
                    onCallStarted?(info)
                }
            } else {
                candidate = (app, now)
            }
        } else {
            candidate = nil
        }

        // Share detection only matters while something is going on.
        if activeCall != nil || candidate != nil || isScreenSharing {
            setSharing(Self.detectScreenSharing())
        }
    }

    private func setSharing(_ sharing: Bool) {
        guard sharing != isScreenSharing else { return }
        isScreenSharing = sharing
        onScreenSharingChanged?(sharing)
    }

    // MARK: - CoreAudio

    private struct AudioProcess {
        let pid: pid_t
        let bundleID: String
    }

    /// Processes that currently capture audio input, from the HAL process list (macOS 14.4+).
    private static func processesUsingMicrophone() -> [AudioProcess] {
        guard #available(macOS 14.4, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.compactMap { object in
            guard readUInt32(object, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.stride)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { return nil }

            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let bundleID: String
            if AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr,
               let value = bundle?.takeRetainedValue() as String? {
                bundleID = value
            } else {
                bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            }
            return AudioProcess(pid: pid, bundleID: bundleID)
        }
    }

    private static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    // MARK: - App matching

    private static func callInfo(for process: AudioProcess) -> CallInfo? {
        guard let app = callApps.first(where: { process.bundleID.hasPrefix($0.prefix) }) else { return nil }
        // Helper processes (e.g. "com.google.Chrome.helper") report the main app for its icon/name.
        let mainApp = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier.map { $0.hasPrefix(app.prefix) && !$0.contains(".helper") }.orFalse
        }
        return CallInfo(
            bundleID: mainApp?.bundleIdentifier ?? process.bundleID,
            appName: app.name,
            pid: mainApp?.processIdentifier ?? process.pid,
            windowTitle: nil)
    }

    private static func appPrefix(_ bundleID: String) -> String {
        callApps.first { bundleID.hasPrefix($0.prefix) }?.prefix ?? bundleID
    }

    // MARK: - Window titles

    private static func windowTitles(pid: pid_t? = nil) -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { window in
            if let pid, (window[kCGWindowOwnerPID as String] as? pid_t) != pid { return nil }
            return window[kCGWindowName as String] as? String
        }
    }

    /// A readable meeting name from the call app's windows, e.g. "Weekly Sync | Microsoft Teams".
    private static func meetingTitle(pid: pid_t, bundleID: String) -> String? {
        let appNames = ["microsoft teams", "teams", "zoom", "zoom meeting", "google meet", "meet", "webex", "slack", "facetime"]
        for title in windowTitles(pid: pid) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for separator in [" | ", " - ", " \u{2013} "] {
                let first = trimmed.components(separatedBy: separator)[0].trimmingCharacters(in: .whitespaces)
                if first != trimmed, !first.isEmpty, !appNames.contains(first.lowercased()) {
                    // Meet tabs are titled "Meet - abc-defg-hij": the code is not a useful name.
                    if first.lowercased() == "meet" { continue }
                    return first
                }
            }
        }
        return nil
    }

    private static func detectScreenSharing() -> Bool {
        windowTitles().contains { title in
            let lower = title.lowercased()
            return sharingTitleMarkers.contains { lower.contains($0) }
        }
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
