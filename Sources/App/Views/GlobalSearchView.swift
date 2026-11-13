// Purpose: The Cmd+K global search, Spotlight style: a search field on a translucent panel near the
//          top of the main window, results grouped below it (pages and Settings, projects, Claude
//          sessions, meetings with the matching transcript or summary line, knowledge files, menu
//          commands). Up and down move the highlight, Return opens it, Esc, Cmd+K again or a click
//          outside closes the panel.
// Dependencies: Sources/App/Supporting/GlobalSearch.swift (matching, results),
//               Sources/App/ViewModels/AppViewModel+GlobalSearch.swift (entries, meetings,
//               knowledge, opening a result), Sources/App/Views/TranscriptDetailView.swift
//               (a transcript hit opens there, filtered to the query),
//               Sources/App/Components/ProjectAvatarView.swift (creatures on project rows)
// Used by: Sources/App/Views/ContentView.swift (`.globalSearch`),
//          Sources/App/Components/MainWindowEventMonitor.swift (Cmd+K toggles it)
// Notes: Lives in the window like the project switcher, since it moves around inside the app.
//        The searchable names, meetings and menu commands are collected once when it opens;
//        summaries are read from disk in the background and the results refresh when they arrive.
//        Typing is debounced briefly and the meeting scan runs off the main actor. Closing gives
//        the keyboard back to whatever had it before (a terminal, the editor), so a menu command
//        chosen here acts on that, as it would from the menu bar. The keys follow the Task
//        Commander's list (arrows, Return, Esc on the field).

import AppKit
import SwiftUI

/// A transcript to show from a search hit, filtered to `query`.
struct GlobalSearchTranscriptRequest: Identifiable {
    let sessionID: UUID
    let query: String
    var id: UUID { sessionID }
}

/// The search's state: shown or not, the query, the results and the highlight.
@Observable
@MainActor
final class GlobalSearchModel {
    private(set) var isShown = false
    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    private(set) var results: [GlobalSearchResult] = []
    /// Index into `results` of the highlighted row.
    private(set) var highlighted = 0
    /// True once a search for the current query finished, so "No results" never flashes.
    private(set) var hasSearched = false
    /// A transcript hit waiting to be shown (the host's sheet).
    var transcript: GlobalSearchTranscriptRequest?

    @ObservationIgnored private weak var viewModel: AppViewModel?
    @ObservationIgnored private var entries: [GlobalSearchEntry] = []
    @ObservationIgnored private var meetings: [GlobalSearchMeeting] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    /// What had the keyboard when the search opened, given back on close.
    @ObservationIgnored private weak var previousResponder: NSResponder?

    func toggle(viewModel: AppViewModel) {
        isShown ? close() : show(viewModel: viewModel)
    }

    func show(viewModel: AppViewModel) {
        guard !isShown else { return }
        self.viewModel = viewModel
        previousResponder = viewModel.mainWindow?.firstResponder
        entries = viewModel.globalSearchEntries()
        meetings = viewModel.globalSearchMeetings()
        query = ""
        results = []
        highlighted = 0
        hasSearched = false
        isShown = true

        let files = viewModel.globalSearchSummaryFiles()
        summaryTask = Task { [weak self] in
            let summaries = await Task.detached(priority: .userInitiated) {
                files.compactMapValues { try? String(contentsOf: $0, encoding: .utf8) }
            }.value
            guard let self, self.isShown, !Task.isCancelled else { return }
            self.meetings = self.meetings.map { meeting in
                var meeting = meeting
                meeting.summary = summaries[meeting.id]
                return meeting
            }
            if !self.query.isEmpty { self.scheduleSearch(delay: .zero) }
        }
    }

    func close() {
        guard isShown else { return }
        isShown = false
        searchTask?.cancel()
        summaryTask?.cancel()
        entries = []
        meetings = []
        results = []
        if let window = viewModel?.mainWindow, let previousResponder {
            // Only when it is still part of the window (a closed tab's terminal is not).
            if let view = previousResponder as? NSView, view.window !== window { return }
            window.makeFirstResponder(previousResponder)
        }
    }

