// Purpose: What the two avatar pickers share: the right click "Delete avatar" with its
//          confirmation, the hint that Claude designs new avatars and the "Restore built-in
//          avatars" button. The pickers lay out their tiles themselves.
// Dependencies: Sources/App/Supporting/MascotAvatarStore.swift (delete, restore, what exists),
//               Sources/App/Supporting/MascotAvatarUsage.swift (who wears an avatar),
//               Sources/App/Supporting/CompanionAppearance.swift (the home companion's choice),
//               Sources/App/ViewModels/AppViewModel.swift (projects, errorMessage)
// Used by: Sources/App/Views/AppearanceSettingsView.swift (the companion's avatar picker),
//          Sources/App/Components/ProjectCompanionChooser.swift (a project's)
// Notes: - Every avatar can be deleted, built-in ones too. The confirmation names the projects
//          and the companion that wear it; they keep their choice and show the Blob.
//        - There is no editing here: avatars are designed and changed by asking Claude.
//        - Restoring asks first only when it would discard edits of built-ins; bringing back
//          deleted ones loses nothing.
//        - The hint shows only while no custom avatar exists.

import SwiftUI

extension View {
    /// Right click on an avatar in a picker: Delete avatar, after a confirmation.
    func avatarDeleteMenu(_ avatar: MascotAvatar) -> some View {
        modifier(AvatarDeleteMenu(avatar: avatar))
    }
}

private struct AvatarDeleteMenu: ViewModifier {
    let avatar: MascotAvatar
    @Environment(AppViewModel.self) private var viewModel
    @State private var isConfirming = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Delete avatar", role: .destructive) { isConfirming = true }
            }
            .confirmationDialog("Delete \u{201C}\(avatar.name)\u{201D}?", isPresented: $isConfirming) {
                Button("Delete Avatar", role: .destructive) {
                    do {
                        try MascotAvatarStore.shared.delete(id: avatar.id)
                    } catch {
                        viewModel.errorMessage = "The avatar could not be deleted: \(error.localizedDescription)"
                    }
                }
            } message: {
                let usage = MascotAvatarUsage(
                    of: avatar.id, projects: viewModel.projects, homeAvatarID: CompanionAppearance.shared.avatarID)
                Text(usage.deleteMessage(isBuiltIn: MascotAvatarCatalog.builtIns.contains { $0.id == avatar.id }))
            }
    }
}

/// One line under an avatar picker while the user has no avatars of their own.
struct AvatarDesignHint: View {
    var body: some View {
        if !MascotAvatarStore.shared.snapshot.hasCustomAvatars {
            Text("Ask Claude to design a new avatar.")
                .font(.themed(.caption))
                .foregroundStyle(.secondary)
        }
    }
}

/// Brings deleted and edited built-in avatars back; shown only while there are any.
struct RestoreBuiltInAvatarsButton: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var isConfirming = false

    var body: some View {
        let snapshot = MascotAvatarStore.shared.snapshot
        if snapshot.canRestoreBuiltIns {
            let edited = MascotAvatarCatalog.builtIns.filter { snapshot.editedBuiltInIDs.contains($0.id) }.map(\.name)
            Button("Restore built-in avatars") {
                if edited.isEmpty { restore() } else { isConfirming = true }
            }
            .controlSize(.small)
            .confirmationDialog("Restore built-in avatars?", isPresented: $isConfirming) {
                Button("Restore", role: .destructive, action: restore)
            } message: {
                Text("\(edited.formatted(.list(type: .and))) \(edited.count == 1 ? "goes" : "go") back to the original drawing; the changes are lost. Avatars you added stay.")
            }
        }
    }

    private func restore() {
        do {
            try MascotAvatarStore.shared.restoreBuiltIns()
        } catch {
            viewModel.errorMessage = "The built-in avatars could not be restored: \(error.localizedDescription)"
        }
    }
}
