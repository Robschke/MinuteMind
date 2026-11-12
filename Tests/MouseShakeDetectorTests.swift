// Purpose: Tests for the mouse shake that calls the desktop companion: a real shake fires once,
//          slow panning, small jitter and a single swipe do not.
// Dependencies: Sources/App/Supporting/MouseShakeDetector.swift

import CoreGraphics
import Foundation
import Testing

@testable import MinuteMindApp

@Suite("MouseShakeDetector Tests")
struct MouseShakeDetectorTests {
    /// Feeds a back-and-forth movement at 60 Hz: `amplitude` pt each way, `strokes` strokes of
    /// `strokeDuration` seconds; returns how often it fired.
    private func shakes(amplitude: CGFloat, strokes: Int, strokeDuration: TimeInterval) -> Int {
        var detector = MouseShakeDetector()
        var fired = 0
        let steps = Int(strokeDuration * 60)
        var time: TimeInterval = 0
        var x: CGFloat = 500
        for stroke in 0..<strokes {
            let sign: CGFloat = stroke.isMultiple(of: 2) ? 1 : -1
            for _ in 0..<steps {
                x += sign * amplitude / CGFloat(steps)
                time += 1.0 / 60
                if detector.add(x: x, at: time) { fired += 1 }
            }
        }
        return fired
    }

    @Test("A quick shake fires once, even when it goes on")
    func shakeFires() {
        #expect(shakes(amplitude: 120, strokes: 6, strokeDuration: 0.12) == 1)
        #expect(shakes(amplitude: 120, strokes: 14, strokeDuration: 0.1) == 1)
    }

    @Test("Slow panning back and forth is no shake")
    func slowPanning() {
        #expect(shakes(amplitude: 300, strokes: 8, strokeDuration: 0.6) == 0)
    }

    @Test("Small jitter is no shake")
    func jitter() {
        #expect(shakes(amplitude: 20, strokes: 20, strokeDuration: 0.05) == 0)
    }

    @Test("Three quick flips are enough, two are not")
    func flipCount() {
        #expect(shakes(amplitude: 150, strokes: 4, strokeDuration: 0.1) == 1)
        #expect(shakes(amplitude: 150, strokes: 3, strokeDuration: 0.1) == 0)
    }

    @Test("Strokes slower than a quarter second, like scrubbing a timeline, do not count")
    func scrubbing() {
        #expect(shakes(amplitude: 120, strokes: 8, strokeDuration: 0.3) == 0)
    }

    @Test("Long fast sweeps across the screen are no shake")
    func longSweeps() {
        #expect(shakes(amplitude: 900, strokes: 6, strokeDuration: 0.2) == 0)
    }
}
