// Purpose: Tests for the sidebar's Recently used order: starred first, then projects with an open
//          Claude session by opening time, then by last use, never-used ones in the manual order;
//          plus storing the setting and the session times.
// Dependencies: Sources/App/Models/ProjectSidebarOrder.swift, Sources/App/Models/Project.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("ProjectSidebarOrder Tests")
struct ProjectSidebarOrderTests {

    private func project(_ name: String, starred: Bool = false) -> Project {
        var project = Project(name: name)
        project.isStarred = starred ? true : nil
        return project
    }

    private func at(_ minutes: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + minutes * 60)
    }

    private func names(_ projects: [Project]) -> [String] { projects.map(\.name) }

    @Test func openSessionsComeFirstByOpeningTime() {
        let a = project("A"), b = project("B"), c = project("C")
        let activity = [
            a.id: ProjectAgentActivity(openedAt: at(10)),
            b.id: ProjectAgentActivity(openedAt: at(20)),
            c.id: ProjectAgentActivity(openedAt: at(5), closedAt: at(30)),
        ]
        let order = ProjectSidebarOrder.recentlyUsed([a, b, c], activity: activity, open: [a.id, b.id])
        // C closed most recently, but open projects stay above it.
        #expect(names(order) == ["B", "A", "C"])
    }

    @Test func closedProjectsSortByLastUse() {
        let a = project("A"), b = project("B")
        let activity = [
            a.id: ProjectAgentActivity(openedAt: at(1), closedAt: at(40)),
            b.id: ProjectAgentActivity(openedAt: at(30), closedAt: at(35)),
        ]
        let order = ProjectSidebarOrder.recentlyUsed([b, a], activity: activity, open: [])
        #expect(names(order) == ["A", "B"])
    }

    @Test func neverUsedKeepTheManualOrderAtTheBottom() {
        let x = project("X"), y = project("Y"), used = project("Used")
        let activity = [used.id: ProjectAgentActivity(openedAt: at(1), closedAt: at(2))]
        let order = ProjectSidebarOrder.recentlyUsed([x, y, used], activity: activity, open: [])
        #expect(names(order) == ["Used", "X", "Y"])
    }

    @Test func starredLeadAndSortTheSameWayAmongThemselves() {
        let plainOpen = project("PlainOpen")
        let starIdle = project("StarIdle", starred: true)
        let starOpen = project("StarOpen", starred: true)
        let starNever = project("StarNever", starred: true)
        let activity = [
            plainOpen.id: ProjectAgentActivity(openedAt: at(50)),
            starIdle.id: ProjectAgentActivity(openedAt: at(1), closedAt: at(2)),
            starOpen.id: ProjectAgentActivity(openedAt: at(3)),
        ]
        let order = ProjectSidebarOrder.recentlyUsed(
            [plainOpen, starNever, starIdle, starOpen], activity: activity, open: [plainOpen.id, starOpen.id])
        #expect(names(order) == ["StarOpen", "StarIdle", "StarNever", "PlainOpen"])
    }

    @Test func settingAndTimesRoundTrip() throws {
        let suite = "ProjectSidebarOrderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ProjectSidebarSort.load(from: defaults) == .manual)
        defaults.set(ProjectSidebarSort.recentlyUsed.rawValue, forKey: ProjectSidebarSort.storageKey)
        #expect(ProjectSidebarSort.load(from: defaults) == .recentlyUsed)

        let id = UUID()
        let activity = [id: ProjectAgentActivity(openedAt: at(1), closedAt: at(2))]
        ProjectAgentActivity.saveAll(activity, to: defaults)
        #expect(ProjectAgentActivity.loadAll(from: defaults) == activity)
    }
}
