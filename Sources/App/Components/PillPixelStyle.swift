// Purpose: PillPixelStyle, a light pixel-art finish for the meeting pill's cards while they open
//          beside the desktop companion, so they match the pixel creature: stepped corners, a
//          crisp border, a hard drop shadow, blocky buttons, a square recording dot, block
//          level meters and a block dictation waveform.
// Dependencies: Sources/App/Supporting/CompanionAppearance.swift (the creature's colour for the
//               border), Sources/App/Components/DesignSystem.swift (accent)
// Used by: Sources/App/Views/MeetingPillView.swift (Glass, PillButtonStyle, RecordingDot,
//          LevelBars, DictationWave switch to these when `pillPixelStyle` is set)
// Notes: User request 2026-10-13: cards and recording "a bit more in line" with the pixel creature,
//        not too much. Decisions:
//        - Only in companion mode; the bottom-centre pill (companion hidden, screen share) keeps
//          its glass look.
//        - Text stays in the system font at the same sizes: legibility first, the pixel feel comes
//          from shapes, edges and shadows. The timer uses monospaced digits in SF Mono.
//        - A solid card instead of frosted glass: pixel art has no blur, and a solid fill reads on
//          any wallpaper. Corners step by 3 pt, the creature's pixel size; buttons by 2 pt.
//        - Border = the creature's outline colour (its body colour with black), so card and creature
//          belong together under every theme (65% black in dark mode too, so it reads as an
//          outline, not a glow). Shadow: 3 pt straight down, no blur.
//        - Design review: buttons opaque, their 2 pt base the face mixed with black (translucent
//          layers made the base read lighter than the face); the recording dot stays lit (a blink
//          for a whole meeting broke the creature's calm); status icons are squares like the
//          creature's bubbles; the meter rests flat.
//        - Dictation waveform (user request 2026-10-13: the fn capsule kept the smooth bars): one
//          column of 3 pt blocks per sample, all 18 samples (as wide as the smooth wave), 1 to 5
//          blocks from the bottom on the smooth wave's level mapping, no animation. Bottom-aligned
//          won over a centred waveform in rendered comparisons: centred columns with an even block
//          count cannot sit symmetric on the grid and looked lopsided, and odd counts only
//          overstated quiet speech. It now reads as the recording meter's wider sibling.

import SwiftUI

private struct PillPixelStyleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Draw the pill's cards in the pixel finish (set while they open beside the companion).
    var pillPixelStyle: Bool {
        get { self[PillPixelStyleKey.self] }
        set { self[PillPixelStyleKey.self] = newValue }
    }
}

/// A rectangle whose corners step in two `step` sized notches, like a pixel-art rounded corner.
struct PixelPanelShape: Shape {
    var step: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let s = step
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: minX + 2 * s, y: minY))
        path.addLine(to: CGPoint(x: maxX - 2 * s, y: minY))
        path.addLine(to: CGPoint(x: maxX - 2 * s, y: minY + s))
        path.addLine(to: CGPoint(x: maxX - s, y: minY + s))
        path.addLine(to: CGPoint(x: maxX - s, y: minY + 2 * s))
        path.addLine(to: CGPoint(x: maxX, y: minY + 2 * s))
        path.addLine(to: CGPoint(x: maxX, y: maxY - 2 * s))
        path.addLine(to: CGPoint(x: maxX - s, y: maxY - 2 * s))
        path.addLine(to: CGPoint(x: maxX - s, y: maxY - s))
        path.addLine(to: CGPoint(x: maxX - 2 * s, y: maxY - s))
        path.addLine(to: CGPoint(x: maxX - 2 * s, y: maxY))
        path.addLine(to: CGPoint(x: minX + 2 * s, y: maxY))
        path.addLine(to: CGPoint(x: minX + 2 * s, y: maxY - s))
        path.addLine(to: CGPoint(x: minX + s, y: maxY - s))
        path.addLine(to: CGPoint(x: minX + s, y: maxY - 2 * s))
        path.addLine(to: CGPoint(x: minX, y: maxY - 2 * s))
        path.addLine(to: CGPoint(x: minX, y: minY + 2 * s))
        path.addLine(to: CGPoint(x: minX + s, y: minY + 2 * s))
        path.addLine(to: CGPoint(x: minX + s, y: minY + s))
        path.addLine(to: CGPoint(x: minX + 2 * s, y: minY + s))
        path.closeSubpath()
        return path
    }
}

