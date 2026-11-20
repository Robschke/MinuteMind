// Purpose: AgentCockpitSpaces, which spaces (projects and General) the agent cockpit lists, which
//          ones its "+" menu offers, and which space it shows. Pure functions, no UI.
// Dependencies: none
// Used by: Sources/App/ViewModels/AppViewModel+Cockpit.swift, Tests/AgentCockpitSpacesTests.swift
// Notes: The cockpit lists only spaces with a running Claude session, in the Home sidebar's
//        order (General first, then the user's arrangement), so a space keeps its place while
//        its agents change state; nothing reorders by status. Spaces without a session are
//        offered by the "+" menu in the same order.

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
}
