// Purpose: LaunchAtLogin, opens MinuteMind when the user logs in, through macOS's own login item
//          registration (SMAppService.mainApp), so the Settings switch and System Settings,
//          General, Login Items always agree.
// Dependencies: ServiceManagement (SMAppService).
// RBAC: None.
// Dependents: Sources/App/Views/AutomationSettingsView.swift (Startup switch),
//             Sources/App/ViewModels/AppViewModel.swift (turned on once at first launch)
// Notes: The state is read from macOS every time instead of being stored, because the user can
//        switch it off in System Settings too. It is on by default: the first launch of a build
//        with this switch registers the app once (`mm.launchAtLoginInitialized`), and after that
//        only the user changes it. Jobs and meeting detection only run while the app is open,
//        which is why it defaults to on.

import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    private static let initializedKey = "mm.launchAtLoginInitialized"

    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    /// What went wrong the last time the switch was used, if anything.
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    /// macOS registered the app but waits for the user to allow it in System Settings.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Turns it on once, the first time a build with the switch runs.
    func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.initializedKey) else { return }
        defaults.set(true, forKey: Self.initializedKey)
        refresh()
        if status == .notRegistered { setEnabled(true) }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
