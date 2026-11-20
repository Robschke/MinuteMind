// Purpose: ThemeFonts, turning a theme's style into fonts: SwiftUI fonts for the app's text (UI
//          family and scale, the terminal family for monospaced text) and AppKit fonts for the
//          terminals, the code editor and other AppKit text.
// Dependencies: Sources/App/Config/ThemeStyle.swift
// Used by: Sources/App/Components/DesignSystem.swift (Font.themed, Typography),
//          Sources/App/Supporting/ThemeStore.swift (forgets the checks when fonts change),
//          Sources/App/Views/ThemePreviewSheet.swift (preview_theme picture),
//          Sources/App/Supporting/WorkspaceTerminalStore.swift, Sources/App/Views/WorkspaceCodeEditor.swift
// Notes: With the standard style the system fonts come back unchanged, so the built-in themes
//        look exactly as before. A family that is not installed falls back to the system font
//        (checked once per family name until the Mac's fonts change, `forgetInstalled`), so a
//        theme from another Mac never shows a missing-font placeholder and takes its font as soon
//        as it is installed. Weights are applied to the family; a family without that weight shows its
//        nearest face.

import AppKit
import SwiftUI

enum ThemeFonts {
    /// Whether a family is installed, checked once each until `forgetInstalled`.
    @MainActor private static var installed: [String: Bool] = [:]

    /// Fonts were installed or removed: every family is checked again when next asked for.
    @MainActor
    static func forgetInstalled() {
        installed.removeAll()
    }

    @MainActor
    static func isInstalled(_ family: String) -> Bool {
        if let known = installed[family] { return known }
        let found = NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
        installed[family] = found
        return found
    }

    /// Every installed font family, by name.
    static var installedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A text font in the theme's style: `size` is the size the design calls for, scaled by the
    /// theme; monospaced text uses the terminal family.
    @MainActor
    static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, style: ThemeStyle) -> Font {
        let scaled = size * style.fontScale
        let family = design == .monospaced ? style.terminalFontFamily : style.fontFamily
        if let family, isInstalled(family) {
            return Font.custom(family, size: scaled).weight(weight)
        }
        return .system(size: scaled, weight: weight, design: design)
    }

    /// The point size macOS gives a text style (body 13, caption 10, ...), what `.body` etc.
    /// show with the system font.
    static func systemSize(of textStyle: Font.TextStyle) -> CGFloat {
        let appKitStyle: NSFont.TextStyle = switch textStyle {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
        return NSFont.preferredFont(forTextStyle: appKitStyle).pointSize
    }

    /// The terminal and code editor font.
    @MainActor
    static func terminalFont(style: ThemeStyle, weight: NSFont.Weight = .regular) -> NSFont {
        let size = CGFloat(style.terminalFontSize)
        if let family = style.terminalFontFamily, isInstalled(family),
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: weight == .bold ? 9 : 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// An AppKit UI font in the theme's style.
    @MainActor
    static func uiFont(size: CGFloat, weight: NSFont.Weight = .regular, style: ThemeStyle) -> NSFont {
        let scaled = size * style.fontScale
        if let family = style.fontFamily, isInstalled(family),
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: weight >= .semibold ? 9 : 5, size: scaled) {
            return font
        }
        return .systemFont(ofSize: scaled, weight: weight)
    }
}
