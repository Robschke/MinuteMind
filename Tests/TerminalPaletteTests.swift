// Purpose: Tests for TerminalPalette: every terminal colour reaches the minimum contrast on the
//          backgrounds of all built-in themes and on mid-tone custom backgrounds.
// Dependencies: Sources/App/Supporting/TerminalPalette.swift, Sources/App/Config/AppTheme.swift

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("Terminal palette")
struct TerminalPaletteTests {

    /// Built-in theme backgrounds, a typical system window background, and awkward custom ones.
    static let backgrounds: [UInt32] = [
        0xFFFFFF, 0x1E1E1E, 0xFBF8F3, 0x1C1916, 0xF4F7FA, 0x0B1220, 0x0D0D12,
        0x777777, 0x5A7A9A, 0xC2541C, 0x22D3EE, 0x808000,
    ]

    @Test("Every colour but black on dark reads on every background", arguments: backgrounds)
    func testContrast(background: UInt32) {
        let palette = TerminalPalette.ansi(on: background)
        #expect(palette.count == 16)
        for (index, color) in palette.enumerated() {
            if index == 0, TerminalPalette.isDark(background) { continue }
            #expect(TerminalPalette.contrast(color, background) >= TerminalPalette.minimumContrast,
                    "colour \(index) \(String(color, radix: 16)) on \(String(background, radix: 16))")
        }
    }

    @Test("A colour that already reads stays as it is")
    func testReadableUnchanged() {
        #expect(TerminalPalette.readable(0x1D1D1F, on: 0xFFFFFF) == 0x1D1D1F)
        #expect(TerminalPalette.readable(0xF5F5F7, on: 0x0B1220) == 0xF5F5F7)
    }

    @Test("Light text on a light background turns dark")
    func testWrongSide() {
        let fixed = TerminalPalette.readable(0xFFFFFF, on: 0xFBF8F3)
        #expect(TerminalPalette.contrast(fixed, 0xFBF8F3) >= TerminalPalette.minimumContrast)
    }
}
