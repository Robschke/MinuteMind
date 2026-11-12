import SwiftUI

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
    
    struct Typography {
        // Display
        static let largeTitle = Font.system(size: 34, weight: .bold, design: .default)
        static let title1 = Font.system(size: 28, weight: .bold, design: .default)
        static let title2 = Font.system(size: 22, weight: .semibold, design: .default)
        static let title3 = Font.system(size: 20, weight: .semibold, design: .default)
        
        // Body
        static let headline = Font.system(size: 17, weight: .semibold, design: .default)
        static let body = Font.system(size: 15, weight: .regular, design: .default)
        static let callout = Font.system(size: 14, weight: .regular, design: .default)
        
        // Supporting
        static let subheadline = Font.system(size: 13, weight: .regular, design: .default)
        static let footnote = Font.system(size: 12, weight: .regular, design: .default)
        static let caption1 = Font.system(size: 11, weight: .regular, design: .default)
        static let caption2 = Font.system(size: 10, weight: .medium, design: .default)
        
        // Monospaced variants
        static let monoBody = Font.system(size: 15, weight: .regular, design: .monospaced)
        static let monoCaption = Font.system(size: 11, weight: .regular, design: .monospaced)
    }

    // MARK: - Dimensions (8-point grid system)

    struct Dimensions {
        // Spacing scale
        static let spacingXS: CGFloat = 4
        static let spacingS: CGFloat = 8
        static let spacingM: CGFloat = 12
        static let spacingL: CGFloat = 16
        static let spacingXL: CGFloat = 20
        static let spacingXXL: CGFloat = 24
        static let spacingXXXL: CGFloat = 32
        
        // Padding
        static let padding: CGFloat = 16
        static let paddingLarge: CGFloat = 20
        static let spacing: CGFloat = 12
        
        // Radius
        static let cornerRadius: CGFloat = 12
        static let cornerRadiusLarge: CGFloat = 16
        static let innerRadius: CGFloat = 8
        static let pillRadius: CGFloat = 100
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
                RoundedRectangle(cornerRadius: 6)
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
