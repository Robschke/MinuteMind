// Purpose: Detects active Microsoft Teams calls to trigger auto-recording.
// Dependencies: CoreAudio (HAL process monitoring), AppKit (NSWorkspace for Teams PID)
// Notes: Primary signal is CoreAudio kAudioProcessPropertyIsRunningOutput — no
//        accessibility permission needed. A duration gate (callAudioThreshold)
//        distinguishes sustained calls from brief notification sounds.
//        Window-title extraction (Accessibility API) is kept as an optional
//        secondary step purely to surface a human-readable meeting title.

import AppKit
import CoreAudio
import Foundation

/// Detects Microsoft Teams calls using CoreAudio output-activity duration.
///
/// Strategy:
///   1. Every `pollInterval` seconds, check whether the Teams process has active
///      audio output via the CoreAudio HAL process object list.
///   2. Track how long Teams has been continuously producing output audio.
///   3. After `callAudioThreshold` seconds of sustained output, fire `onCallDetected`.
///   4. Optionally attempt to extract a meeting title via the Accessibility API
///      (requires accessibility permission; gracefully skipped if unavailable).
@MainActor
final class TeamsCallDetector: ObservableObject {
    @Published private(set) var isCallActive = false
    @Published private(set) var hasShownPromptForCurrentCall = false
    @Published private(set) var currentMeetingTitle: String?

    // How long Teams must continuously produce output audio before we treat
    // it as a call rather than a notification sound (default: 3 seconds).
    var callAudioThreshold: TimeInterval = 3.0

    private var timer: Timer?
    private let pollInterval: TimeInterval = 2.0

    // When Teams output audio first became continuously active.
    private var audioActiveStartTime: Date?
    // Last continuous-audio start time used when the call was confirmed,
    // so we don't re-trigger for the same audio run.
    private var callConfirmedAt: Date?
    // When audio output last went silent during an active call. Used for
    // hysteresis — brief gaps (screen share transitions, mute, network)
    // don't immediately end the call.
    private var audioGapStartTime: Date?
    /// How long Teams audio output can be silent during an active call before
    /// we declare the call ended. Default 8 seconds covers screen share
    /// transitions and brief network hiccups.
    var callEndGracePeriod: TimeInterval = 8.0

    // Bundle identifiers for Teams (old and new versions)
    private let teamsBundleIDs: Set<String> = [
        "com.microsoft.teams",
        "com.microsoft.teams2"
    ]

    // Keywords used only for window-title extraction (not for call detection).
    private let callWindowKeywords: Set<String> = [
        "meeting",
        "call with",
        "in call",
        " | meeting",
        "is presenting",
        "screen sharing"
    ]

    var onCallDetected: (() -> Void)?
    var onCallEnded: (() -> Void)?

    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    /// True when Teams is known to be running — drives audio polling.
    private var teamsIsRunning = false

    init() {}

