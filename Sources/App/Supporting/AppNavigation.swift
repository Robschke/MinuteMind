// Purpose: Where the main window is (NavigationPlace), the browser-like back and forward history
//          between places (NavigationHistory) and the order and stepping of the Cmd+K project
//          switcher (ProjectSwitcherOrder). Pure value types, no UI.
// Dependencies: Sources/App/Views/ProjectDetailView.swift (ProjectTab)
// Used by: Sources/App/ViewModels/AppViewModel+Navigation.swift (current place, history, recent
//          projects), Sources/App/Views/ProjectSwitcherView.swift (switcher stepping),
//          Tests/AppNavigationTests.swift
// Notes: A place includes the project's section (Overview, Workspace, Jobs), so switching sections
//        inside a project is a step back like switching pages. The history drops places that no
//        longer exist (a deleted project) when it walks over them instead of when they disappear,
//        so it needs no hook into project deletion. The switcher lists only starred projects and
//        projects with a running Claude session, so it stays short; the others are opened from
//        Home or the sidebar. It lists them most recently used first, like the app switcher:
//        inside a project the current one leads and the highlight starts on the one before it, so
//        a single press goes back to the previous one.

import Foundation

/// One page of the main window.
enum NavigationPlace: Hashable, Sendable {
    case home
    case inbox
    case allTranscripts
    case allTasks
    case calendar
    case clipboard
    /// A project (or General) and its section.
    case project(UUID, ProjectTab)

    var projectID: UUID? {
        if case .project(let id, _) = self { return id }
        return nil
    }
}

/// Back and forward stacks of places, newest last.
struct NavigationHistory: Equatable, Sendable {
    private(set) var back: [NavigationPlace] = []
    private(set) var forward: [NavigationPlace] = []

    /// How many places each stack keeps.
    static let limit = 50

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// The user went from `old` to somewhere new: `old` becomes the way back and the forward
    /// stack is gone, as in a browser.
    mutating func visit(from old: NavigationPlace, to new: NavigationPlace) {
        guard old != new else { return }
        if back.last != old { back.append(old) }
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
    }

    /// The place to go back to from `current`, skipping places `isValid` rejects; `current`
    /// becomes the way forward. nil when there is nothing (valid) behind.
    mutating func goBack(from current: NavigationPlace, isValid: (NavigationPlace) -> Bool) -> NavigationPlace? {
        while let place = back.popLast() {
            guard isValid(place), place != current else { continue }
            forward.append(current)
            if forward.count > Self.limit { forward.removeFirst(forward.count - Self.limit) }
            return place
        }
        return nil
    }

    /// The mirror of `goBack`.
    mutating func goForward(from current: NavigationPlace, isValid: (NavigationPlace) -> Bool) -> NavigationPlace? {
        while let place = forward.popLast() {
            guard isValid(place), place != current else { continue }
            back.append(current)
            if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
            return place
        }
        return nil
    }
}

/// Order and stepping of the Cmd+K switcher.
enum ProjectSwitcherOrder {
    /// How many recently used projects are remembered.
    static let recentLimit = 30

    /// `recent` after visiting `id`: it moves to the front.
    static func touched(_ recent: [UUID], _ id: UUID) -> [UUID] {
        Array(([id] + recent.filter { $0 != id }).prefix(recentLimit))
    }

    /// The switcher's entries: of the projects in `all` that `shown` holds (starred or with a
    /// running Claude session), the recently used ones first, most recent first, then the rest in
    /// `all`'s order (the sidebar's).
    static func items(recent: [UUID], all: [UUID], shown: Set<UUID>) -> [UUID] {
        let listed = all.filter { shown.contains($0) }
        let known = Set(listed)
        let used = recent.filter { known.contains($0) }
        let usedSet = Set(used)
        return used + listed.filter { !usedSet.contains($0) }
    }

    /// Where the highlight starts: on the previous project when the current one leads the list,
    /// else on the first entry.
    static func startIndex(items: [UUID], current: UUID?) -> Int {
        guard !items.isEmpty else { return 0 }
        if let current, items.first == current, items.count > 1 { return 1 }
        return 0
    }

    /// `index` moved by `step`, wrapping around.
    static func stepped(_ index: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + step) % count + count) % count
    }
}
