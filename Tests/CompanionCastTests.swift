// Purpose: Tests for the desktop companion's cast: which projects get a creature, their colours
//          and statuses, and which creature is in front.
// Dependencies: Sources/App/Supporting/CompanionCast.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("CompanionCast Tests")
struct CompanionCastTests {
    private func project(_ name: String, _ avatar: MascotAvatar?, color: String? = nil) -> Project {
        var project = Project(name: name, avatarColorHex: color)
        project.companionAvatar = avatar?.rawValue
        return project
    }

    @Test("Worst status wins")
    func worstStatus() {
        #expect(CompanionCast.worst([.done, .working, .idle]) == .working)
        #expect(CompanionCast.worst([.waiting, .error]) == .error)
        #expect(CompanionCast.worst([]) == nil)
    }

    @Test("Only projects with an avatar and a session get a creature, in the given order")
    func members() {
        let duck = project("A", .duck), lime = project("B", .lime), none = project("C", nil), idle = project("D", .cat)
        let sessions: [(projectID: UUID, status: TerminalSessionStatus)] = [
            (lime.id, .waiting), (duck.id, .working), (none.id, .error), (duck.id, .done),
        ]
        let members = CompanionCast.projectMembers(projects: [duck, lime, none, idle], sessions: sessions)
        #expect(members.map(\.name) == ["A", "B"])
        #expect(members.map(\.status) == [.working, .waiting])
        // Natural colours for both.
        #expect(members.allSatisfy { $0.colorHex == nil })
        // The home companion reports the project without an avatar.
        let home = CompanionCast.homeMember(avatar: .blob, projectMembers: members, sessions: sessions)
        #expect(home.projectID == nil && home.status == .error)
    }

    @Test("A creature takes its project's avatar colour, else its natural one")
    func colours() {
        let blob = project("A", .blob, color: "#111111"), duck1 = project("B", .duck), duck2 = project("C", .duck, color: "#222222")
        let sessions = [blob, duck1, duck2].map { (projectID: $0.id, status: TerminalSessionStatus.idle) }
        let members = CompanionCast.projectMembers(projects: [blob, duck1, duck2], sessions: sessions)
        #expect(members.map(\.colorHex) == ["#111111", nil, "#222222"])
    }

    @Test("At most five project creatures; the rest is the home companion's")
    func cap() {
        let projects = (0..<7).map { project("P\($0)", .duck) }
        let sessions = projects.map { (projectID: $0.id, status: TerminalSessionStatus.waiting) }
        let members = CompanionCast.projectMembers(projects: projects, sessions: sessions)
        #expect(members.count == CompanionCast.maxSidekicks)
        #expect(CompanionCast.homeMember(avatar: .blob, projectMembers: members, sessions: sessions).status == .waiting)
    }

    private func member(_ id: UUID, _ status: TerminalSessionStatus?) -> CompanionCastMember {
        CompanionCastMember(projectID: id, avatar: .duck, colorHex: nil, name: "", status: status)
    }

    @Test("A waiting project comes forward unless the front one still waits or home is busy")
    func promotion() {
        let a = UUID(), b = UUID()
        var front = CompanionFront()
        front.promote(a, members: [member(a, .waiting)], homeBusy: true)
        #expect(front.projectID == nil)
        front.promote(a, members: [member(a, .waiting)], homeBusy: false)
        #expect(front.projectID == a)
        front.promote(b, members: [member(a, .waiting), member(b, .error)], homeBusy: false)
        #expect(front.projectID == a)
        front.promote(b, members: [member(a, .working), member(b, .error)], homeBusy: false)
        #expect(front.projectID == b)
    }

    @Test("The front goes back home: busy, session gone, or calm for two minutes")
    func fallback() {
        let a = UUID()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var front = CompanionFront()
        front.choose(a, now: start)
        front.update(members: [member(a, .working)], homeBusy: false, now: start.addingTimeInterval(60))
        #expect(front.projectID == a)
        front.update(members: [member(a, .working)], homeBusy: false, now: start.addingTimeInterval(121))
        #expect(front.projectID == nil)

        front.choose(a, now: start)
        front.update(members: [member(a, .waiting)], homeBusy: false, now: start.addingTimeInterval(500))
        #expect(front.projectID == a)
        front.update(members: [], homeBusy: false, now: start.addingTimeInterval(501))
        #expect(front.projectID == nil)

        front.choose(a, now: start)
        front.update(members: [member(a, .waiting)], homeBusy: true, now: start)
        #expect(front.projectID == nil)
    }

    // MARK: - Double click

    private func choice(_ number: Int, _ status: TerminalSessionStatus, focused: TimeInterval? = nil) -> CompanionCast.SessionChoice {
        CompanionCast.SessionChoice(
            id: UUID(), status: status,
            lastFocused: focused.map { Date(timeIntervalSinceReferenceDate: $0) }, number: number)
    }

    @Test("A double click opens the session that needs the user, an error before a waiting one")
    func doubleClickPrefersNeeds() {
        let done = choice(1, .done, focused: 100), waiting = choice(2, .waiting), error = choice(3, .error)
        #expect(CompanionCast.sessionToOpen([done, waiting, error]) == error.id)
        #expect(CompanionCast.sessionToOpen([done, waiting]) == waiting.id)
        let olderWaiting = choice(0, .waiting)
        #expect(CompanionCast.sessionToOpen([waiting, olderWaiting]) == olderWaiting.id)
    }

    @Test("Without a need it opens the session focused last, else the oldest")
    func doubleClickFallsBackToFocus() {
        let first = choice(1, .working), second = choice(2, .done, focused: 50), third = choice(3, .idle, focused: 80)
        #expect(CompanionCast.sessionToOpen([first, second, third]) == third.id)
        #expect(CompanionCast.sessionToOpen([choice(4, .idle), first]) == first.id)
        #expect(CompanionCast.sessionToOpen([]) == nil)
    }

    @Test("A new project starts with the first creature nobody wears")
    func firstFreeAvatar() {
        #expect(CompanionCast.firstFreeAvatar(used: [], homeAvatar: .blob) == .duck)
        #expect(CompanionCast.firstFreeAvatar(used: [.duck, .dog], homeAvatar: .blob) == .puppy)
        #expect(CompanionCast.firstFreeAvatar(used: Set(MascotAvatar.allCases), homeAvatar: .blob) == nil)
    }
}
