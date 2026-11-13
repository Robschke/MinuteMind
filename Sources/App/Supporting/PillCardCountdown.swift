// Purpose: The rules that let the pill's timed cards (Claude session notices, the assistant's
//          Done card, the saved card) wait for the user without staying for good: when a hover
//          still counts, and the countdown of a Claude session notice.
// Dependencies: CoreGraphics only (pure, unit tested in Tests/PillCardCountdownTests.swift)
// Used by: Sources/App/Supporting/MeetingPillController.swift (showNotice, showAssistant,
//          runCountdown)
// Notes: SwiftUI sends no hover exit when a hovered card is swapped or removed under the pointer
//        (Show, Close or an answer clicked on a notice, a new notice replacing the old one), so
//        the pill's hover flag can stay true after the pointer left. A countdown that trusts the
//        flag then never runs and the card never goes. A hover therefore only counts while the
//        pointer really is over the card's panel or the companion.
//        A notice's other holds: a typed reply holds it for as long as it is there (closing
//        would lose the text); keyboard focus without a reply holds it at most `maxFocusHold`
//        seconds in total, since focus can linger after the user moved on.

import CoreGraphics

enum PillHover {
    /// Whether a hover flag still means the pointer is on the card: only while the pointer is
    /// inside one of `areas` (the panel's frame, the companion's frame).
    static func isReal(flag: Bool, pointer: CGPoint, areas: [CGRect]) -> Bool {
        flag && areas.contains { $0.contains(pointer) }
    }
}

/// The countdown of a Claude session notice beside the companion, ticked once a second.
struct NoticeCountdown: Equatable {
    /// Longest total time keyboard focus alone (no reply typed) keeps a notice up.
    static let maxFocusHold = 60

    private(set) var secondsLeft: Int
    private(set) var focusHeld = 0

    init(seconds: Int) {
        secondsLeft = seconds
    }

    /// One second passed. `hovering` must be a real hover (`PillHover.isReal`), `typing` is
    /// true while a reply is typed into the card, `focused` while the card has the keyboard.
    /// Returns true once the notice should close.
    mutating func tick(hovering: Bool, typing: Bool, focused: Bool) -> Bool {
        if hovering || typing { return false }
        if focused, focusHeld < Self.maxFocusHold {
            focusHeld += 1
            return false
        }
        secondsLeft -= 1
        return secondsLeft <= 0
    }
}
