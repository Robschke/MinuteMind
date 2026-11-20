// Purpose: AgentCockpitSpaces, which spaces (projects and General) the agent cockpit lists, which
//          ones its "+" menu offers, which space it shows, and which spaces the Cmd+T picker
//          lists for a query. Pure functions, no UI.
// Dependencies: Sources/App/Supporting/GlobalSearch.swift (nameRank, the Cmd+K name matching)
// Used by: Sources/App/ViewModels/AppViewModel+Cockpit.swift, Sources/App/Views/AgentCockpitPicker.swift,
//          Tests/AgentCockpitSpacesTests.swift
// Notes: The cockpit lists only spaces with a running Claude session, in the Home sidebar's
//        order (General first, then the user's arrangement), so a space keeps its place while
//        its agents change state; nothing reorders by status. Spaces without a session are
//        offered by the "+" menu in the same order. The picker matches names as Cmd+K does (start
//        of the name, then start of a word, then anywhere), ties kept in sidebar order.

import Foundation

enum AgentCockpitSpaces {
    /// The spaces of `order` that have a running Claude session, in that order.
    static func listed(order: [UUID], running: Set<UUID>) -> [UUID] {
        order.filter(running.contains)
    }

    /// The spaces of `order` without a running Claude session, for the "+" menu.
    static func addable(order: [UUID], running: Set<UUID>) -> [UUID] {
        order.filter { !running.contains($0) }
    }

    /// The space the cockpit shows: the chosen one while it is listed, else the first listed
    /// one, nil when nothing runs.
    static func shown(chosen: UUID?, listed: [UUID]) -> UUID? {
        if let chosen, listed.contains(chosen) { return chosen }
        return listed.first
    }

    /// The spaces whose name matches `query`, best match first, ties in `order`; all of them for
    /// an empty query.
    static func matching(_ query: String, order: [UUID], names: [UUID: String]) -> [UUID] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return order }
        return order.enumerated()
            .compactMap { offset, id -> (rank: Int, offset: Int, id: UUID)? in
                guard let name = names[id], let rank = GlobalSearch.nameRank(of: name, query: text) else { return nil }
                return (rank, offset, id)
            }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.id)
    }
}
