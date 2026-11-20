// Purpose: The two orders of the Home sidebar's project list: the user's own (Manual order) and
//          Recently used, which follows the projects' Claude sessions. Holds the setting, the
//          per-project session times and the pure ordering.
// Dependencies: Sources/App/Models/Project.swift (isStarred, the manual order of the list)
// Used by: Sources/App/ViewModels/AppViewModel+ProjectAgentActivity.swift (records the times,
//          applies the order), Sources/App/Views/ProjectsSidebarView.swift,
//          Sources/App/Views/AppearanceSettingsView.swift, Sources/App/Help/AppSettingsCatalog.swift,
//          Tests/ProjectSidebarOrderTests.swift
// Notes: Recently used: starred projects first, then (within the starred and the others alike)
//        projects with an open Claude session, by when their newest session was opened; then the
//        rest by when their last session closed; projects that never had one last, in the manual
//        order. A session counts as open while its Claude tab exists, whatever it is doing.
//        Ordering open projects by their opening time rather than "now" keeps the list stable:
//        several open projects would otherwise tie and swap places on every refresh.
//        The times live in UserDefaults (`mm.projectAgentActivity`), not in projects.json: they
//        are this Mac's usage, not project data, and sessions do not survive a relaunch anyway.

import Foundation

/// How the Home sidebar orders the projects (Settings > Appearance > Sidebar).
enum ProjectSidebarSort: String, CaseIterable, Identifiable {
    /// The order the user dragged the projects into.
    case manual
    /// Starred first, then by the projects' Claude sessions (see the file header).
    case recentlyUsed

    static let storageKey = "mm.projectSidebarSort"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: "Manual order"
        case .recentlyUsed: "Recently used"
        }
    }

    /// The stored choice; Manual order when none is stored.
    static func load(from defaults: UserDefaults = .standard) -> ProjectSidebarSort {
        defaults.string(forKey: storageKey).flatMap(ProjectSidebarSort.init(rawValue:)) ?? .manual
    }
}

/// When a project's Claude sessions were last opened and closed.
struct ProjectAgentActivity: Codable, Equatable {
    /// When its newest Claude session was opened.
    var openedAt: Date?
    /// When its last open Claude session closed (or the app quit with one open).
    var closedAt: Date?

    /// The later of both: when the project was last seen with a session.
    var lastUsed: Date? { [openedAt, closedAt].compactMap { $0 }.max() }

    static let storageKey = "mm.projectAgentActivity"

    static func loadAll(from defaults: UserDefaults = .standard) -> [UUID: ProjectAgentActivity] {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([String: ProjectAgentActivity].self, from: data)
        else { return [:] }
        var result: [UUID: ProjectAgentActivity] = [:]
        for (key, value) in stored {
            if let id = UUID(uuidString: key) { result[id] = value }
        }
        return result
    }

    static func saveAll(_ activity: [UUID: ProjectAgentActivity], to defaults: UserDefaults = .standard) {
        let stored = Dictionary(uniqueKeysWithValues: activity.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

enum ProjectSidebarOrder {
    /// `projects` (in the manual order) sorted for Recently used; `open` holds the projects with
    /// an open Claude session right now.
    static func recentlyUsed(
        _ projects: [Project], activity: [UUID: ProjectAgentActivity], open: Set<UUID>
    ) -> [Project] {
        struct Key {
            let starred: Bool
            /// 0 open session, 1 had one, 2 never.
            let group: Int
            let time: Date
            let manualIndex: Int
        }
        let keyed = projects.enumerated().map { index, project in
            let record = activity[project.id]
            let group: Int
            let time: Date
            if open.contains(project.id) {
                group = 0
                time = record?.openedAt ?? .distantPast
            } else if let lastUsed = record?.lastUsed {
                group = 1
                time = lastUsed
            } else {
                group = 2
                time = .distantPast
            }
            return (project, Key(starred: project.isStarred == true, group: group, time: time, manualIndex: index))
        }
        return keyed.sorted { lhs, rhs in
            let a = lhs.1, b = rhs.1
            if a.starred != b.starred { return a.starred }
            if a.group != b.group { return a.group < b.group }
            if a.time != b.time { return a.time > b.time }
            return a.manualIndex < b.manualIndex
        }.map(\.0)
    }
}
