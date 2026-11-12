// Purpose: MCPUpdateTools, the MCP tools that let Claude check for a newer MinuteMind release
//          (check_for_update) and install it (update_app).
// Dependencies: Sources/App/Services/AppUpdateService.swift (release lookup, version compare,
//               installer), Sources/App/ViewModels/AppViewModel.swift (recording and queue state),
//               Sources/App/Services/ToolError (ToolExecutor.swift)
// Used by: Sources/App/Services/MCP/MinuteMindMCPServer.swift
// RBAC: none inside the app; every MCP client holding the bearer token may update the app. The
//       update only installs the published release from the project's GitHub repository.
// Notes: update_app refuses while a recording, transcription or meeting processing runs, because
//        the installer quits MinuteMind. It refuses for development builds (no .app bundle) and
//        when there is nothing newer, so a stray call never restarts the app for nothing.

import Foundation

@MainActor
struct MCPUpdateTools {
    let appViewModel: AppViewModel

    static let names: Set<String> = ["check_for_update", "update_app"]

    static var definitions: [[String: Any]] {
        [
            function(
                "check_for_update",
                "Compares the running MinuteMind version with the latest release on GitHub. Returns both versions, whether an update is available, the release notes and the Terminal command that installs or updates MinuteMind. Call it when the user asks about updates or the MinuteMind version."
            ),
            function(
                "update_app",
                "Installs the latest MinuteMind release: MinuteMind quits, is replaced in its folder and opens again within about a minute. Ask the user first, since open windows and Claude sessions in MinuteMind close. Refused while a recording, transcription or meeting processing runs, for development builds and when MinuteMind is already up to date."
            ),
        ]
    }

    func execute(toolName: String, arguments: [String: Any]) async throws -> String {
        switch toolName {
        case "check_for_update":
            return try json(try await status())
        case "update_app":
            return try await update()
        default:
            throw ToolError.invalidArguments("Unknown tool \(toolName)")
        }
    }

    private func status() async throws -> [String: Any] {
        let installed = AppUpdateService.installedVersion
        let release = try await AppUpdateService.latestRelease()
        return [
            "installed_version": installed,
            "latest_version": release.version,
            "update_available": AppUpdateService.isNewer(release.version, than: installed),
            "release_page": release.page.absoluteString,
            "release_notes": release.notes,
            "app_folder": AppUpdateService.installFolder?.path ?? "not an installed app (development build)",
            "terminal_command": AppUpdateService.installCommand,
        ]
    }

    private func update() async throws -> String {
        if let busy = busyReason() {
            throw ToolError.invalidArguments("Not now: \(busy). Try again once it has finished.")
        }
        guard let folder = AppUpdateService.installFolder else {
            throw ToolError.invalidArguments(
                "This MinuteMind is a development build, not an installed app. Install the release with: \(AppUpdateService.installCommand)")
        }
        let installed = AppUpdateService.installedVersion
        let release = try await AppUpdateService.latestRelease()
        guard AppUpdateService.isNewer(release.version, than: installed) else {
            return "MinuteMind \(installed) is up to date (latest release: \(release.version))."
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw ToolError.invalidArguments(
                "MinuteMind cannot write to \(folder.path). Update in Terminal with: \(AppUpdateService.installCommand)")
        }
        try AppUpdateService.startInstaller(into: folder, logFile: Self.logFile)
        return "Updating MinuteMind \(installed) to \(release.version). MinuteMind quits in a few seconds and opens again when the new version is installed (usually under a minute). The installer's output goes to \(Self.logFile.path)."
    }

    /// Why the app must not quit right now, nil when it may.
    private func busyReason() -> String? {
        if appViewModel.isRecording { return "a recording is running" }
        if appViewModel.transcriptionQueue.currentJob != nil || appViewModel.transcriptionQueue.pendingCount > 0 {
            return "a transcription is running"
        }
        if !appViewModel.processingStage.isEmpty { return "a meeting is being processed" }
        return nil
    }

    private static var logFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MinuteMind/update.log")
    }

    private func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func function(_ name: String, _ description: String) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": ["type": "object", "properties": [String: Any](), "required": [String]()] as [String: Any],
            ] as [String: Any],
        ]
    }
}
