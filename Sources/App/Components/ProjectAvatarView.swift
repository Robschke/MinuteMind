// Purpose: ProjectAvatarView, a project's picture wherever the project is named: Home, the
//          sidebars, the project switcher, lists, the calendar. The project's own creature, still,
//          at a chosen pixel size, in its avatar colour.
// Dependencies: Sources/App/Views/CompanionView.swift (MascotCanvas),
//               Sources/App/Supporting/AssistantMascotPose.swift (idle frame),
//               Sources/App/ViewModels/AppViewModel+Companion.swift (projectAvatar: creature and
//               body colour, shared with the desktop companion and the pill)
// Used by: Sources/App/Views/HomeView.swift, Sources/App/Views/ProjectContextSidebar.swift,
//          Sources/App/Views/ProjectSwitcherView.swift, Sources/App/Views/ProjectsSidebarView.swift,
//          Sources/App/Views/ProjectSettingsSheet.swift and the project lists and calendar views
// Notes: Projects have no colour of their own; this creature is what identifies them. A project
//        without a creature of its own shows a Blob, General the home companion, since General is
//        home. The avatar colour tints the body only; eyes, headphones and other details keep
//        their colours (MascotCanvas). `pixelSize` 1 gives a 12 by 16 point mark for text rows.

import SwiftUI

struct ProjectAvatarView: View {
    let projectID: UUID
    /// Side of one creature pixel in points; the view is 12 by 16 pixels.
    var pixelSize: CGFloat
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        let look = viewModel.projectAvatar(for: projectID)
        ProjectCreatureMark(avatar: look.avatar, color: look.color, pixelSize: pixelSize)
    }
}

/// A creature, still, for a project that may not be saved yet or outside the app's environment
/// (the settings sheet's preview, the pill).
struct ProjectCreatureMark: View {
    let avatar: MascotAvatar
    /// The body colour; nil: the home companion's (MascotCanvas).
    var color: Color?
    var pixelSize: CGFloat

    var body: some View {
        MascotCanvas(
            frame: AssistantMascotPose.frame(.init(mood: .idle, time: 0.05, look: nil, avatar: avatar, animated: false)),
            avatar: avatar,
            pixelSize: pixelSize,
            bodyColor: color)
            .accessibilityHidden(true)
    }
}
