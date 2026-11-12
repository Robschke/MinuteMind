// Purpose: Arranging projects in the sidebar, Home Screen style: a long press makes the project
//          rows wiggle, then they can be dragged into a new order. Holds the order maths and the
//          wiggle; the gesture and the state live in ProjectsSidebarView.
// Dependencies: Sources/App/Models/Project.swift (sortOrder)
// Used by: Sources/App/Views/ProjectsSidebarView.swift
// Notes: The wiggle is computed from the clock in a TimelineView rather than a repeatForever
//        animation: repeatForever animations do not reliably stop, and a TimelineView that is
//        paused costs nothing. It stays in the view tree when inactive (paused, amplitude 0) so
//        the row keeps its identity and a press that starts arranging is not cut off.
//        Rows are long and thin, so the rotation is small (under half a degree) and slower than
//        on the Home Screen, or the text shimmers; each row gets its own phase and a slightly
//        different rate so they never move in step.

import SwiftUI

enum ProjectArrangement {
    /// The slot a dragged row lands in: its start slot moved by whole rows of `translation`.
    static func targetIndex(start: Int, translation: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard count > 0, pitch > 0 else { return start }
        let shift = Int((translation / pitch).rounded())
        return min(max(start + shift, 0), count - 1)
    }

    /// `ids` with the element at `from` moved to `to`.
    static func moved(_ ids: [UUID], from: Int, to: Int) -> [UUID] {
        guard ids.indices.contains(from), ids.indices.contains(to), from != to else { return ids }
        var result = ids
        let id = result.remove(at: from)
        result.insert(id, at: to)
        return result
    }
}

/// The Home Screen wiggle while projects are being arranged. No motion with Reduce Motion on.
struct ArrangeWiggle: ViewModifier {
    let active: Bool
    /// Varies phase and rate per row.
    let seed: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let degrees = 0.45
    private static let bob: CGFloat = 0.5

    func body(content: Content) -> some View {
        let moving = active && !reduceMotion
        TimelineView(.animation(minimumInterval: nil, paused: !moving)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let rate = 2.8 + Double(seed % 5) * 0.15
            let phase = Double(seed) * 1.7
            let wave = moving ? sin(time * 2 * .pi * rate + phase) : 0
            content
                .rotationEffect(.degrees(wave * Self.degrees))
                .offset(y: moving ? CGFloat(cos(time * 2 * .pi * rate + phase)) * Self.bob : 0)
        }
    }
}
