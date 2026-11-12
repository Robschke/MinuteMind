// Purpose: Tests for GitAvailability: which developer folders count as having git.
// Dependencies: Sources/App/Services/GitAvailability.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("GitAvailability Tests")
struct GitAvailabilityTests {
    @Test("git counts as installed when the developer folder holds usr/bin/git")
    func folderWithGit() {
        let folder = "/Library/Developer/CommandLineTools\n"
        #expect(GitAvailability.isInstalled(developerDirectory: folder) {
            $0 == "/Library/Developer/CommandLineTools/usr/bin/git"
        })
    }

    @Test("No developer folder, an empty one or one without git means git is missing")
    func missingGit() {
        #expect(!GitAvailability.isInstalled(developerDirectory: nil) { _ in true })
        #expect(!GitAvailability.isInstalled(developerDirectory: " \n") { _ in true })
        #expect(!GitAvailability.isInstalled(developerDirectory: "/Applications/Xcode.app/Contents/Developer") { _ in false })
    }
}
