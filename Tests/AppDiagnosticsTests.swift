// Purpose: Tests for the diagnostics Claude reads over MCP: each failure mode (Claude Code,
//          permissions, a missing or broken Parakeet, speaker models, failed meetings, sync, disk)
//          becomes an issue with the right severity, fix and repair; a healthy app reports nothing
//          serious; the report is valid JSON; the tool names do not clash.
// Dependencies: Sources/App/Help/AppDiagnostics.swift, Sources/App/Help/AppLogReader.swift,
//               Sources/App/Services/MCP/MCPDiagnosticsTools.swift

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("AppDiagnostics Tests")
struct AppDiagnosticsTests {
    /// Everything installed and allowed.
    private func healthy() -> DiagnosticsSnapshot {
        var s = DiagnosticsSnapshot()
        s.claudePathAtLaunch = "/usr/local/bin/claude"
        s.claudePathNow = "/usr/local/bin/claude"
        s.launchAtLogin = true
        for permission in OnboardingPermission.allCases { s.permissions[permission.rawValue] = .granted }
        s.parakeetInstalledFlag = true
        s.parakeet = .init(markerPresent: true, version: "ultra", folder: "/models/x", folderExists: true,
                           filesComplete: true, revision: "abc", installedAt: nil, loadedInMemory: false)
        s.freeDiskBytes = 50_000_000_000
        return s
    }

    private func issue(_ id: String, in s: DiagnosticsSnapshot) -> DiagnosticIssue? {
        AppDiagnostics.issues(in: s).first { $0.id == id }
    }

    @Test("A healthy app has no issues")
    func healthyApp() {
        #expect(AppDiagnostics.issues(in: healthy()).isEmpty)
    }

    @Test("Claude Code missing, or installed after launch")
    func claude() {
        var s = healthy()
        s.claudePathAtLaunch = nil
        s.claudePathNow = nil
        #expect(issue("claude_missing", in: s)?.severity == .error)
        #expect(issue("claude_missing", in: s)?.fix.contains("install.sh") == true)

        s.claudePathNow = "/Users/x/.local/bin/claude"
        #expect(issue("claude_missing", in: s) == nil)
        #expect(issue("claude_found_after_launch", in: s)?.fix.contains("reopen") == true)
    }

    @Test("Parakeet: missing, failed download, broken files, stale state, installing, update")
    func parakeet() {
        var s = healthy()
        s.parakeet = .init(markerPresent: false, version: nil, folder: nil, folderExists: false,
                           filesComplete: false, revision: nil, installedAt: nil, loadedInMemory: false)
        s.parakeetInstalledFlag = false
        #expect(issue("parakeet_missing", in: s)?.severity == .warning)
        #expect(issue("parakeet_missing", in: s)?.repair == .installParakeet)

        s.parakeetLastError = "The network connection was lost."
        #expect(issue("parakeet_missing", in: s)?.severity == .error)
        #expect(issue("parakeet_missing", in: s)?.problem.contains("network connection was lost") == true)

        s.parakeetLastError = nil
        s.parakeet = .init(markerPresent: true, version: "ultra", folder: "/gone", folderExists: false,
                           filesComplete: false, revision: nil, installedAt: nil, loadedInMemory: false)
        let broken = issue("parakeet_broken", in: s)
        #expect(broken?.severity == .error)
        #expect(broken?.problem.contains("/gone is missing") == true)
        #expect(broken?.repair == .installParakeet)

        s.transcriptionEngine = "appleSpeech"
        #expect(issue("parakeet_broken", in: s)?.severity == .warning, "less urgent when Parakeet is not the engine")

        var stale = healthy()
        stale.parakeetInstalledFlag = false
        #expect(issue("parakeet_state_stale", in: stale)?.repair == .verifyParakeet)

        var installing = healthy()
        installing.parakeetInstalling = true
        installing.parakeetProgress = 0.42
        let issues = AppDiagnostics.issues(in: installing)
        #expect(issues.map(\.id) == ["parakeet_installing"])
        #expect(issues.first?.problem.contains("42 %") == true)

        var update = healthy()
        update.parakeetUpdate = "update available"
        #expect(issue("parakeet_update", in: update)?.severity == .info)
    }

