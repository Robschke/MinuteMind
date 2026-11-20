// Purpose: ThemePreviewSheet, a sample MinuteMind screen drawn in a given theme, light and dark
//          side by side: sidebar rows, a card with text in several sizes, buttons, status chips,
//          speaker colours and a terminal. preview_theme returns it as a PNG so Claude can look at
//          a theme before saving it.
// Dependencies: Sources/App/Config/AppTheme.swift (colours, style), Sources/App/Components/ThemeFonts.swift
// Used by: Sources/App/Services/MCP/MCPThemeTools.swift (preview_theme)
// Notes: Drawn from the theme passed in, not the active one, so a draft can be shown without
//        switching the app. The sizes and paddings mirror the real views' design sizes, scaled
//        by the theme's font scale, density and corners, so the picture shows what the style does.

import AppKit
import SwiftUI

struct ThemePreviewSheet: View {
    let theme: AppTheme

    static func png(of theme: AppTheme) -> Data? {
        let renderer = ImageRenderer(content: ThemePreviewSheet(theme: theme))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    var body: some View {
        HStack(spacing: 0) {
            ThemePreviewPanel(theme: theme, dark: false)
            ThemePreviewPanel(theme: theme, dark: true)
        }
        .frame(width: 960)
    }
}

/// The sample screen in one mode.
private struct ThemePreviewPanel: View {
    let theme: AppTheme
    let dark: Bool

    private var style: ThemeStyle { theme.style }
    private func c(_ color: ThemeColor) -> Color { Color(nsColor: ThemeColor.srgb(color.resolved(dark: dark))) }
    private func font(_ size: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        ThemeFonts.font(size: size, weight: weight, design: mono ? .monospaced : .default, style: style)
    }
    private func space(_ value: CGFloat) -> CGFloat { value * style.density.scale }
    private func corner(_ value: CGFloat) -> CGFloat { value * style.corners.scale }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: 150)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(c(theme.surface))
            Rectangle().fill(c(theme.border)).frame(width: 1)
            page
        }
        .frame(width: 480, height: 400)
        .background(c(theme.background))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: space(2)) {
            Text(dark ? "Dark" : "Light")
                .font(font(10, .semibold))
                .foregroundStyle(c(theme.textTertiary))
                .padding(.horizontal, space(8))
                .padding(.bottom, space(4))
            ForEach(Array(["Home", "Cockpit", "Inbox", "Website", "Research"].enumerated()), id: \.offset) { index, name in
                HStack(spacing: space(8)) {
                    Image(systemName: ["house", "gauge.with.dots.needle.33percent", "tray", "folder", "folder"][index])
                        .font(font(12))
                        .foregroundStyle(c(theme.textSecondary))
                        .frame(width: 16)
                    Text(name).font(font(13)).foregroundStyle(c(theme.textPrimary))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, space(8))
                .padding(.vertical, space(6))
                .background(
                    RoundedRectangle(cornerRadius: corner(8))
                        .fill(index == 1 ? c(theme.accent).opacity(0.14) : .clear))
            }
        }
        .padding(space(10))
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: space(12)) {
            VStack(alignment: .leading, spacing: space(6)) {
                Text("Weekly sync").font(font(17, .semibold)).foregroundStyle(c(theme.textPrimary))
                Text("Decisions, open questions and the next steps from Tuesday.")
                    .font(font(13)).foregroundStyle(c(theme.textPrimary))
                Text("42 min, 4 speakers").font(font(11)).foregroundStyle(c(theme.textSecondary))
                HStack(spacing: space(6)) {
                    ForEach(theme.speakers.indices, id: \.self) { index in
                        Circle().fill(c(theme.speakers[index])).frame(width: 8, height: 8)
                    }
                }
                HStack(spacing: space(8)) {
                    Text("Process")
                        .font(font(12, .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, space(12))
                        .padding(.vertical, space(5))
                        .background(RoundedRectangle(cornerRadius: corner(6)).fill(c(theme.accent)))
                    Text("Skip")
                        .font(font(12))
                        .foregroundStyle(c(theme.textPrimary))
                        .padding(.horizontal, space(12))
                        .padding(.vertical, space(5))
                        .background(RoundedRectangle(cornerRadius: corner(6)).strokeBorder(c(theme.border)))
                }
                .padding(.top, space(4))
            }
            .padding(space(14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: corner(12)).fill(c(theme.card)))
            .overlay(RoundedRectangle(cornerRadius: corner(12)).strokeBorder(c(theme.border)))

            HStack(spacing: space(6)) {
                chip("Done", theme.success)
                chip("Waiting", theme.warning)
                chip("Failed", theme.danger)
            }

            VStack(alignment: .leading, spacing: space(3)) {
                Text("~/Workspaces/website ❯ claude")
                    .foregroundStyle(c(theme.textSecondary))
                Text("● Reading knowledge/decisions.md")
                    .foregroundStyle(c(theme.accent))
                Text("Summary written to meetings/2026-11-20-weekly-sync")
                    .foregroundStyle(c(theme.textPrimary))
            }
            .font(Font(ThemeFonts.terminalFont(style: style)))
            .padding(space(10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: corner(8)).fill(c(theme.background)))
            .overlay(RoundedRectangle(cornerRadius: corner(8)).strokeBorder(c(theme.accent).opacity(0.6), lineWidth: 1.5))
            Spacer(minLength: 0)
        }
        .padding(space(16))
    }

    private func chip(_ label: String, _ color: ThemeColor) -> some View {
        Text(label)
            .font(font(11, .medium))
            .foregroundStyle(c(color))
            .padding(.horizontal, space(8))
            .padding(.vertical, space(3))
            .background(RoundedRectangle(cornerRadius: corner(5)).fill(c(color).opacity(0.14)))
    }
}
