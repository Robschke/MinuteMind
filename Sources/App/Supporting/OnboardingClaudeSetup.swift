// Purpose: The onboarding's Claude step: finds the installed Claude Code CLI and registers the
//          MinuteMind MCP server with it in one click, so every Claude Code session on this Mac
//          can use meetings, tasks and knowledge.
// Dependencies: Sources/App/Services/ClaudeCodeService.swift (findBinary, environment),
//               Sources/App/Services/MCP/MinuteMindMCPServer.swift (endpoint, token, isEnabled)
// RBAC: The registered entry carries the MCP bearer token, which grants full read, write and
//       delete access to MinuteMind for any Claude Code session of this user.
// Used by: Sources/App/Views/OnboardingSetupPages.swift (Claude page)
// Notes: The entry goes into Claude Code's user scope (~/.claude.json), not a project, so it works
//        in every folder. An existing "minutemind" entry is replaced rather than kept, because a
//        rotated token or port would leave it pointing nowhere. The CLI's own lookup in
//        ClaudeCodeService is cached for the app's run, so this step asks again on "Check again";
//        the rest of the app sees a fresh install after the restart at the end of the setup.

import Foundation
import Observation

@Observable
@MainActor
final class OnboardingClaudeSetup {
    enum CLIState: Equatable {
        case checking
        case found(path: String)
        case missing
    }

    enum MCPState: Equatable {
        case unknown
        case working
        case added
        case failed(String)
    }

    private(set) var cli: CLIState = .checking
    private(set) var mcp: MCPState = .unknown
    private var binary: URL?

    static let serverName = "minutemind"
    /// Claude Code's native installer, as published by Anthropic.
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    func checkCLI(server: MinuteMindMCPServer) async {
        cli = .checking
        let found = await Task.detached { ClaudeCodeService.findBinary() }.value
        binary = found
        guard let found else {
            cli = .missing
            return
        }
        cli = .found(path: found.path)
        if mcp == .unknown, await isRegistered(token: server.token) { mcp = .added }
    }

    /// Adds (or replaces) the MinuteMind entry in Claude Code's user scope and turns the server on.
    func registerMCP(server: MinuteMindMCPServer) async {
        guard let binary else { return }
        mcp = .working
        if !server.isEnabled { server.isEnabled = true }
        let service = ClaudeCodeService(executableURL: binary)
        _ = await Self.run(service, ["mcp", "remove", "--scope", "user", Self.serverName])
        let result = await Self.run(service, [
            "mcp", "add", "--scope", "user", "--transport", "http", Self.serverName, server.endpointURL,
            "--header", "Authorization: Bearer \(server.token)",
        ])
        if result.status == 0 {
            mcp = .added
        } else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            mcp = .failed(message.isEmpty ? "claude mcp add ended with code \(result.status)" : String(message.prefix(300)))
        }
    }

    /// True when Claude Code already has a "minutemind" entry with the current token.
    private func isRegistered(token: String) async -> Bool {
        guard let binary else { return false }
        let result = await Self.run(ClaudeCodeService(executableURL: binary), ["mcp", "get", Self.serverName])
        return result.status == 0 && result.output.contains(token)
    }

    private static func run(_ service: ClaudeCodeService, _ arguments: [String]) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = service.executableURL
            process.arguments = arguments
            process.environment = service.environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
