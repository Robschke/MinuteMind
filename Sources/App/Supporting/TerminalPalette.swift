// Purpose: TerminalPalette, the colours of the workspace terminals for a given background: the
//          16 ANSI colours and the default text, each pushed until it reads on that background.
// Dependencies: Sources/App/Config/AppTheme.swift (ThemeColor.luminance, CustomThemeSettings.shift)
// Used by: Sources/App/Supporting/WorkspaceTerminalStore.swift (applyPalette)
// Notes: The terminal background follows the app theme, and a Custom theme can pick any colour,
//        so no fixed palette can be readable everywhere. Every colour therefore starts from a
//        light or dark base set and is mixed toward black or white until it reaches
//        `minimumContrast` against the actual background (WCAG ratio). Black on dark backgrounds
//        is left alone: programs paint it as a background, not as text. The ink direction is
//        whichever extreme contrasts more with the background (WCAG luminance 0.179 split), so a
//        mid-tone background can always reach the minimum.

import Foundation

enum TerminalPalette {
    /// WCAG AA for normal text.
    static let minimumContrast = 4.5

    /// The 16 ANSI colours (normal then bright: black, red, green, yellow, blue, magenta, cyan,
    /// white) for `background`, as sRGB hex.
    static func ansi(on background: UInt32) -> [UInt32] {
        let dark = isDark(background)
        return (dark ? darkBase : lightBase).enumerated().map { index, color in
            dark && index == 0 ? color : readable(color, on: background)
        }
    }

    /// `color`, mixed toward the ink extreme of `background` just far enough to reach
    /// `minimumContrast`; unchanged when it already does.
    static func readable(_ color: UInt32, on background: UInt32) -> UInt32 {
        guard contrast(color, background) < minimumContrast else { return color }
        let direction = isDark(background) ? 1.0 : -1.0
        // Stepped, not bisected: a colour on the wrong side of the background (white on cream)
        // loses contrast before it gains it. The extreme itself always passes.
        for step in 1...50 {
            let candidate = CustomThemeSettings.shift(color, by: direction * Double(step) / 50)
            if contrast(candidate, background) >= minimumContrast { return candidate }
        }
        return direction > 0 ? 0xFFFFFF : 0x000000
    }

    /// WCAG contrast ratio of two colours, 1 to 21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = ThemeColor.luminance(a), lb = ThemeColor.luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Whether light ink contrasts more with `background` than dark ink.
    static func isDark(_ background: UInt32) -> Bool {
        ThemeColor.luminance(background) < 0.179
    }

    private static let lightBase: [UInt32] = [
        0x1D1D1F, 0xC4271E, 0x1F7A36, 0x8A5A00, 0x0B5CC2, 0x8E3BB5, 0x0E6F7A, 0x3C3C43,
        0x6E6E73, 0xD7302A, 0x248A3D, 0x9A6700, 0x0A66D8, 0xA04ACB, 0x107C88, 0x1D1D1F,
    ]

    private static let darkBase: [UInt32] = [
        0x000000, 0xFF5F57, 0x32D74B, 0xFFD60A, 0x5E9EFF, 0xD07CFF, 0x5AC8D8, 0xD1D1D6,
        0x8E8E93, 0xFF7B73, 0x5BE37A, 0xFFE155, 0x82B4FF, 0xDE9BFF, 0x7FD9E5, 0xFFFFFF,
    ]
}
