// Purpose: Tests for CrashReport: what of a macOS crash log (.ips) is kept, what is dropped, and
//          that user names never get through; and for finding recent reports in a folder.
// Dependencies: Sources/App/Services/CrashReport.swift, Sources/App/Services/CrashReporter.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("CrashReport Tests")
struct CrashReportTests {
    static let bundleID = "dev.robin.MinuteMind"

    static func ips(bundleID: String = bundleID, incident: String = "80A08BD6-5F00-49E3-BA48-3B9EE5C065FC") -> String {
        let header = """
        {"app_name":"MinuteMind","timestamp":"2026-11-12 17:21:44.00 +0100","app_version":"0.1.0","slice_uuid":"9bdc7fe7-ec6e-359f-86d6-dc2a8161f396","build_version":"1","bundleID":"\(bundleID)","os_version":"macOS 26.5.2 (25F84)","incident_id":"\(incident)","name":"MinuteMind"}
        """
        let body = """
        {"incident":"\(incident)","crashReporterKey":"SECRET-DEVICE-KEY","userID":501,"modelCode":"Mac15,3",
         "procPath":"/Users/jane/Applications/MinuteMind.app/Contents/MacOS/MinuteMind",
         "captureTime":"2026-11-12 17:21:22.7921 +0100",
         "exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP","codes":"0x1"},
         "termination":{"indicator":"Trace/BPT trap: 5"},
         "asi":{"libswiftCore.dylib":["Fatal error: file /Users/jane/Projects/x.swift line 3"]},
         "faultingThread":1,
         "usedImages":[{"name":"MinuteMind","path":"/Users/jane/Applications/MinuteMind.app/Contents/MacOS/MinuteMind"},{"path":"/usr/lib/system/libdispatch.dylib"}],
         "threads":[
           {"frames":[{"imageIndex":0,"imageOffset":1,"symbol":"main"}]},
           {"queue":"com.apple.eventkit.reminders.search","frames":[
             {"imageIndex":1,"imageOffset":226556,"symbol":"_dispatch_assert_queue_fail"},
             {"imageIndex":0,"imageOffset":12568732,"symbol":"closure #1 in RemindersService.listReminders()"}]}]}
        """
        return header + "\n" + body
    }

    @Test("Keeps where it crashed, the versions and the model")
    func keepsCrashLocation() throws {
        let report = try #require(CrashReport.parse(Self.ips(), bundleID: Self.bundleID))
        #expect(report.appVersion == "0.1.0")
        #expect(report.osVersion == "macOS 26.5.2 (25F84)")
        #expect(report.model == "Mac15,3")
        #expect(report.crashDay == "2026-11-12")
        #expect(report.exceptionType == "EXC_BREAKPOINT")
        #expect(report.queue == "com.apple.eventkit.reminders.search")
        #expect(report.frames.map(\.image) == ["libdispatch.dylib", "MinuteMind"])
        #expect(report.frames.last?.offset == 12568732)
        #expect(report.frames.last?.symbol == "closure #1 in RemindersService.listReminders()")
    }

    @Test("No user name, device key or incident id leaves the Mac")
    func dropsIdentifyingData() throws {
        let report = try #require(CrashReport.parse(Self.ips(), bundleID: Self.bundleID))
        let sent = String(decoding: report.json, as: UTF8.self)
        #expect(!sent.contains("jane"))
        #expect(!sent.contains("SECRET-DEVICE-KEY"))
        #expect(!sent.contains("80A08BD6"))
        #expect(!sent.contains("userID") && !sent.contains("procPath"))
        #expect(report.message == "Fatal error: file /Users/USER/Projects/x.swift line 3")
        #expect(report.reportID.count == 64)
    }

    @Test("The same crash always gets the same report id, another crash another one")
    func stableReportID() throws {
        let first = try #require(CrashReport.parse(Self.ips(), bundleID: Self.bundleID))
        let again = try #require(CrashReport.parse(Self.ips(), bundleID: Self.bundleID))
        let other = try #require(CrashReport.parse(Self.ips(incident: "OTHER"), bundleID: Self.bundleID))
        #expect(first.reportID == again.reportID)
        #expect(first.reportID != other.reportID)
    }

    @Test("Crash logs of other apps and broken files are ignored")
    func ignoresOthers() {
        #expect(CrashReport.parse(Self.ips(bundleID: "com.other.App"), bundleID: Self.bundleID) == nil)
        #expect(CrashReport.parse("not a crash log", bundleID: Self.bundleID) == nil)
    }

    @Test("Only MinuteMind's crash logs of the last 14 days are found, newest first")
    func findsRecentReports() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func write(_ name: String, _ text: String, daysAgo: Double) throws {
            let url = folder.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)],
                                                  ofItemAtPath: url.path)
        }
        try write("MinuteMind-old.ips", Self.ips(incident: "old"), daysAgo: 20)
        try write("MinuteMind-a.ips", Self.ips(incident: "a"), daysAgo: 3)
        try write("MinuteMind-b.ips", Self.ips(incident: "b"), daysAgo: 1)
        try write("Safari-c.ips", Self.ips(incident: "c"), daysAgo: 1)

        let reports = CrashReporter.recentReports(bundleID: Self.bundleID, in: folder, now: now)
        let expected = try ["b", "a"].map { try #require(CrashReport.parse(Self.ips(incident: $0), bundleID: Self.bundleID)).reportID }
        #expect(reports.map(\.reportID) == expected)
    }
}