/// The card background: hard shadow, border in the creature's outline colour, solid fill.
struct PixelPanelBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        let border = 1.5 + (contrast == .increased ? 1 : 0)
        content
            .background {
                ZStack {
                    PixelPanelShape()
                        .fill(Color.black.opacity(dark ? 0.5 : 0.18))
                        .offset(y: 3)
                    PixelPanelShape()
                        .fill(dark ? Color(white: 0.16) : Color(white: 0.985))
                    // A centred stroke clipped to the shape: an even border that follows every step.
                    ZStack {
                        PixelPanelShape().stroke(CompanionAppearance.shared.bodyColor, lineWidth: border * 2)
                        PixelPanelShape().stroke(Color.black.opacity(dark ? 0.65 : 0.55), lineWidth: border * 2)
                    }
                    .clipShape(PixelPanelShape())
                }
            }
    }
}

/// A blocky button: stepped corners, flat fill, a 2 pt darker base it sinks into when pressed.
struct PixelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 22)
            .foregroundStyle(kind == .neutral ? Color.primary : Color.white)
            .background {
                ZStack {
                    // The base: the face colour mixed with black (layered: Color.mix needs macOS 15).
                    PixelPanelShape(step: 2).fill(face)
                        .overlay(PixelPanelShape(step: 2).fill(Color.black.opacity(baseDarkening)))
                        .offset(y: pressed ? 0 : 2)
                    PixelPanelShape(step: 2).fill(face)
                        .overlay(PixelPanelShape(step: 2).fill(hoverTint.opacity(hovering ? 1 : 0)))
                }
            }
            .offset(y: pressed ? 2 : 0)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    /// Opaque, so the base below never shows through the face.
    private var face: Color {
        switch kind {
        case .neutral: return Color(white: colorScheme == .dark ? 0.26 : 0.93)
        case .capture: return PillStyle.captureRed
        case .constructive: return DesignSystem.Colors.accent
        }
    }

    /// How much black turns the face into the base (light grey 0.93 becomes about 0.80).
    private var baseDarkening: Double {
        switch kind {
        case .neutral: return colorScheme == .dark ? 0.5 : 0.14
        case .capture, .constructive: return 0.3
        }
    }

    private var hoverTint: Color {
        kind == .neutral && colorScheme == .light ? Color.black.opacity(0.04) : Color.white.opacity(0.08)
    }
}

/// A square recording dot, steadily lit like a pixel LED; dimmed when `still` (dictation over a
/// running recording).
struct PixelRecordingDot: View {
    var still = false

    var body: some View {
        Rectangle()
            .fill(PillStyle.captureRed.opacity(still ? 0.6 : 1))
            .frame(width: 8, height: 8)
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

/// Four columns of 3 pt blocks following the audio level.
struct PixelLevelBars: View {
    let level: Float
    private let weights: [CGFloat] = [0.6, 1.0, 0.85, 0.5]
    /// Resting blocks per column, so silence reads as a quiet meter.
    private let resting = [1, 1, 1, 1]

    var body: some View {
        let normalized = CGFloat(min(1, sqrt(max(0, level)) * 3))
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(weights.indices, id: \.self) { index in
                let blocks = min(4, resting[index] + Int((3 * normalized * weights[index]).rounded()))
                VStack(spacing: 1) {
                    ForEach(0..<blocks, id: \.self) { _ in
                        Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 3, height: 3)
                    }
                }
            }
        }
        .frame(height: 15, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The dictation waveform as pixel columns: one column of 3 pt blocks per level sample (all 18,
/// as wide as the smooth wave), newest on the right, 1 to 5 blocks from the bottom. It steps with
/// the samples, without animation. While the microphone starts (`live` false) every column is
/// one block at 0.22 and one lit block (0.6) steps right at 8 fps (none with Reduce Motion).
struct PixelDictationWave: View {
    let levels: [Float]
    var live = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let maxBlocks = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.125, paused: live || reduceMotion)) { context in
            let lit = reduceMotion ? -1 : Int(context.date.timeIntervalSinceReferenceDate * 8) % max(1, levels.count)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(levels.indices, id: \.self) { index in
                    VStack(spacing: 1) {
                        ForEach(0..<(live ? Self.blocks(for: levels[index]) : 1), id: \.self) { _ in
                            Rectangle()
                                .fill(Color.primary.opacity(live ? 0.7 : (index == lit ? 0.6 : 0.22)))
                                .frame(width: 3, height: 3)
                        }
                    }
                }
            }
        }
        .frame(height: CGFloat(Self.maxBlocks * 4 - 1), alignment: .bottom)
        .accessibilityHidden(true)
    }

    /// 1 to 5 blocks, from the same level mapping as the smooth wave (sqrt, times 3, capped at 1).
    static func blocks(for level: Float) -> Int {
        let normalized = CGFloat(min(1, sqrt(max(0, level)) * 3))
        return 1 + Int((CGFloat(maxBlocks - 1) * normalized).rounded())
    }
}
