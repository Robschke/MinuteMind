// Purpose: CompanionCast, who stands beside the desktop companion: one small creature
//          (sidekick) per project that has its own avatar and a running Claude session, and which
//          of them is in front, drawn big in the companion's place.
// Dependencies: Sources/App/Models/Project.swift (companionCreature, avatarColorHex),
//               Sources/App/Supporting/MascotAvatar.swift, Sources/App/Supporting/TerminalSessionStatus.swift
//               (pure otherwise, unit tested in Tests/CompanionCastTests.swift)
// Used by: Sources/App/Supporting/CompanionController.swift,
//          Sources/App/ViewModels/AppViewModel+Companion.swift (sessionToOpen)
// Notes: The user's request: one big creature in front, the projects' little companions beside
//        it showing what they do; one that needs the user comes to the front, a click on a small
//        one brings it there too. Decisions (with a design review):
//        - The home companion (the avatar from Settings) reports every session of a project
//          without an avatar, General and the projects beyond `maxSidekicks`.
//        - A project shows its worst status: error, then waiting, working, done, idle.
//        - Colours: a project creature takes the avatar colour picked in its project settings,
//          else its avatar's natural colour, so the user's own colour stays the home companion's.
//        - Only waiting and error bring a project forward, and only when the one in front is not
//          itself waiting or erring (the oldest request stays in front). Done never swaps: long
//          turns would make the cast churn.
//        - The home companion takes the front back while it has its own work (recording,
//          dictation, a meeting question, the voice assistant), when the front project's last
//          session closes, and `fallbackDelay` after the front project stopped needing the user
//          (a click on it counts as needing nothing more, so it stays that long after a click).
//        - A double click on a project creature opens the session its light stands for when it
//          needs the user (error, then waiting), else the one focused last (`sessionToOpen`).

import Foundation

struct CompanionCastMember: Equatable, Identifiable {
    /// nil: the home companion.
    let projectID: UUID?
    let avatar: MascotAvatar
    /// The project's avatar colour to draw the body in (`#RRGGBB`); nil: the avatar's natural
    /// colour, or for the home companion the colour from Settings.
    let colorHex: String?
    let name: String
    /// The worst status of its sessions; nil without sessions.
    var status: TerminalSessionStatus?

    var id: String { projectID?.uuidString ?? "home" }

    var needsUser: Bool { status == .waiting || status == .error }
}

enum CompanionCast {
    static let maxSidekicks = 5

    /// error > waiting > working > done > idle; nil for no sessions.
    static func worst(_ statuses: [TerminalSessionStatus]) -> TerminalSessionStatus? {
        statuses.max { rank($0) < rank($1) }
    }

    private static func rank(_ status: TerminalSessionStatus) -> Int {
        switch status {
        case .idle: 0
        case .done: 1
        case .working: 2
        case .waiting: 3
        case .error: 4
        }
    }

    /// The projects that get a creature: an avatar and at least one session, in `projects`'
    /// order (the sidebar's), at most `maxSidekicks`.
    static func projectMembers(
        projects: [Project], sessions: [(projectID: UUID, status: TerminalSessionStatus)]
    ) -> [CompanionCastMember] {
        var members: [CompanionCastMember] = []
        for project in projects {
            guard members.count < maxSidekicks, let avatar = project.companionCreature else { continue }
            let statuses = sessions.filter { $0.projectID == project.id }.map(\.status)
            guard !statuses.isEmpty else { continue }
            members.append(CompanionCastMember(
                projectID: project.id, avatar: avatar,
                colorHex: project.avatarColorHex,
                name: project.name, status: worst(statuses)))
        }
        return members
    }

    /// The creature a new project starts with: the first one no project and not the home
    /// companion wears; nil when every one is taken.
    static func firstFreeAvatar(used: Set<MascotAvatar>, homeAvatar: MascotAvatar) -> MascotAvatar? {
        MascotAvatar.allCases.first { $0 != homeAvatar && !used.contains($0) }
    }

    /// One of a project's Claude sessions, as `sessionToOpen` weighs it.
    struct SessionChoice: Equatable {
        let id: UUID
        let status: TerminalSessionStatus
        /// When the user last clicked into it this launch; nil: never.
        let lastFocused: Date?
        let number: Int
    }

    /// The session a double click on a project's creature opens: one that needs the user (an
    /// error before a waiting one, the oldest first), else the one focused last, else the oldest.
    static func sessionToOpen(_ choices: [SessionChoice]) -> UUID? {
        for status in [TerminalSessionStatus.error, .waiting] {
            if let first = choices.filter({ $0.status == status }).min(by: { $0.number < $1.number }) {
                return first.id
            }
        }
        let focused = choices.compactMap { choice in choice.lastFocused.map { (choice.id, $0) } }
            .max { $0.1 < $1.1 }
        return focused?.0 ?? choices.min { $0.number < $1.number }?.id
    }

    /// The home companion, reporting every session no project creature reports.
    static func homeMember(
        avatar: MascotAvatar, projectMembers: [CompanionCastMember],
        sessions: [(projectID: UUID, status: TerminalSessionStatus)]
    ) -> CompanionCastMember {
        let reported = Set(projectMembers.compactMap(\.projectID))
        let statuses = sessions.filter { !reported.contains($0.projectID) }.map(\.status)
        return CompanionCastMember(projectID: nil, avatar: avatar, colorHex: nil, name: "MinuteMind", status: worst(statuses))
    }
}

/// Which creature is in front (nil: the home companion), and when it goes back.
struct CompanionFront: Equatable {
    static let fallbackDelay: TimeInterval = 120

    private(set) var projectID: UUID?
    /// Since when the front project needs nothing from the user.
    private var calmSince: Date?

    /// A session of `id` started waiting or erred: it comes forward unless the one in front
    /// still needs the user, or the home companion is busy.
    mutating func promote(_ id: UUID, members: [CompanionCastMember], homeBusy: Bool) {
        guard !homeBusy, id != projectID else { return }
        if let current = projectID, members.first(where: { $0.projectID == current })?.needsUser == true { return }
        projectID = id
        calmSince = nil
    }

    /// A click on a sidekick (nil: the home companion).
    mutating func choose(_ id: UUID?, now: Date) {
        projectID = id
        calmSince = id == nil ? nil : now
    }

    /// Once a second: hands the front back to the home companion when it is due.
    mutating func update(members: [CompanionCastMember], homeBusy: Bool, now: Date) {
        guard let id = projectID else { return }
        guard !homeBusy, let member = members.first(where: { $0.projectID == id }) else {
            projectID = nil
            calmSince = nil
            return
        }
        if member.needsUser {
            calmSince = nil
            return
        }
        let since = calmSince ?? now
        calmSince = since
        if now.timeIntervalSince(since) >= Self.fallbackDelay {
            projectID = nil
            calmSince = nil
        }
    }
}