    func moveHighlight(by step: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(highlighted + step, 0), results.count - 1)
    }

    func openHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        open(results[highlighted])
    }

    func open(_ result: GlobalSearchResult) {
        let viewModel = viewModel
        close()
        switch result.target {
        case .transcript(let sessionID, let query):
            transcript = GlobalSearchTranscriptRequest(sessionID: sessionID, query: query)
        default:
            // After the keyboard went back, so a menu command reaches the right responder.
            DispatchQueue.main.async { viewModel?.openGlobalSearchTarget(result.target) }
        }
    }

    private func scheduleSearch(delay: Duration = .milliseconds(120)) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShown, !text.isEmpty else {
            results = []
            highlighted = 0
            hasSearched = false
            return
        }
        let entries = entries
        let meetings = meetings
        searchTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let named = GlobalSearch.matchEntries(text, in: entries)
            let found = await Task.detached(priority: .userInitiated) {
                GlobalSearch.matchMeetings(text, in: meetings)
            }.value
            guard let self, !Task.isCancelled else { return }
            let knowledge = self.viewModel?.globalSearchKnowledge(text) ?? []
            self.results = GlobalSearch.grouped(named + found + knowledge).flatMap(\.results)
            self.highlighted = 0
            self.hasSearched = true
        }
    }
}

extension View {
    /// Adds the global search panel over this view and the sheet its transcript hits open in.
    func globalSearch(_ model: GlobalSearchModel) -> some View {
        modifier(GlobalSearchHost(model: model))
    }
}

struct GlobalSearchHost: ViewModifier {
    @Bindable var model: GlobalSearchModel
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if model.isShown {
                    GlobalSearchView(model: model)
                        .environment(viewModel)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.isShown)
            .sheet(item: $model.transcript) { request in
                if let session = viewModel.sessions.first(where: { $0.id == request.sessionID }) {
                    TranscriptDetailView(session: session, initialSearch: request.query)
                        .environment(viewModel)
                }
            }
    }
}

struct GlobalSearchView: View {
    @Bindable var model: GlobalSearchModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var fieldFocused: Bool

    private static let width: CGFloat = 620
    private static let resultsHeight: CGFloat = 420

    var body: some View {
        ZStack(alignment: .top) {
            // A click beside the panel closes it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.close() }
                .accessibilityHidden(true)
            panel
                .frame(width: Self.width)
                .padding(.top, 72)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            if !model.results.isEmpty {
                Divider()
                resultList
            } else if model.hasSearched {
                Divider()
                Text("No results")
                    .font(DesignSystem.Typography.callout)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Dimensions.spacingL)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
    }

    private var field: some View {
        HStack(spacing: DesignSystem.Dimensions.spacingS) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            TextField("Search pages, projects, sessions, meetings and knowledge", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($fieldFocused)
                .onKeyPress(.upArrow) {
                    model.moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    model.openHighlighted()
                    return .handled
                }
                .onKeyPress(.escape) {
                    model.close()
                    return .handled
                }
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingL)
        .padding(.vertical, DesignSystem.Dimensions.spacingM)
        .onAppear {
            // After the panel is in the window, or the focus request finds no field yet.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private var resultList: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(GlobalSearch.grouped(model.results), id: \.section) { group in
                        Text(group.section.title)
                            .font(DesignSystem.Typography.caption1.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .padding(.horizontal, DesignSystem.Dimensions.spacingL)
                            .padding(.top, DesignSystem.Dimensions.spacingS)
                            .padding(.bottom, 2)
                        ForEach(group.results) { result in
                            row(result)
                                .id(result.id)
                        }
                    }
                }
                .padding(.bottom, DesignSystem.Dimensions.spacingS)
            }
            .frame(maxHeight: Self.resultsHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.highlighted) { _, index in
                guard model.results.indices.contains(index) else { return }
                scroller.scrollTo(model.results[index].id)
            }
        }
    }

    private func row(_ result: GlobalSearchResult) -> some View {
        let selected = model.results.indices.contains(model.highlighted)
            && model.results[model.highlighted].id == result.id
        return HStack(spacing: DesignSystem.Dimensions.spacingS) {
            icon(result)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(DesignSystem.Typography.callout)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingS)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .padding(.horizontal, DesignSystem.Dimensions.spacingS)
        .onTapGesture { model.open(result) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func icon(_ result: GlobalSearchResult) -> some View {
        if case .project(let id) = result.target {
            ProjectAvatarView(projectID: id, pixelSize: 1.5)
        } else {
            Image(systemName: result.icon)
                .font(.system(size: 14))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }
}
