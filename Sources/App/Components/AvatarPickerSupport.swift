// Purpose: What the two avatar pickers share: the right click "Delete avatar" with its
//          confirmation, the hint that Claude designs new avatars, the "Restore built-in
//          avatars" button, and a layout that wraps the avatars into even rows.
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
                .font(.caption)
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

/// Lays its subviews out in one row while they fit, else in as few rows as needed, each with
/// the same number of items (the last may be shorter), so the rows look even.
struct BalancedRows: Layout {
    var spacing: CGFloat = 8

    private func rows(_ sizes: [CGSize], width: CGFloat) -> [Range<Int>] {
        guard !sizes.isEmpty else { return [] }
        for rowCount in 1...sizes.count {
            let perRow = Int((Double(sizes.count) / Double(rowCount)).rounded(.up))
            let ranges = stride(from: 0, to: sizes.count, by: perRow).map { $0..<min($0 + perRow, sizes.count) }
            let fits = ranges.allSatisfy { range in
                sizes[range].reduce(0) { $0 + $1.width } + spacing * CGFloat(range.count - 1) <= width
            }
            if fits || perRow == 1 { return ranges }
        }
        return sizes.indices.map { $0..<($0 + 1) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(sizes, width: proposal.width ?? .infinity)
        let widths = rows.map { range in sizes[range].reduce(0) { $0 + $1.width } + spacing * CGFloat(range.count - 1) }
        let heights = rows.map { range in sizes[range].map(\.height).max() ?? 0 }
        return CGSize(
            width: widths.max() ?? 0,
            height: heights.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for range in rows(sizes, width: bounds.width) {
            var x = bounds.minX
            for index in range {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += sizes[index].width + spacing
            }
            y += (sizes[range].map(\.height).max() ?? 0) + spacing
        }
    }
}
