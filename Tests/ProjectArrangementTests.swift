// Purpose: Tests for arranging projects in the sidebar: where a dragged row lands, how the order
//          moves, and how saved orders sort (never-arranged projects first, newest on top).
// Dependencies: Sources/App/Views/ProjectSidebarArranging.swift, Sources/App/Models/Project.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("ProjectArrangement Tests")
struct ProjectArrangementTests {

    @Test func targetMovesByWholeRows() {
        #expect(ProjectArrangement.targetIndex(start: 2, translation: 0, pitch: 34, count: 5) == 2)
        #expect(ProjectArrangement.targetIndex(start: 2, translation: 16, pitch: 34, count: 5) == 2)
        #expect(ProjectArrangement.targetIndex(start: 2, translation: 18, pitch: 34, count: 5) == 3)
        #expect(ProjectArrangement.targetIndex(start: 2, translation: -70, pitch: 34, count: 5) == 0)
    }

    @Test func targetStaysInsideTheList() {
        #expect(ProjectArrangement.targetIndex(start: 0, translation: -500, pitch: 34, count: 5) == 0)
        #expect(ProjectArrangement.targetIndex(start: 4, translation: 500, pitch: 34, count: 5) == 4)
    }

    @Test func movedReordersOneElement() {
        let ids = (0..<4).map { _ in UUID() }
        #expect(ProjectArrangement.moved(ids, from: 0, to: 2) == [ids[1], ids[2], ids[0], ids[3]])
        #expect(ProjectArrangement.moved(ids, from: 3, to: 0) == [ids[3], ids[0], ids[1], ids[2]])
        #expect(ProjectArrangement.moved(ids, from: 1, to: 9) == ids)
    }

    @Test func neverArrangedProjectsComeFirstNewestOnTop() {
        let old = Date(timeIntervalSince1970: 0)
        var arrangedA = Project(name: "A", createdAt: old)
        arrangedA.sortOrder = 1
        var arrangedB = Project(name: "B", createdAt: old)
        arrangedB.sortOrder = 0
        let newer = Project(name: "New", createdAt: Date(timeIntervalSince1970: 200))
        let new = Project(name: "Older new", createdAt: Date(timeIntervalSince1970: 100))
        let sorted = [arrangedA, new, arrangedB, newer].sorted(by: Project.isOrderedBefore)
        #expect(sorted.map(\.name) == ["New", "Older new", "B", "A"])
    }

    @Test func savedProjectsWithoutSortOrderStillDecode() throws {
        let json = ##"[{"id":"\##(UUID().uuidString)","name":"Acme","colorHex":"#007AFF","createdAt":0,"updatedAt":0}]"##
        let projects = try JSONDecoder().decode([Project].self, from: Data(json.utf8))
        #expect(projects.first?.sortOrder == nil)
    }
}
