// Purpose: CrashReporter, the opt-in crash reports: the setting, and sending MinuteMind's recent
//          crashes (as CrashReport) to the project's crash report endpoint once each.
// Dependencies: Sources/App/Services/CrashReport.swift (what is sent),
//               Sources/App/ViewModels/AppViewModel.swift (isTestProcess)
// Used by: Sources/App/ViewModels/AppViewModel.swift (sends at launch),
//          Sources/App/Views/HelpSettingsView.swift (switch, Show Last Report),
//          Sources/App/Views/OnboardingSetupPages.swift (finish page switch)
// Notes: Off until the user switches it on (consent: never pre-selected). Reports come from
//        macOS's own crash logs in ~/Library/Logs/DiagnosticReports, which macOS writes when the
//        app crashes; the next launch finds them. Only crashes of the last 14 days are sent, at
//        most 5 per launch, and the ids of sent reports are remembered so none goes twice.
//        Crashes from before the switch was turned on are sent too, within those 14 days: the
//        crash that made someone opt in is usually the one worth seeing.
//        Development builds (no bundle id) never send.

import Foundation
import Observation

@Observable
@MainActor
final class CrashReporter {
    static let shared = CrashReporter()

    nonisolated static let endpoint = URL(string: "https://minutemind-crash-reports.robin-steinkuehler.workers.dev/v1/crash")!
    nonisolated static let maxAge: TimeInterval = 14 * 86_400
    static let maxPerLaunch = 5

    private static let enabledKey = "mm.crashReportsEnabled"
    private static let sentKey = "mm.crashReportsSent"
    private static let sentLimit = 200

    /// The user's choice; switching it on sends what is waiting.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled && !oldValue { sendPending() }
        }
    }

    private var isSending = false

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Sends the recent crash reports not sent yet, when switched on. `delay` keeps the work out
    /// of the launch.
    func sendPending(after delay: Duration = .zero) {
        guard isEnabled, !isSending, !AppViewModel.isTestProcess,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        isSending = true
        Task {
            defer { isSending = false }
            try? await Task.sleep(for: delay)
            let sent = Set(UserDefaults.standard.stringArray(forKey: Self.sentKey) ?? [])
            let reports = await Task.detached { Self.recentReports(bundleID: bundleID) }.value
            for report in reports.filter({ !sent.contains($0.reportID) }).prefix(Self.maxPerLaunch) {
                guard isEnabled else { return }
                if await Self.upload(report) { markSent(report.reportID) }
            }
        }
    }

    /// The newest crash of the last 14 days exactly as it would be sent, nil when there is none.
    nonisolated static func latestReportText() -> String? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let report = recentReports(bundleID: bundleID).first else { return nil }
        return String(decoding: report.json, as: UTF8.self)
    }

    /// MinuteMind's crash reports of the last 14 days, newest first.
    nonisolated static func recentReports(bundleID: String, in folder: URL? = nil, now: Date = .now) -> [CrashReport] {
        let folder = folder ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("MinuteMind") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(date) <= maxAge else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .compactMap { url, _ in
                (try? String(contentsOf: url, encoding: .utf8)).flatMap { CrashReport.parse($0, bundleID: bundleID) }
            }
    }

    private nonisolated static func upload(_ report: CrashReport) async -> Bool {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = report.json
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(status)
    }

    private func markSent(_ id: String) {
        var sent = UserDefaults.standard.stringArray(forKey: Self.sentKey) ?? []
        sent.append(id)
        UserDefaults.standard.set(Array(sent.suffix(Self.sentLimit)), forKey: Self.sentKey)
    }
}
