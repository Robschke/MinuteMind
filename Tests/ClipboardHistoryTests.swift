// Purpose: Tests for the companion's Clipboard list: newest first, no repeats, at most 20 entries,
//          blank copies ignored, one-line previews, images (screenshots) kept with their size.
// Dependencies: Sources/App/Supporting/ClipboardHistory.swift

import AppKit
import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("ClipboardHistory Tests")
struct ClipboardHistoryTests {
    @Test func newestFirstWithoutRepeats() {
        let history = ClipboardHistory()
        history.record("one")
        history.record("two")
        history.record("one")
        #expect(history.items.map(\.text) == ["one", "two"])
    }

    @Test func keepsTheLastTwenty() {
        let history = ClipboardHistory()
        for index in 1...25 { history.record("text \(index)") }
        #expect(history.items.count == ClipboardHistory.limit)
        #expect(history.items.first?.text == "text 25")
        #expect(history.items.last?.text == "text 6")
    }

    @Test func ignoresBlankCopies() {
        let history = ClipboardHistory()
        history.record("  \n\t")
        #expect(history.items.isEmpty)
    }

    @Test func previewIsOneLine() {
        #expect(ClipboardHistory.preview("first line\n\n  second\tline ") == "first line second line")
    }

    @Test func keepsImagesWithoutRepeats() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let image = try #require(ClipboardHistory.Image(data: png, type: .png))
        let history = ClipboardHistory()
        history.record(image)
        history.record("text")
        history.record(image)
        #expect(history.items.count == 2)
        #expect(history.items.first?.title == "Image 40 \u{00D7} 30")
        #expect(ClipboardHistory.Image(data: Data("not an image".utf8), type: .png) == nil)
    }
}
