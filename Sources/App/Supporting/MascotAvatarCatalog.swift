// Purpose: MascotAvatarCatalog, the list of every avatar a creature can be and the one place
//          that turns a stored id back into an avatar.
// Dependencies: Sources/App/Supporting/MascotAvatar.swift (the avatars and the built-in ones),
//               Sources/App/Supporting/MascotAvatarStore.swift (the user's avatars folder)
// Used by: Sources/App/Models/Project.swift (companionCreature), Sources/App/Supporting/
//          CompanionAppearance.swift (the home companion's avatar), Sources/App/Supporting/
//          CompanionCast.swift (firstFreeAvatar), Sources/App/Help/AppSettingsCatalog.swift,
//          the pickers (Sources/App/Views/AppearanceSettingsView.swift, Sources/App/Components/
//          ProjectCompanionChooser.swift, Sources/App/Views/ProjectsSidebarView.swift)
// Notes: Everything that lists avatars or reads a stored id goes through here, never through
//        the built-in instances. The built-ins are only the defaults: the store adds the user's
//        own avatars, swaps in edited built-ins and leaves deleted ones out.
//        An id nobody knows resolves to the original Blob: a project or a setting always has a
//        creature to show, whatever was stored and whatever was deleted.

import Foundation

enum MascotAvatarCatalog {
    /// The avatars that ship with the app, in the pickers' order.
    static let builtIns: [MascotAvatar] = [.blob, .duck, .dog, .puppy, .pug, .cat, .coolCat, .sweetCat, .lime]

    /// The avatar shown for an id the catalog does not know.
    static let fallback = MascotAvatar.blob

    /// Every avatar that can be chosen, in the pickers' order.
    static var all: [MascotAvatar] { MascotAvatarStore.shared.snapshot.avatars }

    /// The avatar with exactly this id, nil when there is none.
    static func avatar(id: String) -> MascotAvatar? {
        MascotAvatarStore.shared.snapshot.avatar(id: id)
    }

    /// The avatar a stored id stands for; the Blob when the id is unknown.
    static func resolve(_ id: String) -> MascotAvatar {
        MascotAvatarStore.shared.snapshot.resolve(id)
    }
}
