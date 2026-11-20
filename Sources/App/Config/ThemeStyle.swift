// Purpose: ThemeStyle, the non-colour part of a theme: the UI font and its size scale, corner
//          rounding, density (how much space padding and gaps take) and the terminal font. The
//          design tokens (DesignSystem) and the AppKit text views read it from the active theme.
// Dependencies: none
// Used by: Sources/App/Config/AppTheme.swift (every theme carries one),
//          Sources/App/Config/ThemeFile.swift (read from and written to theme files),
//          Sources/App/Components/DesignSystem.swift (fonts, spacing, corners),
//          Sources/App/Supporting/WorkspaceTerminalStore.swift, Sources/App/Views/WorkspaceCodeEditor.swift
//          (terminal font)
// Notes: `standard` is the app as it looked before themes had a style: system font at its own
//        sizes, today's corners and spacing, SF Mono 12 in terminals. Every built-in theme uses
//        it, so choosing a built-in never changes more than colours. Font scale and terminal
//        size are kept within ranges the layouts survive; ThemeFileValidator refuses values
//        outside them.

import Foundation

struct ThemeStyle: Equatable, Sendable {
    enum Corners: String, CaseIterable, Sendable {
        case square, subtle, regular, round

        /// Multiplier for every corner radius in the app.
        var scale: Double {
            switch self {
            case .square: 0
            case .subtle: 0.5
            case .regular: 1
            case .round: 1.6
            }
        }
    }

    enum Density: String, CaseIterable, Sendable {
        case compact, regular, roomy

        /// Multiplier for every padding and gap in the app.
        var scale: Double {
            switch self {
            case .compact: 0.7
            case .regular: 1
            case .roomy: 1.3
            }
        }
    }

    static let fontScaleRange: ClosedRange<Double> = 0.8...1.5
    static let terminalSizeRange: ClosedRange<Double> = 9...24
    static let standardTerminalSize: Double = 12

    /// Font family for the app's text (e.g. "Inter", "Geist Mono"); nil is the system font.
    var fontFamily: String?
    /// Multiplier for every text size in the app.
    var fontScale: Double = 1
    var corners: Corners = .regular
    var density: Density = .regular
    /// Font family for the Claude terminals, the code editor and monospaced text; nil is SF Mono.
    var terminalFontFamily: String?
    /// Point size of terminal and editor text.
    var terminalFontSize: Double = standardTerminalSize

    static let standard = ThemeStyle()

    /// True when text looks exactly as it did before themes had a style.
    var hasStandardFonts: Bool { fontFamily == nil && fontScale == 1 }
}
