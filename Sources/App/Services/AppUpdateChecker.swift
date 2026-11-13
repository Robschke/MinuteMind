// Purpose: AppUpdateChecker, looks for a newer MinuteMind release at launch and every 24 hours
//          while the app runs, and decides when the update dialog may appear.
// Dependencies: Sources/App/Services/AppUpdateService.swift (release lookup, version compare,
//               installer), Sources/App/ViewModels/AppViewModel.swift (recording and queue state),
//               Sources/App/Supporting/OnboardingFlow (first-launch setup)
// Used by: Sources/App/Views/ContentView.swift (starts it, presents AppUpdateSheet),
//          Sources/App/Views/AppUpdateSheet.swift, Sources/App/Services/MCP/MCPUpdateTools.swift
//          (updateBlockedReason)
// Notes: The dialog only appears while nothing records, transcribes or processes and the setup
//        is not running, because Update quits MinuteMind. A loop re-evaluates that every minute
//        without asking GitHub again; GitHub is asked at most once per check interval.
//        "Later" hides the dialog for three days for any version, also across restarts.
//        Development builds (no .app bundle) never check.

import Foundation
import Observation

@Observable
@MainActor
final class AppUpdateChecker {
    static let shared = AppUpdateChecker()

    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let snoozeInterval: TimeInterval = 3 * 24 * 60 * 60
    static let snoozeKey = "mm.updateSnoozedUntil"

    /// The release the dialog shows; nil while there is none or it may not appear yet.
    private(set) var offeredRelease: AppUpdateService.Release?
    private(set) var isUpdating = false
    private(set) var updateError: String?

    @ObservationIgnored private var latestRelease: AppUpdateService.Release?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isBlocked: @MainActor () -> Bool = { true }

    /// Starts the checks once; later calls only replace the busy test.
    func start(isBlocked: @escaping @MainActor () -> Bool) {
        self.isBlocked = isBlocked
        guard loop == nil, AppUpdateService.installFolder != nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Hides the dialog for three days.
    func later() {
        UserDefaults.standard.set(Date().addingTimeInterval(Self.snoozeInterval), forKey: Self.snoozeKey)
        offeredRelease = nil
        updateError = nil
    }

    /// Starts install.sh; MinuteMind quits and opens again as the new version.
    func update() {
        guard !isUpdating else { return }
        if isBlocked() {
            updateError = "MinuteMind is busy right now. Try again once the recording or processing has finished."
            return
        }
        do {
            let folder = try AppUpdateService.writableInstallFolder()
            try AppUpdateService.startInstaller(into: folder, logFile: AppUpdateService.logFile)
            isUpdating = true
            updateError = nil
        } catch {
            updateError = error.localizedDescription
        }
    }

    /// Whether the dialog may show `release` now. Pure, so the rules are testable.
    nonisolated static func shouldOffer(
        _ release: AppUpdateService.Release?, installed: String, snoozedUntil: Date?, now: Date, blocked: Bool
    ) -> Bool {
        guard let release, AppUpdateService.isNewer(release.version, than: installed) else { return false }
        if let snoozedUntil, snoozedUntil > now { return false }
        return !blocked
    }

    private func run() async {
        var nextCheck = Date.distantPast
        while !Task.isCancelled {
            if Date() >= nextCheck {
                nextCheck = Date().addingTimeInterval(Self.checkInterval)
                // A failed lookup (offline, GitHub down) waits for the next interval, silently.
                if let release = try? await AppUpdateService.latestRelease() { latestRelease = release }
            }
            evaluate()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func evaluate() {
        guard offeredRelease == nil, !isUpdating else { return }
        let snoozedUntil = UserDefaults.standard.object(forKey: Self.snoozeKey) as? Date
        if Self.shouldOffer(
            latestRelease, installed: AppUpdateService.installedVersion,
            snoozedUntil: snoozedUntil, now: Date(), blocked: isBlocked()
        ) {
            offeredRelease = latestRelease
        }
    }
}

extension AppViewModel {
    /// Why MinuteMind must not quit for an update right now, nil when it may.
    var updateBlockedReason: String? {
        if isRecording { return "a recording is running" }
        if transcriptionQueue.currentJob != nil || transcriptionQueue.pendingCount > 0 {
            return "a transcription is running"
        }
        if !processingStage.isEmpty { return "a meeting is being processed" }
        return nil
    }
}
