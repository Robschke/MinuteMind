// Purpose: Tests for the avatar file format and its validator: every built-in passes, the face
//          zones come out of the pose code as expected, and each kind of mistake is named in
//          words that say where it is.
// Dependencies: Sources/App/Supporting/MascotAvatarValidator.swift, Sources/App/Supporting/
//               MascotAvatarFile.swift, Sources/App/Supporting/MascotAvatarCatalog.swift,
//               Sources/App/Supporting/AssistantMascotPose.swift (mouthArea)

import Foundation
import Testing

@testable import MinuteMindApp

@Suite("MascotAvatarValidator Tests")
struct MascotAvatarValidatorTests {
    /// A plain custom avatar: the Blob's body under another id.
    static func fox(id: String = "red-fox") -> MascotAvatarFile {
        MascotAvatarFile(
            id: id, name: "Red Fox", rows: MascotAvatar.blob.rows, bodyColor: "#E0703A",
            featureColor: "#FFFFFF", neutralMouth: [[5, 9], [6, 9]])
    }

    private static func replacing(_ rows: [String], x: Int, y: Int, with character: Character) -> [String] {
        var rows = rows
        var row = Array(rows[y])
        row[x] = character
        rows[y] = String(row)
        return rows
    }

    @Test("Every built-in passes the validator, as a file and after a round trip through JSON")
    func builtInsPass() throws {
        for avatar in MascotAvatarCatalog.builtIns {
            let file = MascotAvatarFile(avatar)
            #expect(MascotAvatarValidator.issues(in: file) == [], "\(avatar.id)")
            let data = try JSONSerialization.data(withJSONObject: file.jsonObject)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let read = try MascotAvatarValidator.validated(object)
            #expect(read == file)
            #expect(read.avatar == avatar, "\(avatar.id) keeps its traits and its name")
        }
    }

    @Test("The face zones are read from the pose code")
    func faceZones() {
        let zones = FaceZones()
        func part(_ x: Int, _ y: Int) -> FaceZones.Part? { zones.spots.first { $0.x == x && $0.y == y }?.part }
        // Open eyes at x 4 and 7 in rows 6 and 7, one pixel each way when they look around.
        #expect(part(4, 6) == .eyes && part(7, 7) == .eyes && part(3, 5) == .eyes && part(8, 8) == .eyes)
        // The happy eyes reach out to x 2 and 9.
        #expect(part(2, 7) == .eyes && part(9, 7) == .eyes)
        #expect(part(2, 8) == .cheeks && part(9, 8) == .cheeks)
        #expect(part(5, 9) == .mouth && part(3, 9) == .mouth && part(7, 10) == .mouth)
        // Arms, headphones, the laptop's base and the thumb are no part of the face.
        #expect(part(11, 4) == nil && part(0, 5) == nil && part(2, 11) == nil && part(9, 3) == nil)
        #expect(zones.spots.allSatisfy { (2...9).contains($0.x) && (5...10).contains($0.y) })
        #expect(zones.headTopRow == 1 && zones.feetRow == 12)
        #expect(zones.spots.first { $0.x == 3 && $0.y == 5 }?.moods.contains("error") == true)

        let area = AssistantMascotPose.mouthArea.map { "\($0.x),\($0.y)" }
        #expect(area == ["3,9", "4,9", "5,9", "6,9", "7,9", "8,9", "4,10", "5,10", "6,10", "7,10"])
    }

    @Test("An avatar with shades needs the body under them filled too")
    func traitZones() {
        let plain = FaceZones()
        let shaded = FaceZones(wearsShades: true)
        #expect(!plain.spots.contains { $0.y == 3 })
        #expect(shaded.spots.contains { $0.x == 2 && $0.y == 3 } && shaded.spots.contains { $0.x == 9 && $0.y == 4 })
    }

    @Test("A wrong size or a foreign ink is named with its row")
    func shape() {
        var file = Self.fox()
        file.rows.removeLast()
        #expect(MascotAvatarValidator.issues(in: file).contains { $0.contains("has 12 rows") && $0.contains("exactly 13") })

        file = Self.fox()
        file.rows[3] = ".obhhbbbbbo"
        #expect(MascotAvatarValidator.issues(in: file).contains { $0.contains("Row y 3") && $0.contains("11 characters") })

        file = Self.fox()
        file.rows = Self.replacing(file.rows, x: 5, y: 4, with: "k")
        let issues = MascotAvatarValidator.issues(in: file)
        #expect(issues.count == 1)
        #expect(issues.first?.contains("Row y 4 has \"k\" at x 5") == true)
    }

