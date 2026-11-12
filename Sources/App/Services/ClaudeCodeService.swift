// Purpose: ClaudeCodeService, runs the user's installed Claude Code CLI headless (`claude -p`) so the
//          app can use Claude models (Sonnet for transcript cleanup, Opus for agents) through the
//          user's own Claude subscription, without an API key in MinuteMind.
// Dependencies: Foundation (Process). Requires Claude Code installed and logged in.
// Used by: Sources/App/Services/TranscriptCleanupService.swift (Claude cleanup backend),
//          the "Claude Code" AI profile (chat / chatJSON from the meeting, todo, brief, calendar
//          blocker and knowledge services),
//          Sources/App/ViewModels/AppViewModel.swift (availability check),
//          Sources/App/Services/ClaudeAssistantService.swift (voice assistant runs, `runPrinted`)
// Notes: GUI apps do not inherit the shell PATH, so the binary is looked up in the usual install
//        locations and, as a last resort, through a login shell. Login state lives in the keychain
//        and needs USER/LOGNAME, which the app's own environment provides.
//        Completion calls run with no tools, no MCP servers, no user/project settings and no
//        session persistence, from a temporary directory, so a cleanup can never touch files and
//        never picks up a CLAUDE.md. The `sonnet` / `opus` aliases always map to the newest model.

import Foundation

struct ClaudeCodeService: Sendable {
    enum ServiceError: Error, LocalizedError {
        case notInstalled
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Claude Code is not installed. Install it from claude.com/code and run `claude` once to log in."
            case .failed(let message): return "Claude Code: \(message)"
            case .timedOut: return "Claude Code did not answer in time."
            }
        }
    }

    let executableURL: URL

    /// The installed CLI, or nil when Claude Code is not installed.
    static func locate() -> ClaudeCodeService? {
        locatedBinary.map(ClaudeCodeService.init(executableURL:))
    }

    private static let locatedBinary: URL? = findBinary()

    /// Looks for the CLI now, without the cached answer `locate()` keeps for the app's lifetime
    /// (the onboarding checks again after the user installed Claude Code). Can start a login
    /// shell, so call it off the main thread.
    static func findBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        // Custom installs (nvm, volta, ...): ask a login shell, which sources the user's profile.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: output) ? URL(fileURLWithPath: output) : nil
    }

    /// Environment for child processes: the app's own plus the CLI's directory and common tool
    /// paths, so Claude Code (and anything it launches) finds node, git and friends.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [executableURL.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return env
    }

    /// One-shot completion without tools. Returns Claude's final text.
    func complete(
        prompt: String,
        systemPrompt: String,
        model: String = "sonnet",
        timeout: TimeInterval = 300
    ) async throws -> String {
        let arguments = [
            "-p", "--model", model, "--output-format", "json",
            "--system-prompt", systemPrompt,
            "--tools", "", "--strict-mcp-config", "--setting-sources", "",
            "--no-session-persistence",
        ]
        let data = try await run(arguments: arguments, stdin: prompt, timeout: timeout)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.failed(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let result = object["result"] as? String ?? ""
        if object["is_error"] as? Bool == true { throw ServiceError.failed(result) }
        return result
    }

    /// Runs Claude as a small agent inside `workingDirectory` with only the given built-in tools
    /// (e.g. Read, Edit, Write, Glob, Grep), file edits auto-accepted and nothing else allowed:
    /// no shell, no MCP, no user settings. Used for the knowledge curation in workspace repos.
    /// Edits outside the working directory would need a permission prompt, which headless mode
    /// cannot answer, so they are refused. Returns Claude's final reply.
    func runAgent(
        prompt: String,
        systemPrompt: String,
        workingDirectory: URL,
        tools: [String],
        model: String = "sonnet",
        timeout: TimeInterval = 600
    ) async throws -> String {
        let arguments = [
            "-p", "--model", model, "--output-format", "json",
            "--system-prompt", systemPrompt,
            "--tools", tools.joined(separator: ","), "--permission-mode", "acceptEdits",
            "--strict-mcp-config", "--setting-sources", "",
            "--no-session-persistence",
        ]
        let data = try await run(arguments: arguments, stdin: prompt, timeout: timeout, workingDirectory: workingDirectory)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.failed(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let result = object["result"] as? String ?? ""
        if object["is_error"] as? Bool == true { throw ServiceError.failed(result) }
        return result
    }

    /// Runs the CLI with prepared arguments (they must include `-p` and `--output-format json`)
    /// and returns the final text and the session ID, for runs that resume later (the voice
    /// assistant, ClaudeAssistantService).
    func runPrinted(
        arguments: [String], prompt: String, workingDirectory: URL, timeout: TimeInterval
    ) async throws -> (result: String, sessionID: String?) {
        let data = try await run(arguments: arguments, stdin: prompt, timeout: timeout, workingDirectory: workingDirectory)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.failed(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let result = object["result"] as? String ?? ""
        if object["is_error"] as? Bool == true { throw ServiceError.failed(result) }
        return (result, object["session_id"] as? String)
    }

    /// One system + user exchange through the installed CLI: the Claude Code AI profile's
    /// equivalent of a chat completion request.
    static func chat(system: String, user: String, model: String, timeout: TimeInterval = 300) async throws -> String {
        guard let claude = locate() else { throw ServiceError.notInstalled }
        return try await claude.complete(prompt: user, systemPrompt: system, model: model, timeout: timeout)
    }

    /// Like `chat`, for callers that parse a JSON object (what other providers get from
    /// `response_format: json_object`). Returns just the object, without prose or code fences.
    static func chatJSON(system: String, user: String, model: String) async throws -> String {
        let text = try await chat(
            system: system + "\n\nRespond with a single JSON object only: no prose, no Markdown code fences.",
            user: user, model: model)
        return jsonObject(in: text)
    }

    /// The outermost `{...}` in `text`, or the trimmed text when there is none.
    static func jsonObject(in text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[start...end])
    }

    private func run(
        arguments: [String], stdin: String, timeout: TimeInterval, workingDirectory: URL? = nil
    ) async throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory ?? FileManager.default.temporaryDirectory
        let box = ProcessBox(process)

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let process = box.process
                let input = Pipe(), output = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()

                let timer = DispatchWorkItem { box.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                defer { timer.cancel() }

                input.fileHandleForWriting.write(Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                try Task.checkCancellation()
                if process.terminationReason == .uncaughtSignal { throw ServiceError.timedOut }
                return data
            }.value
        } onCancel: {
            box.terminate()
        }
    }
}

/// Lets the cancellation handler and the timeout stop a running CLI process.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}
