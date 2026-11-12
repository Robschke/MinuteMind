// Purpose: The Markdown theme for Claude's text in the companion's chat card: what a session
//          asks, its plan and its last message, rendered instead of shown as raw Markdown.
// Dependencies: MarkdownUI (swift-markdown-ui)
// Used by: Sources/App/Views/CompanionChatCard.swift
// Notes: The card is small and read at a glance, so the theme stays close to its body text:
//        headings only a step larger than the text and semibold, tight margins between blocks,
//        inline code and code blocks monospaced at about the card's code size on a faint tint,
//        code blocks scrolling sideways instead of wrapping. Sizes are relative (em) to `size`,
//        so the card's Metrics alone set them.

import MarkdownUI
import SwiftUI

extension Theme {
    /// Claude's Markdown in the companion's chat card, on a `size` pt base.
    @MainActor
    static func companionChat(size: CGFloat) -> Theme {
        Theme()
            .text {
                FontSize(size)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.86))
                BackgroundColor(Color.primary.opacity(0.08))
            }
            .strong {
                FontWeight(.semibold)
            }
            .link {
                ForegroundColor(.accentColor)
            }
            .heading1 { configuration in heading(configuration, scale: 1.15) }
            .heading2 { configuration in heading(configuration, scale: 1.07) }
            .heading3 { configuration in heading(configuration, scale: 1) }
            .heading4 { configuration in heading(configuration, scale: 1) }
            .heading5 { configuration in heading(configuration, scale: 1) }
            .heading6 { configuration in heading(configuration, scale: 1) }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.15))
                    .markdownMargin(top: .zero, bottom: .em(0.5))
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.15))
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .relativePadding(.leading, length: .em(0.8))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2)
                    }
                    .markdownMargin(top: .zero, bottom: .em(0.5))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.15))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.86))
                        }
                        .padding(8)
                }
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: .zero, bottom: .em(0.5))
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: .zero, bottom: .em(0.5))
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .relativePadding(.horizontal, length: .em(0.5))
                    .relativePadding(.vertical, length: .em(0.25))
            }
            .thematicBreak {
                Divider().markdownMargin(top: .em(0.5), bottom: .em(0.5))
            }
    }

    @MainActor
    private static func heading(_ configuration: BlockConfiguration, scale: Double) -> some View {
        configuration.label
            .markdownMargin(top: .em(0.6), bottom: .em(0.3))
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(scale))
            }
    }
}
