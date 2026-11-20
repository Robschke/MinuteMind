// Purpose: DesignSystem, the app's design tokens: colours, text styles, spacing and radii, all
//          following the active theme (ThemeStore), plus the helpers every view uses for sizes
//          that are not tokens: Font.themed(...) for text, .space(_:) for paddings and gaps,
//          .corner(_:) for corner radii, .row(_:) for fixed row and bar heights.
// Dependencies: Sources/App/Supporting/ThemeStore.swift (active theme), Sources/App/Config/ThemeStyle.swift
//               (font, density, corners), Sources/App/Components/ThemeFonts.swift (font lookup)
// Used by: nearly every view
// Notes: The helpers take the size the design calls for and return it in the theme's style, so a
//        view keeps its proportions and the standard style returns exactly the system font and
//        the given number (the built-in themes look as before). They read ThemeStore.shared,
//        which is @Observable, so a view redraws when the theme changes. Geometry that must not
//        scale (pixel creatures, their crowd and swap scene, the pill's pixel steps, hit areas,
//        previews of other themes) keeps plain numbers.

import SwiftUI

extension Font {
    /// A system-style font in the active theme: `size` scaled by the theme, its UI family (or
    /// the terminal family for monospaced text). Drop-in for `.system(size:weight:design:)`.
    @MainActor
    static func themed(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let style = ThemeStore.shared.theme.style
        if style.hasStandardFonts, design != .monospaced || style.terminalFontFamily == nil {
            return .system(size: size, weight: weight, design: design)
        }
        return ThemeFonts.font(size: size, weight: weight, design: design, style: style)
    }

    /// A text style in the active theme. Drop-in for `.body`, `.caption`, `.system(.body, design:)`.
    @MainActor
    static func themed(_ textStyle: Font.TextStyle, design: Font.Design = .default) -> Font {
        let style = ThemeStore.shared.theme.style
        if style.hasStandardFonts, design != .monospaced || style.terminalFontFamily == nil {
            return .system(textStyle, design: design)
        }
        return ThemeFonts.font(
            size: ThemeFonts.systemSize(of: textStyle), weight: textStyle == .headline ? .bold : .regular,
            design: design, style: style)
    }
}

extension CGFloat {
    /// A padding or gap in the active theme's density, rounded to half points.
    @MainActor
    static func space(_ value: CGFloat) -> CGFloat {
        let scale = ThemeStore.shared.theme.style.density.scale
        return scale == 1 ? value : (value * scale * 2).rounded() / 2
    }

    /// A fixed row or bar height in the active theme: grows with the text size (most of a row
    /// is text) and shrinks or grows with the density (the rest is padding).
    @MainActor
    static func row(_ value: CGFloat) -> CGFloat {
        let style = ThemeStore.shared.theme.style
        let scale = 0.6 * style.fontScale + 0.4 * style.density.scale
        return scale == 1 ? value : (value * scale).rounded()
    }

    /// A corner radius in the active theme's rounding.
    @MainActor
    static func corner(_ value: CGFloat) -> CGFloat {
        let scale = ThemeStore.shared.theme.style.corners.scale
        return scale == 1 ? value : value * scale
    }
}

struct DesignSystem {
    // MARK: - Colors

    /// Colours of the active theme (ThemeStore). Computed, so views redraw when the theme
    /// changes; with the default Studio theme they are the system colours the app used before.
    @MainActor
    struct Colors {
        private static var palette: ThemeStore.Palette { ThemeStore.shared.palette }

        static var accent: Color { palette.accent }
        static let secondary = Color.secondary

        /// Page background behind the content.
        static var surface: Color { palette.background }
        /// Secondary panes (file tree, strips).
        static var surfaceSecondary: Color { palette.surface }
        /// Cards and raised panels.
        static var card: Color { palette.card }
        static var border: Color { palette.border }
        static var divider: Color { palette.border.opacity(0.7) }

        static var textPrimary: Color { palette.textPrimary }
        static var textSecondary: Color { palette.textSecondary }
        static var textTertiary: Color { palette.textTertiary }

        static var success: Color { palette.success }
        static var warning: Color { palette.warning }
        static var error: Color { palette.danger }
        static var info: Color { palette.accent }

        // Interactive states
        static let hoverOverlay = Color.primary.opacity(0.05)
        static let pressedOverlay = Color.primary.opacity(0.1)
    }

    // MARK: - Typography

    /// Text styles in the active theme's font and size scale (ThemeStyle); with the standard
    /// style they are the system fonts at the sizes below.
    @MainActor
    struct Typography {
        private static func font(_ size: CGFloat, _ weight: Font.Weight, _ design: Font.Design = .default) -> Font {
            .themed(size: size, weight: weight, design: design)
        }

