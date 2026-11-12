// Purpose: ProjectWheel, picking the running recording's project by scrolling over the desktop
//          companion: the list of projects and where the selection stands, turned by mouse wheel
//          notches or trackpad swipes. Pure state, no timing or UI.
// Dependencies: Foundation (CoreGraphics types)
// Used by: Sources/App/Supporting/CompanionController.swift (feeds scroll events, commits),
//          Sources/App/Supporting/MeetingPillController.swift (ProjectWheelCard shows it)
// Notes: A mouse wheel sends one event per notch: one step each, whatever its size, so a fast spin
//        does not jump. A trackpad sends a stream of small precise deltas: they add up and every
//        `trackpadStep` points is one step; momentum (the glide after the fingers lift) is
//        ignored, so the selection stops where the fingers stop. Scrolling the content up (wheel
//        towards the user, or fingers up with natural scrolling) moves down the list, like
//        scrolling any list. The list wraps around.

import CoreGraphics
import Foundation
import SwiftUI

struct ProjectWheel: Equatable {
    struct Item: Equatable, Identifiable {
        /// Nil for "No Project" and "Later".
        var projectID: UUID?
        var name: String
        var colorHex: String?
        /// "Later": the saved card's question is put off to the Inbox.
        var isLater = false
        /// Starred in the sidebar: shows the companion's avatar in the row.
        var isStarred = false
        /// The starred mark's creature and colour (the project's own; nil: the home companion).
        var markAvatar: MascotAvatar? = nil
        var markColor: Color? = nil

        var id: String { isLater ? "later" : projectID?.uuidString ?? "none" }
    }

    /// Trackpad travel in points for one step.
    static let trackpadStep: CGFloat = 28

    let items: [Item]
    private(set) var index: Int
    let startProjectID: UUID?
    private var accumulated: CGFloat = 0

    init(items: [Item], selected projectID: UUID?) {
        self.items = items
        index = items.firstIndex { $0.projectID == projectID && !$0.isLater }
            ?? items.firstIndex { $0.projectID == projectID } ?? 0
        startProjectID = items.indices.contains(index) ? items[index].projectID : nil
    }

    var selected: Item? { items.indices.contains(index) ? items[index] : nil }

    /// Where the list started: the recording's project before scrolling. -1 when it had none
    /// (then nothing is marked "current", not even Later).
    var startIndex: Int { items.firstIndex { $0.projectID == startProjectID && !$0.isLater } ?? -1 }

    /// Jumps to an entry (a click on its row).
    mutating func select(_ newIndex: Int) {
        guard items.indices.contains(newIndex) else { return }
        index = newIndex
        accumulated = 0
    }

    /// Applies one scroll event. Returns true when the selection moved.
    mutating func scroll(deltaY: CGFloat, precise: Bool, momentum: Bool, began: Bool = false) -> Bool {
        guard !items.isEmpty, !momentum else { return false }
        let steps: Int
        if precise {
            if began { accumulated = 0 }
            accumulated += deltaY
            let whole = Int(accumulated / Self.trackpadStep)
            accumulated -= CGFloat(whole) * Self.trackpadStep
            steps = whole
        } else {
            steps = deltaY > 0 ? 1 : deltaY < 0 ? -1 : 0
        }
        guard steps != 0 else { return false }
        // Positive deltas scroll the content down, which shows earlier rows: move up the list.
        index = ((index - steps) % items.count + items.count) % items.count
        return true
    }
}
