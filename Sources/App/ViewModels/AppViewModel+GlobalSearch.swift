// Purpose: What the Cmd+K global search finds in the app and how a result is opened: pages,
//          Settings pages, main menu items, projects, Claude sessions, meetings with their
//          transcripts and summaries, and knowledge files from the existing FTS index.
// Dependencies: Sources/App/Supporting/GlobalSearch.swift (entries, meetings, results, snippets),
//               Sources/App/ViewModels/AppViewModel+Navigation.swift (go(to:), enterProject),
//               Sources/App/ViewModels/AppViewModel+AppControl.swift (show(.settings)),
//               Sources/App/ViewModels/AppViewModel+Companion.swift (revealTerminalSession),
//               Sources/App/Store/KnowledgeStore.swift (searchChunks),
//               Sources/App/Services/KnowledgeIndexer.swift (file(fromSource:)),
//               Sources/App/Supporting/WorkspaceEditorStore.swift (opening a knowledge file)
// Used by: Sources/App/Views/GlobalSearchView.swift
// Notes: Menu items are read from the main menu when the search opens, while the window's own
//        first responder is still in place, so only items that are enabled there are offered;
//        Services, alternates, hidden items and items with their own view are left out.
//        Knowledge results are limited to the workspace files (notes have no page of their own).
//        Summaries are read from disk off the main actor (`globalSearchSummaryFiles`), so the
//        search can open at once.

import AppKit
import Foundation

extension AppViewModel {
    // MARK: - What the search finds

    /// Everything found by its name: pages (and the open project's sections), Settings pages,
    /// projects, Claude sessions and main menu items.
    func globalSearchEntries() -> [GlobalSearchEntry] {
        var entries: [GlobalSearchEntry] = [
            .init(section: .places, title: "Home", subtitle: "Page", icon: "house", target: .place(.home)),
            .init(section: .places, title: "Inbox", subtitle: "Page", icon: "tray", target: .place(.inbox)),
            .init(section: .places, title: "All Transcripts", subtitle: "Page", icon: "doc.text", target: .place(.allTranscripts)),
            .init(section: .places, title: "All Tasks", subtitle: "Page", icon: "checklist", target: .place(.allTasks)),
            .init(section: .places, title: "Calendar", subtitle: "Page", icon: "calendar", target: .place(.calendar)),
            .init(section: .places, title: "Clipboard", subtitle: "Page", icon: "doc.on.clipboard", target: .place(.clipboard)),
        ]
        if let id = currentPlace.projectID {
            let name = globalSearchProjectName(id)
            for tab in projectTabs(of: id) {
                entries.append(.init(
                    section: .places, title: tab.rawValue, subtitle: name, icon: tab.icon,
                    target: .place(.project(id, tab))))
            }
        }
        for tab in MeetingMinutesSettingsView.Tab.allCases {
            entries.append(.init(
                section: .places, title: "\(tab.rawValue) Settings", subtitle: "Settings", icon: "gearshape",
                target: .settings(tab)))
        }
        let projectIDs = [ProjectRepositoryService.generalProjectID] + projects.sorted(by: Project.isOrderedBefore).map(\.id)
        for id in projectIDs {
            entries.append(.init(
                section: .projects, title: globalSearchProjectName(id), subtitle: "Project", icon: "folder",
                target: .project(id)))
        }
        for session in workspaceTerminals.claudeSessions {
            entries.append(.init(
                section: .agentSessions, title: session.displayName,
                subtitle: globalSearchProjectName(session.projectID), icon: "sparkle",
                target: .agentSession(session.id)))
        }
        entries.append(contentsOf: Self.mainMenuEntries())
        return entries
    }

    /// Every meeting and quick recording with its transcript; summaries are filled in later from
    /// `globalSearchSummaryFiles`.
    func globalSearchMeetings() -> [GlobalSearchMeeting] {
        sessions.map { session in
            let place = session.projectID.map(globalSearchProjectName)
                ?? (session.assignedToGeneral == true ? "General" : nil)
            let date = session.createdAt.formatted(date: .abbreviated, time: .shortened)
            return GlobalSearchMeeting(
                id: session.id, title: session.title,
                subtitle: [date, place].compactMap { $0 }.joined(separator: " \u{00B7} "),
                createdAt: session.createdAt, transcript: session.transcript?.text ?? "", summary: nil,
                hasSummary: session.meetingMinutesFileName != nil)
        }
    }

