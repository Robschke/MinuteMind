// Purpose: MascotAvatarUsage, who wears an avatar (which projects, and whether the home
//          companion does), and the words the delete confirmation says about it.
// Dependencies: Sources/App/Models/Project.swift (companionAvatar)
// Used by: Sources/App/Components/AvatarPickerSupport.swift (the delete confirmation),
//          Sources/App/Services/MCP/MCPAvatarTools.swift (list_avatars, delete_avatar),
//          Tests/MascotAvatarUsageTests.swift
// Notes: Usage goes by the stored id, not by the creature shown: a project whose avatar was
//        deleted shows the Blob but does not count as a user of the Blob.

import Foundation

struct MascotAvatarUsage: Equatable, Sendable {
    /// The projects that wear the avatar, in the order given.
    var projectNames: [String] = []
    var isHomeCompanion = false

    var isUsed: Bool { isHomeCompanion || !projectNames.isEmpty }

    init(of avatarID: String, projects: [Project], homeAvatarID: String) {
        projectNames = projects.filter { $0.companionAvatar == avatarID }.map(\.name)
        isHomeCompanion = homeAvatarID == avatarID
    }

    /// Who wears it, as the start of a sentence: "Atlas, Beta and your companion"; nil when
    /// nobody does.
    var wearers: String? {
        let names = projectNames + (isHomeCompanion ? ["your companion"] : [])
        guard let last = names.last else { return nil }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The delete confirmation's message.
    func deleteMessage(isBuiltIn: Bool) -> String {
        var sentences: [String] = []
        if let wearers {
            let single = projectNames.count + (isHomeCompanion ? 1 : 0) == 1
            sentences.append("\(wearers.prefix(1).uppercased() + wearers.dropFirst()) \(single ? "uses" : "use") this avatar and will show the Blob instead.")
        }
        sentences.append(isBuiltIn
            ? "You can bring it back with Restore built-in avatars in Settings > Appearance."
            : "This cannot be undone.")
        return sentences.joined(separator: " ")
    }
}