        // Display
        static var largeTitle: Font { font(34, .bold) }
        static var title1: Font { font(28, .bold) }
        static var title2: Font { font(22, .semibold) }
        static var title3: Font { font(20, .semibold) }

        // Body
        static var headline: Font { font(17, .semibold) }
        static var body: Font { font(15, .regular) }
        static var callout: Font { font(14, .regular) }

        // Supporting
        static var subheadline: Font { font(13, .regular) }
        static var footnote: Font { font(12, .regular) }
        static var caption1: Font { font(11, .regular) }
        static var caption2: Font { font(10, .medium) }

        // Monospaced variants (the theme's terminal font)
        static var monoBody: Font { font(15, .regular, .monospaced) }
        static var monoCaption: Font { font(11, .regular, .monospaced) }
    }

    // MARK: - Dimensions (8-point grid system)

    /// Spacing follows the active theme's density, radii its corners (ThemeStyle); with the
    /// standard style they are the values below.
    @MainActor
    struct Dimensions {
        // Spacing scale
        static var spacingXS: CGFloat { .space(4) }
        static var spacingS: CGFloat { .space(8) }
        static var spacingM: CGFloat { .space(12) }
        static var spacingL: CGFloat { .space(16) }
        static var spacingXL: CGFloat { .space(20) }
        static var spacingXXL: CGFloat { .space(24) }
        static var spacingXXXL: CGFloat { .space(32) }

        // Padding
        static var padding: CGFloat { .space(16) }
        static var paddingLarge: CGFloat { .space(20) }
        static var spacing: CGFloat { .space(12) }

        // Radius
        static var cornerRadius: CGFloat { .corner(12) }
        static var cornerRadiusLarge: CGFloat { .corner(16) }
        static var innerRadius: CGFloat { .corner(8) }
        static var pillRadius: CGFloat { .corner(100) }
    }

    // MARK: - Shadows

    struct Shadows {
        static let subtle = Shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        static let soft = Shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        static let card = Shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        static let elevated = Shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)
    }

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
    
    // MARK: - Animation
    
    struct Animation {
        static let quick = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.8)
        static let smooth = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.85)
        static let bounce = SwiftUI.Animation.spring(response: 0.5, dampingFraction: 0.7)
        static let gentle = SwiftUI.Animation.easeInOut(duration: 0.25)
    }
}

extension View {
    /// Premium card with liquid glass effect
    func premiumCardStyle() -> some View {
        self.padding(DesignSystem.Dimensions.paddingLarge)
            .background(
                ZStack {
                    // Base material
                    RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadius)
                        .fill(DesignSystem.Colors.card)
                    
                    // Subtle gradient overlay for depth
                    RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.05),
                                    Color.white.opacity(0.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Dimensions.cornerRadius)
                    .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
            )
            .shadow(
                color: DesignSystem.Shadows.card.color,
                radius: DesignSystem.Shadows.card.radius,
                x: DesignSystem.Shadows.card.x,
                y: DesignSystem.Shadows.card.y
            )
    }
    
    /// Enhanced hover effect with elevation
    func hoverElevation(isHovering: Bool) -> some View {
        self
            .scaleEffect(isHovering ? 1.005 : 1.0)
            .shadow(
                color: isHovering ? DesignSystem.Shadows.elevated.color : .clear,
                radius: isHovering ? DesignSystem.Shadows.elevated.radius : 0,
                x: 0,
                y: isHovering ? DesignSystem.Shadows.elevated.y : 0
            )
    }

    func glassBackground() -> some View {
        self.background(.ultraThinMaterial)
    }
    
    /// Section container with consistent styling
    func sectionContainer() -> some View {
        self
            .padding(DesignSystem.Dimensions.spacingL)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                    .fill(DesignSystem.Colors.card.opacity(0.5))
            )
    }
    
    /// Section divider with proper spacing
    func sectionDivider() -> some View {
        Divider()
            .overlay(DesignSystem.Colors.divider)
            .padding(.vertical, DesignSystem.Dimensions.spacingS)
    }
}

// MARK: - Button Styles

/// Button style that shows the theme's accent only on hover, otherwise transparent
struct HoverButtonStyle: ButtonStyle {
    @State private var isHovering = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isHovering ? DesignSystem.Colors.accent : .secondary)
            .background(
                RoundedRectangle(cornerRadius: .corner(6))
                    .fill(isHovering ? DesignSystem.Colors.accent.opacity(0.1) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
