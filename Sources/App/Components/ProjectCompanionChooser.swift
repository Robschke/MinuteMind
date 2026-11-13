// Purpose: ProjectCompanionChooser, picking a project's creature: None, then every avatar as a
//          tile, drawn in the colour it will have on the project. Shared by the New Project sheet
//          and the project settings sheet.
// Dependencies: Sources/App/Components/ProjectAvatarView.swift (ProjectCreatureMark),
//               Sources/App/Supporting/CompanionAppearance.swift (projectBodyColor, home avatar)
// Used by: Sources/App/Views/ProjectsSidebarView.swift (New Project sheet, Companion menu labels),
//          Sources/App/Views/ProjectSettingsSheet.swift
// Notes: Avatars already in use are named in the tooltip, not blocked: an avatar colour tells two
//        projects with the same creature apart.

import SwiftUI

struct ProjectCompanionChooser: View {
    @Binding var selection: MascotAvatar?
    /// The project's avatar colour, so every tile shows the creature as it would look.
    var avatarColorHex: String?
    /// The project being edited (nil for a new one), left out of "used by".
    var projectID: UUID?
    @Environment(AppViewModel.self) private var viewModel

    private static let tileSize: CGFloat = 40

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Dimensions.spacingS) {
            tile(nil) {
                Text("None")
                    .font(DesignSystem.Typography.caption1)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(Self.tileSize), spacing: DesignSystem.Dimensions.spacingS), count: 5),
                alignment: .leading, spacing: DesignSystem.Dimensions.spacingS
            ) {
                ForEach(MascotAvatar.allCases) { avatar in
                    tile(avatar) {
                        ProjectCreatureMark(
                            avatar: avatar,
                            color: CompanionAppearance.projectBodyColor(avatar, hex: avatarColorHex),
                            pixelSize: 2)
                    }
                }
            }
        }
    }

    private func tile(_ avatar: MascotAvatar?, @ViewBuilder content: () -> some View) -> some View {
        let isSelected = selection == avatar
        let label = avatar.map { Self.label($0, projectID: projectID, projects: viewModel.projects) } ?? "No companion"
        return Button {
            selection = avatar
        } label: {
            content()
                .frame(width: Self.tileSize, height: Self.tileSize)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? DesignSystem.Colors.accent.opacity(0.15) : Color.primary.opacity(0.04)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? DesignSystem.Colors.accent : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The avatar's name, with the home companion or the other projects that wear it.
    static func label(_ avatar: MascotAvatar, projectID: UUID?, projects: [Project]) -> String {
        if avatar == CompanionAppearance.shared.avatar { return "\(avatar.name) (your companion)" }
        let others = projects.filter { $0.id != projectID && $0.companionCreature == avatar }.map(\.name)
        return others.isEmpty ? avatar.name : "\(avatar.name) (used by \(others.joined(separator: ", ")))"
    }
}
