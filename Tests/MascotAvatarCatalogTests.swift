// Purpose: Tests for the avatar catalog and the rendering entry point: the built-in ids that
//          projects and settings store, what an unknown id resolves to, and that a pixel avatar's
//          frame comes from the pixel renderer.
// Dependencies: Sources/App/Supporting/MascotAvatarCatalog.swift, Sources/App/Supporting/
//               MascotAvatar.swift, Sources/App/Supporting/CreatureRenderer.swift,
//               Sources/App/Models/Project.swift (companionCreature)

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("MascotAvatarCatalog Tests")
struct MascotAvatarCatalogTests {
    @Test("The built-in ids are the stored ones, in the pickers' order")
    func builtInIDs() {
        let ids = ["blob", "duck", "dog", "puppy", "pug", "cat", "coolCat", "sweetCat", "lime"]
        #expect(MascotAvatarCatalog.builtIns.map(\.id) == ids)
        #expect(MascotAvatarCatalog.all.map(\.id) == ids)
        #expect(MascotAvatar.coolCat.id == "coolCat" && MascotAvatar.sweetCat.id == "sweetCat")
    }

    @Test("An id resolves to its avatar, an unknown one to the Blob")
    func resolving() {
        #expect(MascotAvatarCatalog.avatar(id: "duck") == .duck)
        #expect(MascotAvatarCatalog.avatar(id: "dragon") == nil)
        #expect(MascotAvatarCatalog.avatar(id: "") == nil)
        #expect(MascotAvatarCatalog.resolve("lime") == .lime)
        #expect(MascotAvatarCatalog.resolve("dragon") == .blob)
        #expect(MascotAvatarCatalog.resolve("") == .blob)
    }

    @Test("A project's stored id gives its creature: none without one, the Blob for an unknown one")
    func projectCreature() {
        var project = Project(name: "Atlas")
        #expect(project.companionCreature == nil)
        project.companionAvatar = "pug"
        #expect(project.companionCreature == .pug)
        project.companionAvatar = "dragon"
        #expect(project.companionCreature == .blob)
        #expect(project.companionAvatar == "dragon", "the stored id is kept")
    }

    @Test("Avatars are equal when they are drawn the same")
    func equality() {
        #expect(MascotAvatar.cat == MascotAvatar.cat)
        #expect(MascotAvatar.cat != MascotAvatar.coolCat)
        let recoloured = MascotAvatar(
            id: "cat", name: "Cat", rows: MascotAvatar.cat.rows, naturalBody: 0x123456,
            featureColor: MascotAvatar.cat.featureColor, neutralMouth: MascotAvatar.cat.neutralMouth)
        #expect(recoloured != MascotAvatar.cat)
        #expect(Set([MascotAvatar.cat, .cat, .duck]).count == 2)
    }

    @Test("Every built-in is a pixel avatar and is drawn by the pixel renderer")
    func rendererByKind() {
        for avatar in MascotAvatarCatalog.builtIns {
            #expect(avatar.kind == .pixel)
            let pose = CreaturePose(mood: .waiting, time: 0.3, look: nil, avatar: avatar)
            let frame = CreatureRenderer.frame(pose)
            #expect(frame == .pixel(AssistantMascotPose.frame(pose)))
            #expect(frame.bubble == .attention)
        }
        #expect(CreatureCanvas.size(unit: 3) == CGSize(width: 36, height: 48))
    }
}
