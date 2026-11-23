// Purpose: Opt-in snapshots of real screens in sample themes (the standard look, a dense square
//          terminal look and a large roomy look), to check by eye that fonts, density and corners
//          from a theme file leave every layout intact.
// Dependencies: Sources/App/Supporting/ThemeStore.swift, Sources/App/Config/ThemeFile.swift,
//               Sources/App/Views/ContentView.swift, Sources/App/Views/MeetingMinutesSettingsView.swift
// Notes: Only runs with MM_THEME_SNAPSHOT_DIR=<folder> set: `MM_THEME_SNAPSHOT_DIR=/tmp/themes swift
//        test --filter ThemeSnapshot`. Rendered through an NSHostingView like the onboarding
//        snapshots (ImageRenderer leaves AppKit controls blank). In a test process the themes
//        folder is a temporary one, so the user's themes are never touched.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("Theme snapshots")
struct ThemeSnapshotTests {
    private static let samples: [[String: Any]] = [
        [
            "id": "snapshot-terminal", "name": "Terminal", "base": "midnight",
            "colors": ["background": ["light": "#F6F7F9", "dark": "#0A0D12"]],
            "font": ["family": "Menlo", "scale": 0.95], "corners": "square", "density": "compact",
            "terminal": ["family": "Menlo", "size": 13],
        ],
        [
            "id": "snapshot-large", "name": "Large", "base": "ember",
            "font": ["scale": 1.4], "corners": "round", "density": "roomy",
        ],
    ]

    @Test("Snapshots of main screens in sample themes", .enabled(if: ProcessInfo.processInfo.environment["MM_THEME_SNAPSHOT_DIR"] != nil))
    func snapshots() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MM_THEME_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let themes = ThemeStore.shared
        let previousTheme = themes.themeID
        defer { themes.themeID = previousTheme }
        var ids = [AppTheme.studio.id]
        for sample in Self.samples {
            let file = try ThemeFileValidator.validated(sample)
            try themes.saveFileTheme(file)
            ids.append(file.themeID)
        }

        let viewModel = AppViewModel()
        for id in ids {
            themes.themeID = id
            let name = id.replacingOccurrences(of: "file:", with: "")
            for place in [NavigationPlace.home, .cockpit, .inbox] {
                viewModel.go(to: place)
                try render(ContentView().environment(viewModel).themedWindow(),
                           size: NSSize(width: 1280, height: 820),
                           to: folder.appendingPathComponent("\(name)-\(place.snapshotName).png"))
            }
            try render(MeetingMinutesSettingsView().environment(viewModel).themedWindow(),
                       size: NSSize(width: 980, height: 720),
                       to: folder.appendingPathComponent("\(name)-settings.png"))
        }
    }

    private func render(_ view: some View, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<2 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

private extension NavigationPlace {
    var snapshotName: String {
        switch self {
        case .home: "home"
        case .cockpit: "cockpit"
        case .inbox: "inbox"
        default: "page"
        }
    }
}
