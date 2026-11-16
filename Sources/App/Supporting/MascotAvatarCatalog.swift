// Purpose: MascotAvatarCatalog, the list of every avatar a creature can be and the one place
//          that turns a stored id back into an avatar.
// Dependencies: Sources/App/Supporting/MascotAvatar.swift (the avatars and the built-in ones)
// Used by: Sources/App/Models/Project.swift (companionCreature), Sources/App/Supporting/
//          CompanionAppearance.swift (the home companion's avatar), Sources/App/Supporting/
//          CompanionCast.swift (firstFreeAvatar), Sources/App/Help/AppSettingsCatalog.swift,
//          the pickers (Sources/App/Views/AppearanceSettingsView.swift, Sources/App/Components/
//          ProjectCompanionChooser.swift, Sources/App/Views/ProjectsSidebarView.swift)
// Notes: Everything that lists avatars or reads a stored id goes through here, never through
//        the built-in instances, so avatars from another source join by being added to `all`.
//        An id nobody knows resolves to the Blob: a project or a setting always has a creature
//        to show, whatever was stored.

import Foundation

enum MascotAvatarCatalog {
    /// The avatars that ship with the app, in the pickers' order.
    static let builtIns: [MascotAvatar] = [.blob, .duck, .dog, .puppy, .pug, .cat, .coolCat, .sweetCat, .lime]

    /// The avatar shown for an id the catalog does not know.
    static let fallback = MascotAvatar.blob

    /// Every avatar that can be chosen, in the pickers' order.
    static var all: [MascotAvatar] { builtIns }

    /// The avatar with exactly this id, nil when there is none.
    static func avatar(id: String) -> MascotAvatar? {
        all.first { $0.id == id }
    }

    /// The avatar a stored id stands for; the Blob when the id is unknown.
    static func resolve(_ id: String) -> MascotAvatar {
        avatar(id: id) ?? fallback
    }
}
