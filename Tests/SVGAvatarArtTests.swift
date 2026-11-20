// Purpose: Tests for avatars of kind "svg": reading and writing the format, what the checks accept
//          and refuse (external references, scripts, event attributes, wrong viewBox, broken XML,
//          too many frames), which drawing and props the renderer picks per mood, and that a
//          drawing renders. With MM_SVG_AVATAR_SHEET=<file.png> the sample's mood sheet is written
//          there to look at.
// Dependencies: Sources/App/Supporting/SVGAvatarArt.swift, Sources/App/Supporting/MascotAvatarFile.swift,
//               Sources/App/Supporting/MascotAvatarValidator.swift, Sources/App/Supporting/SVGCreatureRenderer.swift,
//               Sources/App/Supporting/SVGAvatarImageCache.swift, Sources/App/Views/AvatarMoodSheet.swift

import Foundation
import Testing

@testable import MinuteMindApp

@MainActor
@Suite("SVG avatar Tests")
struct SVGAvatarArtTests {
    /// A smooth fox: body in currentColor, white muzzle, dark eyes.
    static let body = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 130">
      <defs><radialGradient id="shine" cx="0.35" cy="0.3" r="0.8"><stop offset="0" stop-color="#fff" stop-opacity="0.35"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient></defs>
      <path d="M22 30 L34 6 L48 28 Z M98 30 L86 6 L72 28 Z" fill="currentColor" stroke="#3a1f0f" stroke-width="3" stroke-linejoin="round"/>
      <ellipse cx="60" cy="72" rx="44" ry="50" fill="currentColor" stroke="#3a1f0f" stroke-width="3"/>
      <ellipse cx="60" cy="72" rx="44" ry="50" fill="url(#shine)"/>
      <path d="M30 84 Q60 120 90 84 Q60 98 30 84 Z" fill="#fff8ef"/>
      <circle cx="44" cy="64" r="6" fill="#1b1b1b"/><circle cx="76" cy="64" r="6" fill="#1b1b1b"/>
      <ellipse cx="60" cy="86" rx="5" ry="3.5" fill="#1b1b1b"/>
      <ellipse cx="44" cy="126" rx="10" ry="4" fill="#3a1f0f"/><ellipse cx="76" cy="126" rx="10" ry="4" fill="#3a1f0f"/>
    </svg>
    """

    static let anchors: [String: Any] = [
        "eyes": [[44, 64], [76, 64]], "eyeSize": 6, "mouth": [60, 94],
        "hands": [[14, 92], [106, 92]], "top": [60, 22], "feet": [60, 128],
    ]

    static var fox: [String: Any] {
        ["id": "fox", "name": "Fox", "kind": "svg", "bodyColor": "#E8762C", "svg": ["body": body, "anchors": anchors]]
    }

    private func issues(_ object: [String: Any]) -> [String] {
        do {
            _ = try MascotAvatarValidator.validated(object)
            return []
        } catch let failure as MascotAvatarValidator.Failure {
            return failure.issues
        } catch {
            return ["\(error)"]
        }
    }

    private func withBody(_ svg: String) -> [String: Any] {
        var object = Self.fox
        object["svg"] = ["body": svg, "anchors": Self.anchors]
        return object
    }

    @Test func acceptsASmoothFoxAndRoundTrips() throws {
        let file = try MascotAvatarValidator.validated(Self.fox)
        #expect(file.isSVG)
        #expect(file.avatar.kind == .svg)
        #expect(file.avatar.art?.anchors.eyes.count == 2)
        let again = try MascotAvatarValidator.validated(file.jsonObject)
        #expect(again == file)
    }

    @Test func refusesAnythingThatReachesOutsideOrRunsCode() {
        let open = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 130">"#
        #expect(issues(withBody(open + #"<image href="https://example.com/a.png" width="10" height="10"/></svg>"#)).contains { $0.contains("<image>") })
        #expect(issues(withBody(open + "<script>alert(1)</script></svg>")).contains { $0.contains("<script>") })
        #expect(issues(withBody(open + #"<circle cx="5" cy="5" r="5" onclick="x()"/></svg>"#)).contains { $0.contains("event handlers") })
        #expect(issues(withBody(open + #"<use href="other.svg#a"/></svg>"#)).contains { $0.contains("points outside") })
        #expect(issues(withBody(open + #"<rect width="5" height="5" fill="url(http://x/y)"/></svg>"#)).contains { $0.contains("url(") })
        #expect(issues(withBody(open + "<style>@import url(x.css);</style></svg>")).contains { $0.contains("@import") })
    }

    @Test func refusesBrokenDrawings() {
        #expect(issues(withBody(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"/>"#)).contains { $0.contains("viewBox") })
        #expect(issues(withBody(#"<svg viewBox="0 0 120 130"><text>a < b</text></svg>"#)).contains { $0.contains("well-formed") })
        var tooMany = Self.fox
        tooMany["svg"] = ["body": Self.body, "anchors": Self.anchors,
                          "moods": ["waiting": ["frames": Array(repeating: Self.body, count: 9), "fps": 4]]]
        #expect(issues(tooMany).contains { $0.contains("at most 8") })
        var unknown = Self.fox
        unknown["svg"] = ["body": Self.body, "anchors": Self.anchors, "moods": ["dancing": ["frames": [Self.body]]]]
        #expect(issues(unknown).contains { $0.contains("not a mood") })
    }

    @Test func rendererUsesOwnFramesAndFallsBackToProps() throws {
        var art = try #require(try MascotAvatarValidator.validated(Self.fox).svg)
        var pose = CreaturePose(mood: .working, time: 0.1)
        #expect(SVGCreatureRenderer.frame(pose, art: art).props.contains { if case .laptop = $0 { true } else { false } })
        art.moods["working"] = .init(frames: [Self.body, Self.body], fps: 4)
        #expect(SVGCreatureRenderer.frame(pose, art: art).drawing == .mood("working", 0))
        #expect(SVGCreatureRenderer.frame(pose, art: art).props.isEmpty)
        pose.time = 0.3
        #expect(SVGCreatureRenderer.frame(pose, art: art).drawing == .mood("working", 1))

        pose.mood = .waiting
        let waiting = SVGCreatureRenderer.frame(pose, art: art)
        #expect(waiting.bubble == .attention)
        pose.headphones = true
        #expect(SVGCreatureRenderer.frame(pose, art: art).props.contains(.headphones))
    }

    @Test func drawingsRenderAndTakeTheBodyColour() throws {
        let art = try #require(try MascotAvatarValidator.validated(Self.fox).svg)
        let image = try #require(SVGAvatarImageCache.shared.image(art: art, drawing: .body, color: 0xE8762C, pixelWidth: 120))
        #expect(image.width == 120 && image.height == 130)
        #expect(SVGAvatarImageCache.tinted(#"<svg color="red" viewBox="0 0 1 1"/>"#, color: 0x00FF00)
            == ##"<svg color="#00FF00" viewBox="0 0 1 1"/>"##)
    }

    @Test("Mood sheet of the sample", .enabled(if: ProcessInfo.processInfo.environment["MM_SVG_AVATAR_SHEET"] != nil))
    func moodSheet() throws {
        let avatar = try MascotAvatarValidator.validated(Self.fox).avatar
        let png = try #require(AvatarMoodSheet.png(of: avatar))
        try png.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["MM_SVG_AVATAR_SHEET"]!))
    }
}
