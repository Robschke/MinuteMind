// Purpose: The macOS permissions the onboarding asks for, one page each: what each one is for,
//          how to read its current state and how to ask for it.
// Dependencies: AVFoundation (microphone), CoreGraphics (screen and system audio recording),
//               ApplicationServices (accessibility), Sources/App/Services/CalendarService.swift
//               (calendar access through the app's own event store), UserNotifications, Speech.
// Used by: Sources/App/Supporting/OnboardingFlow.swift (step list),
//          Sources/App/Views/OnboardingPermissionPage.swift (page content and buttons)
// Notes: Screen recording cannot tell "denied" from "not asked yet" and only takes effect after a
//        relaunch, so once it was requested it counts as pending until the restart at the end of
//        the onboarding. Accessibility has no system prompt of its own beyond the one that points
//        to System Settings; its state changes live, so the page polls it.
//        Calendar goes through CalendarService so the app's event store sees the grant at once.

import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import EventKit
import Speech
import UserNotifications

enum OnboardingPermission: String, CaseIterable, Identifiable, Sendable {
    case microphone, screenRecording, accessibility, calendar, notifications, speechRecognition

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen & System Audio Recording"
        case .accessibility: "Accessibility"
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        case .speechRecognition: "Speech Recognition"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .screenRecording: "speaker.wave.2.fill"
        case .accessibility: "keyboard.fill"
        case .calendar: "calendar"
        case .notifications: "bell.badge.fill"
        case .speechRecognition: "waveform"
        }
    }

    var headline: String {
        switch self {
        case .microphone: "Hear your side of the conversation"
        case .screenRecording: "Hear the other side too"
        case .accessibility: "Shortcuts that work in every app"
        case .calendar: "Know which meeting is next"
        case .notifications: "Tell you when something is ready"
        case .speechRecognition: "Live text while you speak"
        }
    }

    var points: [String] {
        switch self {
        case .microphone:
            ["Records your microphone during meetings and while you dictate.",
             "Audio stays on this Mac; transcription runs on-device."]
        case .screenRecording:
            ["Captures the call's audio (Teams, Zoom, Meet, ...) so every participant ends up in the transcript.",
             "MinuteMind records sound only, never your screen's picture.",
             "macOS applies this permission after a restart; the last step of the setup does that."]
        case .accessibility:
            ["Lets the dictation key, the Claude key and the recording shortcuts work while another app is in front.",
             "Puts dictated text at your cursor and hands the selected text to Claude."]
        case .calendar:
            ["Offers to record your calendar's meetings and names recordings after them.",
             "Recurring meetings can be filed into a project automatically."]
        case .notifications:
            ["Says when a summary is ready, when Claude finishes or needs you, and when a scheduled job ran."]
        case .speechRecognition:
            ["Shows the live transcript while you dictate. Meeting transcripts use the Parakeet model instead."]
        }
    }

    /// Opens this permission's pane in System Settings.
    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .calendar: anchor = "Privacy_Calendars"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

enum OnboardingPermissionState: Equatable, Sendable {
    case granted
    /// Asked once and refused: only System Settings can change it now.
    case denied
    case notDetermined
    /// Requested, waiting for the restart (screen recording) or for the switch in System Settings.
    case pendingRestart
}

@MainActor
enum OnboardingPermissionCheck {
    private static let screenRecordingRequestedKey = "mm.onboardingScreenRecordingRequested"

    static func state(of permission: OnboardingPermission) async -> OnboardingPermissionState {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notDetermined
            }
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return UserDefaults.standard.bool(forKey: screenRecordingRequestedKey) ? .pendingRestart : .notDetermined
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .denied, .restricted, .writeOnly: return .denied
            default: return .notDetermined
            }
        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else { return .notDetermined }
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            default: return .notDetermined
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notDetermined
            }
        }
    }

    /// Shows the system prompt where macOS has one; otherwise (or once refused) opens System
    /// Settings at the right pane. Returns the state right after.
    static func request(_ permission: OnboardingPermission, calendarService: CalendarService) async
        -> OnboardingPermissionState
    {
        let before = await state(of: permission)
        if before == .denied {
            openSettings(for: permission)
            return before
        }
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screenRecording:
            UserDefaults.standard.set(true, forKey: screenRecordingRequestedKey)
            // The first call shows the system prompt and lists the app in System Settings; later
            // calls do nothing, so the pane is opened for the user to flip the switch.
            if !CGRequestScreenCaptureAccess(), before == .pendingRestart {
                openSettings(for: permission)
            }
        case .accessibility:
            if !TextInsertionService.requestPermission() {
                openSettings(for: permission)
            }
        case .calendar:
            _ = await calendarService.requestAccess()
        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else { break }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        case .speechRecognition:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        return await state(of: permission)
    }

    static func openSettings(for permission: OnboardingPermission) {
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
    }
}
