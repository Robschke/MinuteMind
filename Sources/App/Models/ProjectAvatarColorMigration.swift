// Purpose: ProjectAvatarColorMigration, turning the project colours of files written before
//          avatar colours into avatar colours, once, so every creature keeps the look it had.
// Dependencies: Sources/App/Models/Project.swift (legacyColorHex, avatarColorHex, isOrderedBefore),
//               Sources/App/Supporting/MascotAvatar.swift
// Used by: Sources/App/ViewModels/AppViewModel.swift (right after loading projects.json)
// Notes: The old project colour was visible on the creature only in some cases, and only there it
//        becomes the avatar colour: a project without a creature of its own (drawn as a Blob in
//        its colour), a Blob, a creature the home companion wears, and a creature an earlier
//        project in the sidebar order already wears. Every other creature showed its natural
//        colour and keeps it (Default). Pure and unit tested (Tests/ProjectAvatarColorTests.swift).

import Foundation

enum ProjectAvatarColorMigration {
    /// The projects with every old project colour resolved, or nil when none had one.
    static func migrated(_ projects: [Project], homeAvatar: MascotAvatar) -> [Project]? {
        guard projects.contains(where: { $0.legacyColorHex != nil }) else { return nil }
        let ordered = projects.sorted(by: Project.isOrderedBefore)
        return projects.map { project in
            guard let legacy = project.legacyColorHex else { return project }
            var migrated = project
            migrated.legacyColorHex = nil
            if showedProjectColor(project, among: ordered, homeAvatar: homeAvatar) {
                migrated.avatarColorHex = legacy
            }
            return migrated
        }
    }

    /// Whether the creature was drawn in the project colour before avatar colours existed.
    static func showedProjectColor(_ project: Project, among ordered: [Project], homeAvatar: MascotAvatar) -> Bool {
        guard let avatar = project.companionCreature else { return true }
        if avatar == .blob || avatar == homeAvatar { return true }
        for other in ordered {
            if other.id == project.id { return false }
            if other.companionCreature == avatar { return true }
        }
        return false
    }
}
