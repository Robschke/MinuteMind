// Purpose: Tests for AppUpdateService: version comparison, reading GitHub's release JSON, and the
//          update tools being exposed over MCP.
// Dependencies: Sources/App/Services/AppUpdateService.swift,
//               Sources/App/Services/MCP/MCPUpdateTools.swift, MinuteMindMCPServer.exposedToolNames

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("AppUpdateService Tests")
struct AppUpdateServiceTests {
    @Test("Versions compare number by number, with or without a leading v")
    func versionComparison() {
        #expect(AppUpdateService.isNewer("0.2.0", than: "0.1.0"))
        #expect(AppUpdateService.isNewer("v0.10.0", than: "0.9.1"))
        #expect(AppUpdateService.isNewer("1.0", than: "0.9.9"))
        #expect(AppUpdateService.isNewer("0.1.1", than: "0.1"))
        #expect(!AppUpdateService.isNewer("0.1.0", than: "0.1.0"))
        #expect(!AppUpdateService.isNewer("v0.1", than: "0.1.0"))
        #expect(!AppUpdateService.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test("Development builds and odd tags are never offered an update")
    func nonNumericVersions() {
        #expect(!AppUpdateService.isNewer("0.2.0", than: "dev"))
        #expect(!AppUpdateService.isNewer("nightly", than: "0.1.0"))
        #expect(!AppUpdateService.isNewer("0.2.0-beta", than: "0.1.0"))
    }

    @Test("GitHub's latest-release JSON becomes a Release")
    func parsesRelease() throws {
        let json = """
        {"tag_name": "v0.2.0", "html_url": "https://github.com/Robschke/MinuteMind/releases/tag/v0.2.0",
         "body": "Update from Claude.", "published_at": "2026-11-20T10:00:00Z"}
        """
        let release = try AppUpdateService.parseRelease(Data(json.utf8))
        #expect(release.version == "0.2.0")
        #expect(release.page.absoluteString.hasSuffix("/v0.2.0"))
        #expect(release.notes == "Update from Claude.")
        #expect(release.published != nil)
    }

    @Test("A response without a tag is no release")
    func missingTag() {
        #expect(throws: AppUpdateService.UpdateError.self) {
            try AppUpdateService.parseRelease(Data(#"{"message": "Not Found"}"#.utf8))
        }
    }

    @Test("The update tools are served over MCP")
    @MainActor
    func toolsExposed() {
        let names = Set(MinuteMindMCPServer.exposedToolNames())
        #expect(names.isSuperset(of: MCPUpdateTools.names))
    }
}