    @Test("Permissions: severity by effect, repair names the permission, restart when pending")
    func permissions() {
        var s = healthy()
        s.permissions["microphone"] = .denied
        s.permissions["screenRecording"] = .pendingRestart
        s.permissions["accessibility"] = .notDetermined
        let microphone = issue("permission_microphone", in: s)
        #expect(microphone?.severity == .error)
        #expect(microphone?.repair == .requestPermission)
        #expect(microphone?.repairArguments["permission"] == "microphone")
        #expect(issue("permission_screenRecording", in: s)?.fix.contains("reopen") == true)
        #expect(issue("permission_accessibility", in: s) == nil, "only matters with dictation on")

        s.quickDictationEnabled = true
        #expect(issue("permission_accessibility", in: s)?.severity == .warning)
    }

    @Test("Speaker models: only when identify speakers is on")
    func speakers() {
        var s = healthy()
        s.diarizationEngine = "nemotron3"
        #expect(issue("nemotron_missing", in: s) == nil)
        s.diarizationEnabled = true
        #expect(issue("speaker_models_missing", in: s)?.repair == .installSpeakerModels)
        #expect(issue("nemotron_missing", in: s)?.repair == .installNemotron)
        s.nemotronDownloading = true
        #expect(issue("nemotron_missing", in: s) == nil)
    }

    @Test("Failed meetings offer a retry only with audio; sync problems offer a sync")
    func failures() {
        var s = healthy()
        let withAudio = UUID()
        s.failedMeetings = [
            .init(id: withAudio, title: "Weekly", date: Date(), error: "Model not installed", hasAudio: true),
            .init(id: UUID(), title: "Old", date: Date(), error: nil, hasAudio: false),
        ]
        let issues = AppDiagnostics.issues(in: s).filter { $0.id.hasPrefix("meeting_failed_") }
        #expect(issues.count == 2)
        #expect(issues[0].repair == .retryTranscription)
        #expect(issues[0].repairArguments["meeting_id"] == withAudio.uuidString)
        #expect(issues[1].repair == nil)

        let project = UUID()
        s.sharedProjects = [.init(id: project, name: "Acme", state: "problem", problem: "Authentication failed", lastSynced: nil)]
        let sync = issue("sync_\(project.uuidString)", in: s)
        #expect(sync?.repair == .syncSharedProject)
        #expect(sync?.repairArguments["project_id"] == project.uuidString)
    }

    @Test("Low disk, recent errors, and errors sort first")
    func diskErrorsAndOrder() {
        var s = healthy()
        s.freeDiskBytes = 300_000_000
        s.launchAtLogin = false
        s.recentErrors = [AppErrorRecord(date: Date(), message: "Failed to install Parakeet model: offline")]
        let issues = AppDiagnostics.issues(in: s)
        #expect(issues.first?.id == "low_disk")
        #expect(issues.first?.severity == .error)
        #expect(issues.contains { $0.id == "recent_errors" && $0.problem.contains("offline") })
        #expect(issues.map(\.severity) == issues.map(\.severity).sorted())

        s.recentErrors = [AppErrorRecord(date: Date().addingTimeInterval(-7200), message: "old")]
        #expect(issue("recent_errors", in: s) == nil, "only the last hour")
    }

    @Test("The report is valid JSON and a section narrows it but keeps the issues")
    func report() {
        var s = healthy()
        s.claudePathAtLaunch = nil
        s.claudePathNow = nil
        let full = MCPDiagnosticsTools.report(s, section: nil)
        #expect(JSONSerialization.isValidJSONObject(full))
        #expect((full["issues"] as? [[String: Any]])?.isEmpty == false)
        #expect(full["transcription"] != nil && full["permissions"] != nil)

        let narrow = MCPDiagnosticsTools.report(s, section: "claude")
        #expect(narrow["claude"] != nil && narrow["transcription"] == nil && narrow["issues"] != nil)
    }

    @Test("Repair actions and tool names are well-formed and unique")
    func names() {
        for action in RepairAction.allCases {
            #expect(action.rawValue.range(of: "^[a-z]+(_[a-z]+)*$", options: .regularExpression) != nil)
        }
        let exposed = MinuteMindMCPServer.exposedToolNames()
        #expect(Set(exposed).count == exposed.count)
        #expect(MCPDiagnosticsTools.names.isSubset(of: exposed))
    }

    @Test("Log lines that read like failures count as errors")
    func logErrorWords() {
        #expect(AppLogReader.looksLikeError("KnowledgeCurator: Knowledge: Weekly failed: timeout"))
        #expect(AppLogReader.looksLikeError("Could not open file"))
        #expect(!AppLogReader.looksLikeError("AppViewModel: startRecording called"))
    }
}
