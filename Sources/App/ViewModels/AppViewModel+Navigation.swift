// Purpose: Navigation of the main window as one place (NavigationPlace): which place is shown,
//          going to a place, back and forward through the history, each project's remembered
//          section and the recently used projects for the Cmd+K switcher.
// Dependencies: Sources/App/Supporting/AppNavigation.swift (NavigationPlace, NavigationHistory,
//               ProjectSwitcherOrder), Sources/App/ViewModels/AppViewModel.swift (the navigation
//               flags, projectTabs, recentProjectIDs, navigationHistory, historyTarget),
//               Sources/App/Services/ProjectRepositoryService.swift (generalProjectID)
// Used by: Sources/App/Views/ContentView.swift (records visits, mouse back and forward, switcher),
//          Sources/App/Views/ProjectContextSidebar.swift, Sources/App/Views/HomeView.swift,
//          Sources/App/Views/ProjectDetailView.swift, Sources/App/Views/GeneralWorkspaceView.swift
// Notes: The page flags stay the source of truth: many places set them directly (sidebar,
//        companion, jobs, MCP), so `currentPlace` is derived from them and `go(to:)` sets them the
//        way the sidebar does. Visits are recorded by ContentView watching `currentPlace`, which
//        catches every way of navigating without touching those callers. A back or forward step
//        marks its target in `historyTarget`, so arriving there is not a new visit.
//        General has no Overview: its sections are Workspace and Jobs.

import Foundation

extension AppViewModel {
    nonisolated private static let projectTabsKey = "mm.projectTabs"
    nonisolated private static let recentProjectsKey = "mm.recentProjects"

    /// The page the main window shows, in the order ContentView decides it.
    var currentPlace: NavigationPlace {
        if isShowingInbox { return .inbox }
        if isShowingClipboard { return .clipboard }
        if isShowingAllTasks { return .allTasks }
        if isShowingCalendar { return .calendar }
        if let id = selectedProjectID, projectExists(id) { return .project(id, projectTab(for: id)) }
        if isShowingHome { return .home }
        return .allTranscripts
    }

    /// True for General and every existing project.
    func projectExists(_ id: UUID) -> Bool {
        id == ProjectRepositoryService.generalProjectID || projects.contains { $0.id == id }
    }

    /// The sections a project offers: General has no Overview.
    func projectTabs(of id: UUID) -> [ProjectTab] {
        id == ProjectRepositoryService.generalProjectID ? [.workspaces, .jobs] : ProjectTab.allCases
    }

    /// The project's remembered section; Workspace before the first visit.
    func projectTab(for id: UUID) -> ProjectTab {
        guard let tab = projectTabs[id], projectTabs(of: id).contains(tab) else { return .workspaces }
        return tab
    }

    func setProjectTab(_ tab: ProjectTab, for id: UUID) {
        guard projectTabs(of: id).contains(tab), projectTabs[id] != tab else { return }
        projectTabs[id] = tab
        let stored = Dictionary(uniqueKeysWithValues: projectTabs.map { ($0.key.uuidString, $0.value.rawValue) })
        UserDefaults.standard.set(stored, forKey: Self.projectTabsKey)
    }

    /// Applies `requestedProjectTab` to the selected project and clears it.
    func applyRequestedProjectTab() {
        guard let tab = requestedProjectTab else { return }
        if let id = selectedProjectID { setProjectTab(tab, for: id) }
        requestedProjectTab = nil
    }

    /// Shows `place`, setting the flags the way the sidebar does.
    func go(to place: NavigationPlace) {
        switch place {
        case .home:
            isShowingHome = true
        case .project(let id, let tab):
            clearPages()
            selectedProjectID = id
            setProjectTab(tab, for: id)
        case .allTranscripts:
            clearPages()
        case .inbox:
            clearPages()
            isShowingInbox = true
        case .allTasks:
            clearPages()
            isShowingAllTasks = true
        case .calendar:
            clearPages()
            isShowingCalendar = true
        case .clipboard:
            clearPages()
            isShowingClipboard = true
        }
    }

    /// Enters a project (or General) in its remembered section.
    func enterProject(_ id: UUID) {
        go(to: .project(id, projectTab(for: id)))
    }

    private func clearPages() {
        isShowingHome = false
        selectedProjectID = nil
        isShowingAllTasks = false
        isShowingCalendar = false
        isShowingInbox = false
        isShowingClipboard = false
    }

    /// Called whenever `currentPlace` changed: records the visit unless a back or forward step
    /// arrived, and moves a visited project to the front of the recent ones.
    func recordNavigation(from old: NavigationPlace, to new: NavigationPlace) {
        if let target = historyTarget {
            historyTarget = nil
            if target != new { navigationHistory.visit(from: old, to: new) }
        } else {
            navigationHistory.visit(from: old, to: new)
        }
        if let id = new.projectID, recentProjectIDs.first != id {
            recentProjectIDs = ProjectSwitcherOrder.touched(recentProjectIDs, id)
            UserDefaults.standard.set(recentProjectIDs.map(\.uuidString), forKey: Self.recentProjectsKey)
        }
    }

    func goBack() {
        let current = currentPlace
        guard let place = navigationHistory.goBack(from: current, isValid: isValidPlace) else { return }
        historyTarget = place
        go(to: place)
    }

    func goForward() {
        let current = currentPlace
        guard let place = navigationHistory.goForward(from: current, isValid: isValidPlace) else { return }
        historyTarget = place
        go(to: place)
    }

    private func isValidPlace(_ place: NavigationPlace) -> Bool {
        guard let id = place.projectID else { return true }
        return projectExists(id)
    }

    /// The Cmd+K switcher's entries: recently used first, then the rest in the sidebar's order
    /// (General first).
    var switcherProjectIDs: [UUID] {
        ProjectSwitcherOrder.items(
            recent: recentProjectIDs, all: [ProjectRepositoryService.generalProjectID] + projects.map(\.id))
    }

    nonisolated static func loadProjectTabs() -> [UUID: ProjectTab] {
        let stored = UserDefaults.standard.dictionary(forKey: projectTabsKey) as? [String: String] ?? [:]
        var tabs: [UUID: ProjectTab] = [:]
        for (key, value) in stored {
            if let id = UUID(uuidString: key), let tab = ProjectTab(rawValue: value) { tabs[id] = tab }
        }
        return tabs
    }

    nonisolated static func loadRecentProjects() -> [UUID] {
        (UserDefaults.standard.stringArray(forKey: recentProjectsKey) ?? []).compactMap(UUID.init(uuidString:))
    }
}
