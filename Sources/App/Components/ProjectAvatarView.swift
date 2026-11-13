// Purpose: ProjectAvatarView, a project's picture on Home, in the project sidebar's header and in
//          the Cmd+K switcher: the project's own creature, still, at a chosen pixel size.
// Dependencies: Sources/App/Views/CompanionView.swift (MascotCanvas),
//               Sources/App/Supporting/AssistantMascotPose.swift (idle frame),
//               Sources/App/ViewModels/AppViewModel+Companion.swift (companionMark: the creature's
//               colour as beside the companion), Sources/App/Supporting/CompanionAppearance.swift
//               (the home companion's avatar for General)
// Used by: Sources/App/Views/HomeView.swift, Sources/App/Views/ProjectContextSidebar.swift,
//          Sources/App/Views/ProjectSwitcherView.swift
// Notes: A project without a creature of its own shows a Blob in the project colour, so every
//        project still reads as a creature; General shows the home companion, since General is
//        home. The creature with its own avatar takes the colour CompanionCast gives it, so it
//        looks the same here as beside the companion and in the starred mark.

import SwiftUI

struct ProjectAvatarView: View {
    let projectID: UUID
    /// Side of one creature pixel in points; the view is 12 by 16 pixels.
    var pixelSize: CGFloat
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        let look = appearance
        MascotCanvas(
            frame: AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: nil, avatar: look.avatar, animated: false)),
            avatar: look.avatar,
            pixelSize: pixelSize,
            bodyColor: look.color)
            .accessibilityHidden(true)
    }

    private var appearance: (avatar: MascotAvatar, color: Color?) {
        if projectID == ProjectRepositoryService.generalProjectID {
            return (CompanionAppearance.shared.avatar, nil)
        }
        guard let project = viewModel.projects.first(where: { $0.id == projectID }) else { return (.blob, nil) }
        let mark = viewModel.companionMark(for: project)
        if let avatar = mark.avatar { return (avatar, mark.color) }
        return (.blob, Color(hex: project.colorHex))
    }
}