    @Test("A face pixel on the outline or in empty space names the pixel, the part and the moods")
    func faceOutsideTheBody() {
        var file = Self.fox()
        file.rows = Self.replacing(file.rows, x: 9, y: 7, with: "o")
        var issues = MascotAvatarValidator.issues(in: file)
        #expect(issues.count == 1)
        let issue = issues.first ?? ""
        #expect(issue.contains("Pixel (x 9, y 7) is outline") && issue.contains("eyes") && issue.contains("celebrating") && issue.contains("thumb up"))

        file = Self.fox()
        file.rows = Self.replacing(file.rows, x: 2, y: 8, with: ".")
        issues = MascotAvatarValidator.issues(in: file)
        #expect(issues.count == 1)
        #expect(issues.first?.contains("Pixel (x 2, y 8) is empty") == true && issues.first?.contains("cheeks") == true)

        file = Self.fox()
        file.rows = Self.replacing(file.rows, x: 4, y: 10, with: "o")
        #expect(MascotAvatarValidator.issues(in: file).first?.contains("mouths are drawn there") == true)
    }

    @Test("Head and feet have to reach their rows")
    func headAndFeet() {
        var file = Self.fox()
        file.rows[12] = "............"
        #expect(MascotAvatarValidator.issues(in: file).contains { $0.contains("Row y 12 is empty") })
        file = Self.fox()
        file.rows[1] = "............"
        #expect(MascotAvatarValidator.issues(in: file).contains { $0.contains("Row y 1 is empty") })
    }

    @Test("The neutral mouth stays inside the mouth area")
    func neutralMouth() {
        var file = Self.fox()
        file.neutralMouth = [[5, 9], [5, 8]]
        let issues = MascotAvatarValidator.issues(in: file)
        #expect(issues.count == 1)
        #expect(issues.first?.contains("(x 5, y 8)") == true && issues.first?.contains("y 9: x 3, 4, 5, 6, 7, 8") == true)
        file.neutralMouth = []
        #expect(MascotAvatarValidator.issues(in: file) == [])
    }

    @Test("Colours are #RRGGBB, the body colour may be missing")
    func colours() {
        var file = Self.fox()
        file.bodyColor = nil
        #expect(MascotAvatarValidator.issues(in: file) == [])
        #expect(file.avatar.naturalBody == nil)
        file.bodyColor = "orange"
        file.featureColor = "#FFF"
        let issues = MascotAvatarValidator.issues(in: file)
        #expect(issues.count == 2)
        #expect(issues.contains { $0.contains("\"bodyColor\" is \"orange\"") } && issues.contains { $0.contains("\"featureColor\" is \"#FFF\"") })
        #expect(MascotAvatarFile.color("#1a2B3c") == 0x1A2B3C && MascotAvatarFile.hex(0x1A2B3C) == "#1A2B3C")
    }

    @Test("An id is a slug, or exactly a built-in's id")
    func ids() {
        for id in ["fox", "red-fox", "fox2"] {
            #expect(MascotAvatarValidator.issues(in: Self.fox(id: id)) == [], "\(id)")
        }
        for id in ["", "Red Fox", "red_fox", "-fox", "fox-", "red--fox", "_hidden", "füchsin", String(repeating: "a", count: 41)] {
            #expect(MascotAvatarValidator.issues(in: Self.fox(id: id)).count == 1, "\(id)")
        }
        #expect(MascotAvatarValidator.issues(in: Self.fox(id: "coolCat")) == [])
        #expect(MascotAvatarValidator.issues(in: Self.fox(id: "coolcat")).first?.contains("\"coolCat\"") == true)
    }

    @Test("An edit of a built-in keeps its name and traits")
    func builtInEdit() {
        var file = MascotAvatarFile(MascotAvatar.lime)
        file.name = "Lemon"
        file.bodyColor = "#F4E04D"
        #expect(MascotAvatarValidator.issues(in: file) == [])
        let avatar = file.avatar
        #expect(avatar.name == "Lime" && avatar.nubs.isEmpty && avatar.naturalBody == 0xF4E04D)
        #expect(MascotAvatarFile(MascotAvatar.coolCat).avatar.wearsShades)
        #expect(MascotAvatarFile(MascotAvatar.sweetCat).avatar.isContent)
        #expect(Self.fox().avatar.nubs.count == 2)
    }

    @Test("A draft with missing or mistyped fields lists them all at once")
    func reading() {
        let object: [String: Any] = ["id": "fox", "rows": "nope", "featureColor": 3, "neutralMouth": [[1.5, 2]]]
        do {
            _ = try MascotAvatarValidator.validated(object)
            Issue.record("the draft should not pass")
        } catch let failure as MascotAvatarValidator.Failure {
            let text = failure.issues.joined(separator: "\n")
            #expect(text.contains("\"name\" is missing"))
            #expect(text.contains("\"rows\" must be a list"))
            #expect(text.contains("\"featureColor\" must be a string"))
            #expect(text.contains("\"neutralMouth\" must be a list"))
            #expect(failure.issues.count == 4, "each field is reported once")
            #expect(failure.localizedDescription.contains("4 issues"))
        } catch {
            Issue.record("unexpected error \(error)")
        }

        var good = Self.fox().jsonObject
        good["kind"] = nil
        good["formatVersion"] = nil
        good["bodyColor"] = nil
        #expect((try? MascotAvatarValidator.validated(good)) != nil, "kind, formatVersion and bodyColor have defaults")
        good["kind"] = "vector"
        good["formatVersion"] = 2
        #expect((try? MascotAvatarValidator.validated(good)) == nil)
    }
}
