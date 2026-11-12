// Purpose: Tests for the saved card's publish question in Shared Projects: only a Shared Project
//          asks, a Private one or General keeps "Filed to X", no answer means private, a new pick
//          replaces the question, and with automatic processing off the answer leads to Process Now.
// Dependencies: Sources/App/Supporting/SharedPublishCard.swift,
//               Sources/App/Supporting/MeetingPillController.swift (MeetingPillModel.SavedNext)

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("SharedPublishCard Tests")
@MainActor
struct SharedPublishCardTests {
    private typealias Next = MeetingPillModel.SavedNext

    private let all: [ProjectWheel.Item] = [
        .init(projectID: UUID(), name: "Acme"),
        .init(projectID: UUID(), name: "Beta"),
        .init(projectID: ProjectRepositoryService.generalProjectID, name: "General"),
    ]

    private var choosing: Next { .chooseProject(quick: Array(all.prefix(2)), all: all, processes: true) }

    // MARK: - Right after the recording stopped

    @Test func filedToASharedProjectAsksWithChange() {
        let next = Next.filed(project: "Acme", all: all).askingToPublish(sharedProject: "Acme")
        #expect(next == .publish(project: "Acme", alreadyFiled: true, all: all, processes: true))
        #expect(next.hint == "Filed to Acme")
        #expect(next.waitsForAnswer)
        #expect(!next.asksForProject)
    }

    @Test func filedToAPrivateProjectStaysAsItIs() {
        let filed = Next.filed(project: "Acme", all: all)
        #expect(filed.askingToPublish(sharedProject: nil) == filed)
        #expect(filed.hint == "Filed to Acme, summary follows")
        #expect(!filed.waitsForAnswer)
    }

    @Test func withoutAProjectItAsksWhichOneFirst() {
        #expect(choosing.askingToPublish(sharedProject: "Acme") == choosing)
    }

    @Test func processingOffStillAsksAndThenOffersProcessNow() {
        let next = Next.manual.askingToPublish(sharedProject: "Acme")
        #expect(next == .publish(project: "Acme", alreadyFiled: true, all: [], processes: false))
        #expect(next.afterPublishAnswer == .manual)
    }

    // MARK: - Picking on the card

    @Test func pickingASharedProjectTurnsTheCardIntoTheQuestion() {
        let next = choosing.picking("Acme", shared: true)
        #expect(next == .publish(project: "Acme", alreadyFiled: false, all: all, processes: true))
        #expect(next.hint == "Share with the Acme team?")
        #expect(next.afterPublishAnswer == nil)
    }

    @Test func pickingAPrivateProjectOrGeneralShowsFiledUnchanged() {
        #expect(choosing.picking("Beta", shared: false) == .filed(project: "Beta", all: all))
        #expect(choosing.picking("General", shared: false) == .filed(project: "General", all: all))
        let manual = Next.chooseProject(quick: [], all: all, processes: false)
        #expect(manual.picking("Beta", shared: false) == .manual)
    }

    @Test func changeToAnotherProjectResetsTheQuestion() {
        let asking = Next.filed(project: "Acme", all: all).askingToPublish(sharedProject: "Acme")
        // Another Shared Project asks again, about that project.
        #expect(asking.picking("Beta", shared: true) == .publish(project: "Beta", alreadyFiled: false, all: all, processes: true))
        // A Private project drops the question.
        let toPrivate = asking.picking("Beta", shared: false)
        #expect(toPrivate == .filed(project: "Beta", all: all))
        #expect(toPrivate.unansweredPublication == nil)
        // Processing off is kept through the change.
        let manualAsking = Next.manual.askingToPublish(sharedProject: "Acme")
        #expect(manualAsking.picking("Beta", shared: true).afterPublishAnswer == .manual)
        #expect(manualAsking.picking("Beta", shared: false) == .manual)
    }

    // MARK: - No answer

    @Test func noAnswerMeansKeepPrivate() {
        #expect(choosing.picking("Acme", shared: true).unansweredPublication == .keptPrivate)
        #expect(Next.manual.askingToPublish(sharedProject: "Acme").unansweredPublication == .keptPrivate)
    }

    @Test func cardsWithoutTheQuestionRecordNothing() {
        #expect(choosing.unansweredPublication == nil)
        #expect(Next.filed(project: "Acme", all: all).unansweredPublication == nil)
        #expect(Next.manual.unansweredPublication == nil)
        #expect(Next.manual.afterPublishAnswer == nil)
    }
}
