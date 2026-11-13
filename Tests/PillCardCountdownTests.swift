// Purpose: Tests for the pill's timed cards: a hover flag only holds while the pointer is on the
//          card, a Claude session notice closes on time, waits for a real hover or a typed reply,
//          and keyboard focus alone holds it only for a while.
// Dependencies: Sources/App/Supporting/PillCardCountdown.swift

import CoreGraphics
import Testing

@testable import MinuteMindApp

@Suite("PillCardCountdown Tests")
struct PillCardCountdownTests {
    private let card = CGRect(x: 100, y: 100, width: 300, height: 120)
    private let creature = CGRect(x: 420, y: 100, width: 36, height: 48)

    // MARK: - Hover

    @Test func hoverCountsWhileThePointerIsOnTheCardOrTheCreature() {
        #expect(PillHover.isReal(flag: true, pointer: CGPoint(x: 150, y: 150), areas: [card, creature]))
        #expect(PillHover.isReal(flag: true, pointer: CGPoint(x: 430, y: 120), areas: [card, creature]))
    }

    @Test func aFlagLeftBehindByARemovedCardDoesNotCount() {
        // The card under the pointer went away (Show, Close), no hover exit came, the pointer moved on.
        #expect(!PillHover.isReal(flag: true, pointer: CGPoint(x: 900, y: 600), areas: [card, creature]))
        #expect(!PillHover.isReal(flag: true, pointer: CGPoint(x: 150, y: 150), areas: []))
    }

    @Test func noFlagNoHover() {
        #expect(!PillHover.isReal(flag: false, pointer: CGPoint(x: 150, y: 150), areas: [card]))
    }

    // MARK: - Notice countdown

    /// Ticks until the notice closes; nil when it is still up after `limit` seconds.
    private func secondsUntilClosed(
        _ countdown: inout NoticeCountdown, limit: Int = 1000,
        hovering: (Int) -> Bool = { _ in false }, typing: (Int) -> Bool = { _ in false },
        focused: (Int) -> Bool = { _ in false }
    ) -> Int? {
        for second in 1...limit
        where countdown.tick(hovering: hovering(second), typing: typing(second), focused: focused(second)) {
            return second
        }
        return nil
    }

    @Test func closesAfterItsSeconds() {
        var countdown = NoticeCountdown(seconds: 7)
        #expect(secondsUntilClosed(&countdown) == 7)
    }

    @Test func aRealHoverHoldsItAndLeavingResumes() {
        var countdown = NoticeCountdown(seconds: 7)
        // Hovered from second 3 to 102, then the pointer leaves.
        #expect(secondsUntilClosed(&countdown, hovering: { (3...102).contains($0) }) == 107)
    }

    @Test func aTypedReplyHoldsIt() {
        var countdown = NoticeCountdown(seconds: 30)
        #expect(secondsUntilClosed(&countdown, limit: 500, typing: { _ in true }) == nil)
    }

    @Test func focusAloneHoldsItOnlyForAWhile() {
        var countdown = NoticeCountdown(seconds: 30)
        #expect(secondsUntilClosed(&countdown, focused: { _ in true }) == NoticeCountdown.maxFocusHold + 30)
    }

    @Test func focusHoldIsCountedInTotal() {
        var countdown = NoticeCountdown(seconds: 100)
        // Focus comes and goes; the held seconds add up to the same cap.
        let closed = secondsUntilClosed(&countdown, focused: { $0 % 2 == 0 })
        #expect(closed == NoticeCountdown.maxFocusHold + 100)
    }
}