    func startMonitoring() {
        stopMonitoring()

        // Check initial state
        teamsIsRunning = runningTeamsPID() != nil
        if teamsIsRunning {
            startAudioPolling()
        }

        // Observe Teams launch/quit via NSWorkspace — avoids polling when Teams isn't running.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  self?.teamsBundleIDs.contains(bundleID) == true else { return }
            Task { @MainActor in
                self?.teamsIsRunning = true
                self?.startAudioPolling()
            }
        }

        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  self?.teamsBundleIDs.contains(bundleID) == true else { return }
            Task { @MainActor in
                self?.teamsIsRunning = false
                self?.timer?.invalidate()
                self?.timer = nil
                if self?.isCallActive == true {
                    self?.isCallActive = false
                    self?.currentMeetingTitle = nil
                    self?.hasShownPromptForCurrentCall = false
                    self?.callConfirmedAt = nil
                    self?.onCallEnded?()
                }
                self?.audioActiveStartTime = nil
            }
        }

        NSLog("TeamsCallDetector: Started monitoring (Teams %@)", teamsIsRunning ? "running" : "not running")
    }

    /// Start the audio-output polling timer (only when Teams is running).
    private func startAudioPolling() {
        timer?.invalidate()
        checkForTeamsCall()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForTeamsCall() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let obs = launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        launchObserver = nil
        terminateObserver = nil
        teamsIsRunning = false
        audioActiveStartTime = nil
        callConfirmedAt = nil
        audioGapStartTime = nil
    }

    func resetPromptState() {
        hasShownPromptForCurrentCall = false
    }

    // MARK: - Core detection loop

    private func checkForTeamsCall() {
        guard let teamsPID = runningTeamsPID() else {
            // Teams not running — reset all state
            if isCallActive {
                isCallActive = false
                currentMeetingTitle = nil
                hasShownPromptForCurrentCall = false
                callConfirmedAt = nil
                NSLog("TeamsCallDetector: Teams quit, call ended")
                onCallEnded?()
            }
            audioActiveStartTime = nil
            return
        }

        let outputActive = isTeamsOutputActive(pid: teamsPID)

        if outputActive {
            let now = Date()

            // Audio resumed — clear any gap timer.
            if audioGapStartTime != nil {
                NSLog("TeamsCallDetector: Audio resumed after brief gap")
                audioGapStartTime = nil
            }

            if audioActiveStartTime == nil {
                // Teams just started producing audio
                audioActiveStartTime = now
                NSLog("TeamsCallDetector: Teams audio output started")
            }

            let elapsed = now.timeIntervalSince(audioActiveStartTime!)
            let alreadyConfirmedThisRun = callConfirmedAt.map { audioActiveStartTime! <= $0 } ?? false

            if elapsed >= callAudioThreshold && !alreadyConfirmedThisRun {
                // Sustained output — this is a call
                callConfirmedAt = now
                isCallActive = true

                // Best-effort title extraction via Accessibility API
                if currentMeetingTitle == nil {
                    currentMeetingTitle = extractMeetingTitle(pid: teamsPID)
                }

                NSLog("TeamsCallDetector: Call confirmed after %.1fs of audio output (title: %@)",
                      elapsed, currentMeetingTitle ?? "unknown")

                if !hasShownPromptForCurrentCall {
                    hasShownPromptForCurrentCall = true
                    onCallDetected?()
                }
            }
        } else {
            // Audio stopped — reset the "active" tracker.
            if audioActiveStartTime != nil {
                audioActiveStartTime = nil
            }

            if isCallActive {
                // Apply grace period: don't end the call until audio has been
                // silent for callEndGracePeriod seconds continuously.
                let now = Date()
                if audioGapStartTime == nil {
                    audioGapStartTime = now
                    NSLog("TeamsCallDetector: Audio gap started, grace period %.0fs", callEndGracePeriod)
                }

                let gapDuration = now.timeIntervalSince(audioGapStartTime!)
                if gapDuration >= callEndGracePeriod {
                    isCallActive = false
                    currentMeetingTitle = nil
                    hasShownPromptForCurrentCall = false
                    callConfirmedAt = nil
                    audioGapStartTime = nil
                    NSLog("TeamsCallDetector: Call ended (audio silent for %.1fs)", gapDuration)
                    onCallEnded?()
                }
            }
        }
    }

    // MARK: - CoreAudio HAL: per-process output activity

    /// Returns true if the Teams process currently has active audio output.
    /// Uses `kAudioProcessPropertyIsRunningOutput` (macOS 14+) — no special
    /// entitlements required; this is a non-blocking HAL bookkeeping read.
    private func isTeamsOutputActive(pid: pid_t) -> Bool {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &listAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var processObjects = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(systemObject, &listAddress, 0, nil, &dataSize, &processObjects) == noErr
        else { return false }

        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for objectID in processObjects {
            var processPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.stride)
            guard AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr,
                  processPID == pid else { continue }

            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.stride)
            guard AudioObjectGetPropertyData(objectID, &outputAddress, 0, nil, &runningSize, &isRunning) == noErr
            else { return false }

            return isRunning != 0
        }

        return false
    }

    // MARK: - NSWorkspace: find running Teams PID

    private func runningTeamsPID() -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { app in
                guard let id = app.bundleIdentifier else { return false }
                return teamsBundleIDs.contains(id)
            }
            .map(\.processIdentifier)
    }

    // MARK: - Accessibility: optional meeting title extraction

    /// Attempts to read the Teams window title to extract a meeting name.
    /// Returns nil gracefully if accessibility permission is not granted.
    private func extractMeetingTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String else { continue }

            let lower = title.lowercased()
            guard callWindowKeywords.contains(where: { lower.contains($0) }) else { continue }

            return parseMeetingTitle(from: title)
        }

        return nil
    }

    private func parseMeetingTitle(from windowTitle: String) -> String? {
        for separator in [" | ", " - "] {
            let parts = windowTitle.components(separatedBy: separator)
            if parts.count > 1 {
                let candidate = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = candidate.lowercased()
                if !candidate.isEmpty && lower != "microsoft teams" && lower != "teams" {
                    return candidate
                }
            }
        }

        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if !trimmed.isEmpty && lower != "microsoft teams" && lower != "teams" {
            return trimmed
        }

        return nil
    }

    // MARK: - Accessibility permission helpers

    static func checkAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
