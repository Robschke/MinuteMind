// Purpose: CrashReport, turns one macOS crash report (.ips) of MinuteMind into the small report
//          that is sent when the user has switched crash reports on: where it crashed, the app
//          and macOS version and the Mac model, nothing about the user or their meetings.
// Dependencies: Foundation (JSONSerialization), CryptoKit (report id)
// Used by: Sources/App/Services/CrashReporter.swift, Tests/CrashReportTests.swift
// Notes: An .ips file is a one-line JSON header followed by a JSON body. Only the crashed
//        thread's frames (and the exception backtrace of an Objective-C exception) are kept, each
//        library named by its file name only. Home folder paths in any kept text become
//        /Users/USER. The report id is a SHA-256 of macOS's incident id, so a report is sent once
//        and the incident id itself never leaves the Mac. The crash time is cut to the day.
//        Field names match the crash report Worker's validation; change both together.

import CryptoKit
import Foundation

struct CrashReport: Codable, Equatable, Sendable {
    struct Frame: Codable, Equatable, Sendable {
        var image: String
        var offset: Int
        var symbol: String?
    }

    var schema = 1
    var reportID: String
    var appVersion: String
    var build: String
    var osVersion: String
    var model: String
    var binaryUUID: String
    var crashDay: String
    var exceptionType: String
    var signal: String?
    var termination: String?
    var message: String?
    var queue: String?
    var frames: [Frame]
    var exceptionFrames: [Frame]?

    enum CodingKeys: String, CodingKey {
        case schema, build, model, signal, termination, message, queue, frames
        case reportID = "report_id", appVersion = "app_version", osVersion = "os_version"
        case binaryUUID = "binary_uuid", crashDay = "crash_day", exceptionType = "exception_type"
        case exceptionFrames = "exception_frames"
    }

    static let maxFrames = 64
    static let maxMessageLength = 2000

    /// The report in an .ips file's text, nil when the file is no crash of the app `bundleID`.
    static func parse(_ text: String, bundleID: String) -> CrashReport? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = object(text[..<newline]),
              let body = object(text[text.index(after: newline)...]),
              header["bundleID"] as? String == bundleID,
              let incident = header["incident_id"] as? String ?? body["incident"] as? String,
              let exception = body["exception"] as? [String: Any],
              let exceptionType = exception["type"] as? String
        else { return nil }

        let images = (body["usedImages"] as? [[String: Any]] ?? []).map(imageName)
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int
            ?? threads.firstIndex { $0["triggered"] as? Bool == true }
        let thread = faulting.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
        let exceptionFrames = (body["lastExceptionBacktrace"] as? [[String: Any]]).map { frames($0, images) }
        let messages = (body["asi"] as? [String: [String]] ?? [:]).sorted { $0.key < $1.key }.flatMap(\.value)
        let osVersion = header["os_version"] as? String
            ?? (body["osVersion"] as? [String: Any]).flatMap { $0["train"] as? String } ?? "unknown"

        return CrashReport(
            reportID: SHA256.hash(data: Data(incident.utf8)).map { String(format: "%02x", $0) }.joined(),
            appVersion: header["app_version"] as? String ?? "unknown",
            build: header["build_version"] as? String ?? "unknown",
            osVersion: osVersion,
            model: body["modelCode"] as? String ?? "unknown",
            binaryUUID: header["slice_uuid"] as? String ?? "unknown",
            crashDay: String((body["captureTime"] as? String ?? header["timestamp"] as? String ?? "unknown").prefix(10)),
            exceptionType: exceptionType,
            signal: exception["signal"] as? String,
            termination: (body["termination"] as? [String: Any])?["indicator"] as? String,
            message: messages.isEmpty ? nil : String(sanitized(messages.joined(separator: "\n")).prefix(maxMessageLength)),
            queue: (thread?["queue"] as? String).map(sanitized),
            frames: frames(thread?["frames"] as? [[String: Any]] ?? [], images),
            exceptionFrames: exceptionFrames?.isEmpty == false ? exceptionFrames : nil
        )
    }

    /// Pretty-printed JSON, exactly what is sent.
    var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Home folder paths with the user name replaced.
    static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: #"/Users/[^/\s"']+"#, with: "/Users/USER", options: .regularExpression)
    }

    private static func object(_ text: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private static func imageName(_ image: [String: Any]) -> String {
        if let name = image["name"] as? String { return sanitized(name) }
        if let path = image["path"] as? String { return URL(fileURLWithPath: path).lastPathComponent }
        return "unknown"
    }

    private static func frames(_ raw: [[String: Any]], _ images: [String]) -> [Frame] {
        raw.prefix(maxFrames).map { frame in
            let index = frame["imageIndex"] as? Int ?? -1
            return Frame(
                image: images.indices.contains(index) ? images[index] : "unknown",
                offset: frame["imageOffset"] as? Int ?? 0,
                symbol: (frame["symbol"] as? String).map(sanitized)
            )
        }
    }
}
