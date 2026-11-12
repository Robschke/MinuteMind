// Purpose: Help tab for Settings: the MinuteMind user guide, one expandable section per topic, with
//          a search field. Shows the same text Claude reads over MCP (get_help).
// Dependencies: Sources/App/Help/HelpGuide.swift (topics, search),
//               Sources/App/Components/MarkdownDisplayView.swift (topic bodies)
// Used by: Sources/App/Views/MeetingMinutesSettingsView.swift (Help tab)
// Notes: The guide's text lives in HelpGuideContent.swift, not here, so the tab and Claude never
//        disagree. While searching, the matching topics are listed best first and opened.

import SwiftUI

struct HelpSettingsView: View {
    @State private var searchText = ""
    @State private var expandedTopics: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            searchField

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isSearching && shownTopics.isEmpty {
                        Text("Nothing in the guide matches \u{201C}\(searchText)\u{201D}.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    ForEach(shownTopics) { topic in
                        HelpTopicSection(
                            topic: topic,
                            isExpanded: isSearching || expandedTopics.contains(topic.id),
                            toggle: { toggle(topic.id) }
                        )
                    }

                    Text("You can also ask Claude about MinuteMind: it reads this guide and can change settings for you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search help topics...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var isSearching: Bool { !HelpGuide.searchWords(searchText).isEmpty }

    private var shownTopics: [HelpGuideTopic] {
        guard isSearching else { return HelpGuide.topics }
        return HelpGuide.search(searchText, limit: HelpGuide.topics.count).map(\.topic)
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedTopics.contains(id) {
                expandedTopics.remove(id)
            } else {
                expandedTopics.insert(id)
            }
        }
    }
}

// MARK: - Topic Section

private struct HelpTopicSection: View {
    let topic: HelpGuideTopic
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: topic.icon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 24, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.title)
                            .font(.headline)
                        Text(topic.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)

            if isExpanded {
                MarkdownDisplayView(content: topic.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.3))
        )
    }
}
