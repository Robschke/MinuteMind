// Purpose: Tests for the first-launch setup: step order, the diarization default it relies on,
//          and an opt-in snapshot of every page for checking the layout by eye.
// Dependencies: Sources/App/Supporting/OnboardingFlow.swift, Sources/App/Views/OnboardingView.swift,
//               Sources/App/Config/AutomationSettings.swift
// Notes: The snapshots only run with MM_ONBOARDING_SNAPSHOT_DIR=<folder> set; they render each page
//        through an NSHostingView (ImageRenderer leaves AppKit controls blank) at 1100 x 760 pt.
//        In a test process OnboardingFlow never activates itself, so the pages are rendered by
//        jumping to each step directly.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MinuteMindApp

@Suite("Onboarding")
@MainActor
struct OnboardingFlowTests {

    @Test("Steps run welcome, permissions, Claude, models, tour, finish")
    func stepOrder() throws {
        let ids = OnboardingFlow.steps.map(\.id)
        #expect(ids.first == "welcome")
        #expect(ids.last == "finish")
        #expect(Set(ids).count == ids.count)
        let permissions = OnboardingPermission.allCases.map { "permission.\($0.rawValue)" }
        #expect(Array(ids[1...permissions.count]) == permissions)
        let claude = try #require(ids.firstIndex(of: "claude"))
        let models = try #require(ids.firstIndex(of: "models"))
        let firstTour = try #require(ids.firstIndex(where: { $0.hasPrefix("tour.") }))
        #expect(claude == permissions.count + 1)
        #expect(models == claude + 1)
        #expect(firstTour == models + 1)
        #expect(ids.filter { $0.hasPrefix("tour.") }.count == OnboardingTourTopic.allCases.count)
    }

    @Test("Microphone comes first among the permissions")
    func microphoneFirst() {
        #expect(OnboardingPermission.allCases.first == .microphone)
    }

    @Test("Nemotron 3 is the default diarization engine")
    func nemotronDefault() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        #expect(AutomationSettings(defaults: defaults).diarizationEngine == "nemotron3")
    }

    @Test("Snapshots of every onboarding page", .enabled(if: ProcessInfo.processInfo.environment["MM_ONBOARDING_SNAPSHOT_DIR"] != nil))
    @MainActor
    func snapshots() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MM_ONBOARDING_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let viewModel = AppViewModel()
        let flow = OnboardingFlow.shared
        for (position, step) in OnboardingFlow.steps.enumerated() {
            flow.jump(to: step)
            let host = NSHostingView(rootView: OnboardingView().environment(viewModel).themedWindow())
            host.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
            // Two passes: preferences (the Continue label) settle after the first layout.
            for _ in 0..<2 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent(String(format: "%02d-%@.png", position, step.id)))
        }
    }
}