    /// The summary file of every meeting that has one.
    func globalSearchSummaryFiles() -> [UUID: URL] {
        var files: [UUID: URL] = [:]
        for session in sessions where session.meetingMinutesFileName != nil {
            if let url = minutesURL(for: session) { files[session.id] = url }
        }
        return files
    }

    /// Knowledge files matching `query` in the FTS index, one row per file.
    func globalSearchKnowledge(_ query: String) -> [GlobalSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= GlobalSearch.fullTextMinimumLength, let knowledgeStore,
              let hits = try? knowledgeStore.searchChunks(keyword: query) else { return [] }
        var seen: Set<String> = []
        var results: [GlobalSearchResult] = []
        for hit in hits {
            let source = hit.document.sourceMeetingTitle
            guard let file = KnowledgeIndexer.file(fromSource: source), seen.insert(source).inserted else { continue }
            let snippet = GlobalSearch.snippet(in: hit.chunk.content, matching: query)
            results.append(GlobalSearchResult(
                section: .knowledge, title: hit.document.title,
                subtitle: [globalSearchProjectName(file.repoID), snippet].filter { !$0.isEmpty }
                    .joined(separator: " \u{00B7} "),
                icon: "book.closed", target: .knowledgeFile(repoID: file.repoID, relativePath: file.relativePath)))
        }
        return results
    }

    private func globalSearchProjectName(_ id: UUID) -> String {
        if id == ProjectRepositoryService.generalProjectID { return "General" }
        return projects.first { $0.id == id }?.name ?? ""
    }

    // MARK: - Opening a result

    /// Opens what a result points to. A transcript is shown by the search's own sheet
    /// (GlobalSearchHost), so it is not handled here.
    func openGlobalSearchTarget(_ target: GlobalSearchTarget) {
        switch target {
        case .place(let place):
            go(to: place)
        case .settings(let tab):
            try? show(.settings(tab))
        case .menuItem(let path, let title):
            Self.performMainMenuItem(path: path, title: title)
        case .project(let id):
            if projectExists(id) { enterProject(id) }
        case .agentSession(let id):
            revealTerminalSession(id)
        case .summary(let sessionID):
            if let session = sessions.first(where: { $0.id == sessionID }) { openMinutes(session) }
        case .transcript:
            break
        case .knowledgeFile(let repoID, let relativePath):
            guard projectExists(repoID) else { return }
            let url = projectRepositories.repoURL(for: repoID).appendingPathComponent(relativePath)
            go(to: .project(repoID, .workspaces))
            workspaceEditors.state(for: repoID).open(url)
        }
    }

    // MARK: - Main menu

    /// The main menu's enabled commands, titled by their name and found under their menu path.
    private static func mainMenuEntries() -> [GlobalSearchEntry] {
        guard let menu = NSApp?.mainMenu else { return [] }
        var entries: [GlobalSearchEntry] = []
        collectMenuEntries(in: menu, path: [], titles: [], into: &entries)
        return entries
    }

    private static func collectMenuEntries(
        in menu: NSMenu, path: [Int], titles: [String], into entries: inout [GlobalSearchEntry]
    ) {
        if menu === NSApp.servicesMenu { return }
        menu.update()
        for (index, item) in menu.items.enumerated() {
            guard !item.isSeparatorItem, !item.isHidden, !item.isAlternate, item.view == nil else { continue }
            let title = item.title.trimmingCharacters(in: .whitespaces)
            if let submenu = item.submenu {
                // The top level's titles are the menu bar's names; the app menu's is the app name.
                collectMenuEntries(in: submenu, path: path + [index], titles: titles + [title], into: &entries)
                continue
            }
            guard !title.isEmpty, item.action != nil, item.isEnabled else { continue }
            entries.append(GlobalSearchEntry(
                section: .menu, title: title, subtitle: titles.filter { !$0.isEmpty }.joined(separator: " > "),
                icon: "filemenu.and.selection", target: .menuItem(path: path + [index], title: item.title)))
        }
    }

    /// Runs the menu item at `path` if it is still there under `title` and enabled.
    private static func performMainMenuItem(path: [Int], title: String) {
        guard var menu = NSApp?.mainMenu, let last = path.last else { return }
        for index in path.dropLast() {
            guard menu.items.indices.contains(index), let submenu = menu.items[index].submenu else { return }
            menu = submenu
        }
        menu.update()
        guard menu.items.indices.contains(last), menu.items[last].title == title, menu.items[last].isEnabled else { return }
        menu.performActionForItem(at: last)
    }
}
