// Purpose: Tests the rules of the inline task title edit: which title is stored and which task
//          is edited next after Return, Tab, Shift-Tab, Esc or a click elsewhere.
// Dependencies: Sources/App/Components/InlineTaskTitleField.swift (InlineTaskTitleEditing)

import Foundation
import Testing

@testable import MinuteMindApp

struct InlineTaskTitleEditingTests {
    private let ids = [UUID(), UUID(), UUID()]

    @Test func tabMovesToTheNextTaskAndStopsAfterTheLast() {
        #expect(InlineTaskTitleEditing.nextTaskID(after: ids[0], end: .saveAndNext, order: ids) == ids[1])
        #expect(InlineTaskTitleEditing.nextTaskID(after: ids[2], end: .saveAndNext, order: ids) == nil)
    }

    @Test func shiftTabMovesToThePreviousTaskAndStopsAtTheFirst() {
        #expect(InlineTaskTitleEditing.nextTaskID(after: ids[2], end: .saveAndPrevious, order: ids) == ids[1])
        #expect(InlineTaskTitleEditing.nextTaskID(after: ids[0], end: .saveAndPrevious, order: ids) == nil)
    }

    @Test func returnAndEscapeStopEditing() {
        #expect(InlineTaskTitleEditing.nextTaskID(after: ids[1], end: .save, order: ids) == nil)
        #expect(InlineTaskTitleEditing.nextTaskID(after: ids[1], end: .cancel, order: ids) == nil)
    }

    @Test func aTaskNoLongerShownStopsEditing() {
        #expect(InlineTaskTitleEditing.nextTaskID(after: UUID(), end: .saveAndNext, order: ids) == nil)
    }

    @Test func savesTheTrimmedDraft() {
        #expect(InlineTaskTitleEditing.titleToSave(draft: "  New title ", current: "Old", end: .save) == "New title")
        #expect(InlineTaskTitleEditing.titleToSave(draft: "New", current: "Old", end: .saveAndNext) == "New")
    }

    @Test func keepsTheTitleWhenCancelledUnchangedOrEmpty() {
        #expect(InlineTaskTitleEditing.titleToSave(draft: "New", current: "Old", end: .cancel) == nil)
        #expect(InlineTaskTitleEditing.titleToSave(draft: "Old ", current: "Old", end: .save) == nil)
        #expect(InlineTaskTitleEditing.titleToSave(draft: "   ", current: "Old", end: .save) == nil)
    }
}
