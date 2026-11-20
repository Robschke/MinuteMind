// Purpose: AgentCockpitPicker, the cockpit's project picker (Cmd+T): a search field over every
//          project and General, each with its creature in the pose of its Claude sessions and how
//          many agents it runs, in the Home sidebar's order, plus New Project… at the end. Return or a click starts an Opus
//          session in the chosen project and shows it in the cockpit.
// Dependencies: Sources/App/Supporting/AgentCockpitSpaces.swift (matching),
//               Sources/App/ViewModels/AppViewModel+Cockpit.swift (cockpitPickerOrder, spaces,
//               startCockpitSession),
//               Sources/App/Components/AgentStatusCreatureView.swift (creatures)
// Used by: Sources/App/Views/ContentView.swift (overlay while the cockpit shows)
// Notes: Looks and keys like the Cmd+K search (Spotlight panel near the top, arrows, Return,
//        Esc, a click beside it closes it), so the two feel like one family. Rows follow the Home
//        sidebar (manual or recently used, as set in Settings), so the project used last is near
//        the top; a query ranks name matches first and keeps that order among equals. Projects that already
//        run agents are listed too: choosing one starts another session there. New Project… stays
//        the last row whatever the query, so a name that does not exist yet is one arrow away;
//        it opens the cockpit's New Project sheet through `requestsNewProject`. Closing without a
//        choice gives the keyboard back to what had it (usually a terminal).

import AppKit
import SwiftUI

struct AgentCockpitPicker: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var fieldFocused: Bool
    @State private var query = ""
    @State private var highlighted = 0
    @State private var previousResponder: NSResponder?

    private static let width: CGFloat = 560
    private static let listHeight: CGFloat = 420

    /// A row: a space, or New Project… (nil).
    private struct Row: Identifiable, Hashable {
        let spaceID: UUID?
        var id: String { spaceID?.uuidString ?? "new-project" }
    }

    private var rows: [Row] {
        let order = viewModel.cockpitPickerOrder
        let names = Dictionary(uniqueKeysWithValues: order.compactMap { id in
            viewModel.cockpitProject(id).map { (id, $0.name) }
        })
        return AgentCockpitSpaces.matching(query, order: order, names: names).map { Row(spaceID: $0) }
            + [Row(spaceID: nil)]
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            panel
                .frame(width: Self.width)
                .padding(.top, .space(72))
        }
        .onAppear {
            previousResponder = viewModel.mainWindow?.firstResponder
            // After the panel is in the window, or the focus request finds no field yet.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: query) { highlighted = 0 }
    }

    private var panel: some View {
        let rows = rows
        return VStack(spacing: 0) {
            field(rows)
            Divider()
            list(rows)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: .corner(16), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: .corner(16), style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Start an agent")
    }

    private func field(_ rows: [Row]) -> some View {
        HStack(spacing: DesignSystem.Dimensions.spacingS) {
            Image(systemName: "sparkle")
                .font(.themed(size: 17))
                .foregroundStyle(Color.accentColor)
            TextField("Start an agent in…", text: $query)
                .textFieldStyle(.plain)
                .font(.themed(size: 20))
                .focused($fieldFocused)
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, rows.count - 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    if rows.indices.contains(highlighted) { choose(rows[highlighted]) }
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
            Text("Opus")
                .font(DesignSystem.Typography.caption1)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingL)
        .padding(.vertical, DesignSystem.Dimensions.spacingM)
    }

    private func list(_ rows: [Row]) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: .space(2)) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, selected: index == highlighted)
                            .id(row.id)
                            .onTapGesture { choose(row) }
                    }
                }
                .padding(DesignSystem.Dimensions.spacingS)
            }
            .frame(maxHeight: Self.listHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) { _, index in
                guard rows.indices.contains(index) else { return }
                scroller.scrollTo(rows[index].id)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: DesignSystem.Dimensions.spacingM) {
            if let spaceID = row.spaceID, let project = viewModel.cockpitProject(spaceID) {
                let sessions = viewModel.cockpitSessions(in: spaceID)
                AgentStatusCreatureView(projectID: spaceID, sessions: sessions, pixelSize: 2)
                    .frame(width: 32, height: 34)
                VStack(alignment: .leading, spacing: .space(1)) {
                    Text(project.name)
                        .font(DesignSystem.Typography.body.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    Text(agentsLabel(sessions))
                        .font(DesignSystem.Typography.caption1)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "plus")
                    .font(.themed(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().strokeBorder(DesignSystem.Colors.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .frame(width: 32, height: 34)
                Text("New Project…")
                    .font(DesignSystem.Typography.body.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return")
                    .font(.themed(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignSystem.Dimensions.spacingS)
        .padding(.vertical, .space(4))
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Dimensions.innerRadius)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// "No agents", "1 agent running", "3 agents, 1 waiting".
    private func agentsLabel(_ sessions: [WorkspaceTerminalSession]) -> String {
        guard !sessions.isEmpty else { return "No agents" }
        let count = sessions.count == 1 ? "1 agent" : "\(sessions.count) agents"
        let waiting = sessions.filter {
            AgentSessionState($0.status, finishedUnseen: $0.finishedUnseen) == .waiting
        }.count
        return waiting > 0 ? "\(count), \(waiting) waiting" : "\(count) running"
    }

    private func choose(_ row: Row) {
        viewModel.isShowingCockpitPicker = false
        if let spaceID = row.spaceID {
            viewModel.startCockpitSession(in: spaceID)
        } else {
            viewModel.requestsNewProject = true
        }
    }

    private func close() {
        viewModel.isShowingCockpitPicker = false
        guard let window = viewModel.mainWindow, let previousResponder else { return }
        if let view = previousResponder as? NSView, view.window !== window { return }
        window.makeFirstResponder(previousResponder)
    }
}
