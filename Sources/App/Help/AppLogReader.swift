// Purpose: AppLogReader, reads MinuteMind's own recent log lines (NSLog and os_log, from the app
//          and the frameworks inside it) from macOS unified logging, for get_app_log.
// Dependencies: OSLog (OSLogStore)
// Used by: Sources/App/Services/MCP/MCPDiagnosticsTools.swift (get_app_log)
// RBAC: the store is opened for the current process only, so it never shows other apps' logs.
// Notes: Many failures (knowledge curation, sync, model loading) are only logged, never shown, so
//        the log is where Claude finds the cause. Reading the store takes a moment and must not
//        block the main thread: `read` is nonisolated and the caller runs it detached. The store
//        only holds what this run of the app logged; after a crash the previous run's lines need
//        `log show` in Terminal.

import Foundation
import OSLog

enum AppLogReader {
    struct Query: Sendable {
        var sinceMinutes = 30
        var contains: String?
        var errorsOnly = false
        var limit = 200
    }

    /// Matching lines, oldest first, the newest `limit` of them.
    static func read(_ query: Query) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let start = store.position(date: Date().addingTimeInterval(-Double(query.sinceMinutes) * 60))
        let needle = query.contains?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        for case let entry as OSLogEntryLog in try store.getEntries(at: start) {
            if query.errorsOnly && !(entry.level == .error || entry.level == .fault) && !looksLikeError(entry.composedMessage) {
                continue
            }
            if let needle, !needle.isEmpty, !entry.composedMessage.lowercased().contains(needle) { continue }
            let source = entry.subsystem.isEmpty ? "" : " [\(entry.subsystem)\(entry.category.isEmpty ? "" : "/\(entry.category)")]"
            lines.append("\(formatter.string(from: entry.date)) \(levelName(entry.level))\(source) \(entry.composedMessage)")
            if lines.count > query.limit * 4 { lines.removeFirst(lines.count - query.limit) }
        }
        return Array(lines.suffix(query.limit))
    }

    /// NSLog writes everything at the default level, so errors are recognised by their words too.
    static func looksLikeError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["error", "failed", "failure", "cannot", "couldn't", "could not", "refused", "denied", "exception"]
            .contains { lower.contains($0) }
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "ERROR"
        case .fault: "FAULT"
        default: "log"
        }
    }
}
