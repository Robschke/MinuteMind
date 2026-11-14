// Purpose: The Ctrl+Tab project switcher, styled and driven like the macOS app switcher (Cmd+Tab):
//          hold Control, press Tab to open it and step right (the arrow keys step both ways), let go
//          of Control to enter the highlighted project, Esc cancels. A row of creatures on a
//          translucent panel in the middle of the window, each with its project's name below.
// Dependencies: Sources/App/Supporting/AppNavigation.swift (ProjectSwitcherOrder),
//               Sources/App/ViewModels/AppViewModel+Navigation.swift (switcherProjectIDs,
//               enterProject), Sources/App/Components/ProjectAvatarView.swift (creatures)
// Used by: Sources/App/Views/ContentView.swift (overlay),
//          Sources/App/Components/MainWindowEventMonitor.swift (keys)
// Notes: Projects are listed most recently used first, so a quick Ctrl+Tab goes back to the
//        previous project, as Cmd+Tab does with apps. A click on a creature enters it at once. The panel
//        lives in the window (not on the screen like Cmd+Tab), since it switches inside the app.
//        Too many projects for the window's width scroll so the highlighted one stays in view.

import SwiftUI

/// What the switcher shows: the entries and the highlight, nothing while closed.
@Observable
@MainActor
final class ProjectSwitcherModel {
    private(set) var items: [UUID] = []
    private(set) var index = 0

    var isShown: Bool { !items.isEmpty }
    var highlighted: UUID? { items.indices.contains(index) ? items[index] : nil }

    func show(items: [UUID], current: UUID?) {
        guard !items.isEmpty else { return }
        self.items = items
        index = ProjectSwitcherOrder.startIndex(items: items, current: current)
    }

    func step(by step: Int) {
        index = ProjectSwitcherOrder.stepped(index, by: step, count: items.count)
    }

    /// Closes the switcher and returns the highlighted project.
    func finish() -> UUID? {
        let chosen = highlighted
        items = []
        return chosen
    }

    func cancel() { items = [] }
}

struct ProjectSwitcherView: View {
    let model: ProjectSwitcherModel
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme

    /// Side of one creature pixel: the creatures are 60 by 80 points.
    private static let pixel: CGFloat = 5
    /// One entry: the creature (92 by 104) with the project's name below it.
    private static let cell = CGSize(width: 92, height: 126)

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.items, id: \.self) { id in
                            cell(id)
                                .id(id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(width: min(rowWidth, proxy.size.width - 96), height: Self.cell.height)
                .onChange(of: model.index, initial: true) { _, _ in
                    if let id = model.highlighted { scroller.scrollTo(id, anchor: .center) }
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switch project")
    }

    private var rowWidth: CGFloat {
        CGFloat(model.items.count) * (Self.cell.width + 4) + 4
    }

    private func cell(_ id: UUID) -> some View {
        let selected = id == model.highlighted
        return VStack(spacing: 2) {
            ProjectAvatarView(projectID: id, pixelSize: Self.pixel)
                .frame(maxHeight: .infinity)
            Text(name(of: id))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
        }
            .padding(.bottom, 8)
            .frame(width: Self.cell.width, height: Self.cell.height)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.primary.opacity(colorScheme == .dark ? 0.2 : 0.12) : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture {
                model.cancel()
                viewModel.enterProject(id)
            }
            .contextMenu {
                if id != ProjectRepositoryService.generalProjectID {
                    Button("Edit Project…") {
                        model.cancel()
                        viewModel.editingProjectID = id
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(name(of: id))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func name(of id: UUID?) -> String {
        guard let id else { return "" }
        if id == ProjectRepositoryService.generalProjectID { return "General" }
        return viewModel.projects.first { $0.id == id }?.name ?? ""
    }
}
