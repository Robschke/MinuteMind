// Purpose: GitAvailability, whether a real git is installed. On a Mac without Apple's Command
//          Line Tools (or Xcode), /usr/bin/git is only a stub that opens Apple's install dialog
//          and fails, so every git call in the app asks here first, and the workspace and the
//          first-launch setup offer the install instead.
// Dependencies: Foundation (Process: /usr/bin/xcode-select), os (OSAllocatedUnfairLock)
// Used by: Sources/App/Services/WorkspaceGitService.swift (WorkspaceGit.run),
//          Sources/App/Services/ProjectRepositoryService.swift (git),
//          Sources/App/Services/SharedProjectSyncService.swift (SharedRepoGit.run),
//          Sources/App/Views/WorkspaceGitBranchBar.swift (hint row),
//          Sources/App/Supporting/OnboardingClaudeSetup.swift (setup check and install),
//          Tests/GitAvailabilityTests.swift
// Notes: Detection asks xcode-select for the developer folder and looks for usr/bin/git in it.
//        Neither step can open Apple's dialog, unlike running /usr/bin/git itself.
//        A found git is remembered for the app's run. A missing one is checked again at most
//        every few seconds, so installing the tools takes effect without a restart while the
//        workspace's 2 s poll stays cheap.

import Foundation
import os

enum GitAvailability {
    /// What git calls report while git is missing (the first line shows in sync status texts).
    static let missingMessage = "git is not installed (Apple's Command Line Tools are missing)."
    /// The Terminal command that opens Apple's installer.
    static let installCommand = "xcode-select --install"

    private struct Cache {
        var installed = false
        var checked: Date?
    }

    private static let cache = OSAllocatedUnfairLock(initialState: Cache())
    private static let recheckInterval: TimeInterval = 5

    /// True when a real git is installed. Runs xcode-select at most once per recheck interval
    /// while git is missing, so call it off the main actor.
    static var isInstalled: Bool {
        let now = Date()
        let cached: Bool? = cache.withLock { cache in
            if cache.installed { return true }
            if let checked = cache.checked, now.timeIntervalSince(checked) < recheckInterval { return false }
            return nil
        }
        if let cached { return cached }
        let found = isInstalled(developerDirectory: developerDirectory()) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        cache.withLock { $0 = Cache(installed: found, checked: now) }
        return found
    }

    /// Whether the developer folder xcode-select reports (nil when it reports none) holds git.
    static func isInstalled(developerDirectory: String?, isExecutable: (String) -> Bool) -> Bool {
        guard let folder = developerDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty else { return false }
        return isExecutable(URL(fileURLWithPath: folder).appendingPathComponent("usr/bin/git").path)
    }

    /// Opens Apple's installer for the Command Line Tools, which include git. Returns at once;
    /// the install runs in Apple's own window.
    static func installDeveloperTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// `xcode-select -p`: the active developer folder, nil when none is set up.
    private static func developerDirectory() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
