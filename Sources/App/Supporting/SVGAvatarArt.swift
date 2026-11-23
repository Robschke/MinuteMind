// Purpose: SVGAvatarArt, the drawing of an avatar of kind "svg": a body drawing, anchor points
//          (eyes, mouth, hands, top of the head, feet) where the app puts its mood props, and
//          optional frames of its own for any mood. Reads it from JSON, writes it, and checks it.
// Dependencies: AppKit (NSImage checks that each drawing renders), Foundation (XMLParser)
// Used by: Sources/App/Supporting/MascotAvatarFile.swift (the "svg" field of an avatar file),
//          Sources/App/Supporting/MascotAvatarValidator.swift, Sources/App/Supporting/SVGCreatureRenderer.swift,
//          Sources/App/Supporting/SVGAvatarImageCache.swift, Tests/SVGAvatarArtTests.swift
// Notes: - Every drawing uses viewBox "0 0 120 130": the 12 x 13 units a pixel avatar's body
//          covers, ten per unit, so both kinds stand on the same spot of the creature canvas
//          and every layout around them stays the same.
//        - `currentColor` is the body colour (the theme's accent, an own colour or a project's
//          avatar colour); the renderer sets it on the root element.
//        - Checked with an allow list: shapes, text, gradients, patterns, clip paths, masks,
//          filters and CSS are fine; external images, scripts, foreign objects, links, event
//          attributes and references outside the document are refused, so an avatar can never
//          load anything from elsewhere or run code. Sizes are capped so drawing stays cheap.
//        - macOS draws SVG itself (NSImage, macOS 14 and later). SMIL animation is ignored; the
//          app animates (frames per mood, breathing, hops), so the format has no animation tags.

import AppKit
import Foundation

struct SVGAvatarArt: Equatable, Hashable, Sendable {
    static let width: Double = 120
    static let height: Double = 130
    static let viewBox = "0 0 120 130"
    /// Moods an avatar may draw itself. "blink" replaces the closed-eye prop in idle,
    /// "recording" the headphones, "running" the dash to the pointer.
    static let moodNames = [
        "idle", "blink", "sleeping", "working", "waiting", "asking", "dictating", "celebrating",
        "thumbsUp", "error", "running", "recording",
    ]
    static let maxDocumentBytes = 64_000
    static let maxTotalBytes = 400_000
    static let maxFrames = 8
    static let fpsRange: ClosedRange<Double> = 1...12

    struct Point: Equatable, Hashable, Sendable {
        var x: Double
        var y: Double
    }

    /// Where the app's props go, in viewBox coordinates.
    struct Anchors: Equatable, Hashable, Sendable {
        /// Centre of each eye (one or two).
        var eyes: [Point]
        /// Radius of an eye, for the closed-eye prop.
        var eyeSize: Double
        var mouth: Point
        /// Left hand, then right hand.
        var hands: [Point]
        /// Top of the head (headphones).
        var top: Point
        /// Middle between the feet, on the ground.
        var feet: Point
    }

    struct MoodFrames: Equatable, Hashable, Sendable {
        var frames: [String]
        var fps: Double = 4
    }

    var body: String
    var anchors: Anchors
    /// Own frames by mood name (`moodNames`).
    var moods: [String: MoodFrames] = [:]

    /// Every drawing, body first.
    var documents: [String] { [body] + moods.keys.sorted().flatMap { moods[$0]?.frames ?? [] } }

    // MARK: - JSON

    /// Reads the "svg" object of an avatar file; `issues` names what is missing or wrong.
    static func read(_ value: Any?) -> (art: SVGAvatarArt?, issues: [String]) {
        guard let object = value as? [String: Any] else {
            return (nil, [value == nil
                ? "\"svg\" is missing: an avatar of kind \"svg\" needs {\"body\", \"anchors\"} (see get_avatar_rules)."
                : "\"svg\" must be an object with body, anchors and optional moods."])
        }
        var issues: [String] = []
        for key in object.keys.sorted() where !["body", "anchors", "moods"].contains(key) {
            issues.append("\"svg.\(key)\" is not known. Allowed: body, anchors, moods.")
        }
        let body = object["body"] as? String ?? ""
        if object["body"] as? String == nil { issues.append("\"svg.body\" must be an SVG document as a string.") }

        func point(_ raw: Any?, _ path: String) -> Point? {
            guard let pair = raw as? [Any], pair.count == 2,
                  let x = number(pair[0]), let y = number(pair[1]) else {
                issues.append("\"\(path)\" must be [x, y] in viewBox units (0 to 120, 0 to 130).")
                return nil
            }
            return Point(x: x, y: y)
        }
        var anchors = Anchors(eyes: [], eyeSize: 0, mouth: Point(x: 0, y: 0), hands: [], top: Point(x: 0, y: 0), feet: Point(x: 0, y: 0))
        if let raw = object["anchors"] as? [String: Any] {
            for key in raw.keys.sorted() where !["eyes", "eyeSize", "mouth", "hands", "top", "feet"].contains(key) {
                issues.append("\"svg.anchors.\(key)\" is not known. Allowed: eyes, eyeSize, mouth, hands, top, feet.")
            }
            if let list = raw["eyes"] as? [Any], (1...2).contains(list.count) {
                anchors.eyes = list.enumerated().compactMap { point($0.element, "svg.anchors.eyes[\($0.offset)]") }
            } else {
                issues.append("\"svg.anchors.eyes\" must list one or two eye centres, e.g. [[44, 64], [76, 64]].")
            }
            if let size = number(raw["eyeSize"] as Any), size > 0, size <= 30 {
                anchors.eyeSize = size
            } else {
                issues.append("\"svg.anchors.eyeSize\" must be the eye radius, a number from 1 to 30.")
            }
            anchors.mouth = point(raw["mouth"], "svg.anchors.mouth") ?? anchors.mouth
            if let list = raw["hands"] as? [Any], list.count == 2 {
                anchors.hands = list.enumerated().compactMap { point($0.element, "svg.anchors.hands[\($0.offset)]") }
            } else {
                issues.append("\"svg.anchors.hands\" must list the left and the right hand, e.g. [[10, 88], [110, 88]].")
            }
            anchors.top = point(raw["top"], "svg.anchors.top") ?? anchors.top
            anchors.feet = point(raw["feet"], "svg.anchors.feet") ?? anchors.feet
        } else {
            issues.append("\"svg.anchors\" is missing: eyes, eyeSize, mouth, hands, top and feet in viewBox units.")
        }

        var moods: [String: MoodFrames] = [:]
        if let raw = object["moods"] {
            if let table = raw as? [String: Any] {
                for (name, value) in table.sorted(by: { $0.key < $1.key }) {
                    guard moodNames.contains(name) else {
                        issues.append("\"svg.moods.\(name)\" is not a mood. Moods: \(moodNames.joined(separator: ", ")).")
                        continue
                    }
                    guard let entry = value as? [String: Any], let frames = entry["frames"] as? [String], !frames.isEmpty else {
                        issues.append("\"svg.moods.\(name)\" must be {\"frames\": [SVG strings], \"fps\": number}.")
                        continue
                    }
                    var mood = MoodFrames(frames: frames)
                    if let fps = entry["fps"] {
                        if let value = number(fps), fpsRange.contains(value) {
                            mood.fps = value
                        } else {
                            issues.append("\"svg.moods.\(name).fps\" must be from \(Int(fpsRange.lowerBound)) to \(Int(fpsRange.upperBound)).")
                        }
                    }
                    moods[name] = mood
                }
            } else {
                issues.append("\"svg.moods\" must be an object of mood name to {frames, fps}.")
            }
        }
        return (SVGAvatarArt(body: body, anchors: anchors, moods: moods), issues)
    }

    var jsonObject: [String: Any] {
        func pair(_ point: Point) -> [Double] { [point.x, point.y] }
        var object: [String: Any] = [
            "body": body,
            "anchors": [
                "eyes": anchors.eyes.map(pair), "eyeSize": anchors.eyeSize, "mouth": pair(anchors.mouth),
                "hands": anchors.hands.map(pair), "top": pair(anchors.top), "feet": pair(anchors.feet),
            ] as [String: Any],
        ]
        if !moods.isEmpty {
            object["moods"] = moods.mapValues { ["frames": $0.frames, "fps": $0.fps] as [String: Any] }
        }
        return object
    }

    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    // MARK: - Checking

    /// Everything that keeps the drawing from being saved, empty when it is fine.
    func issues() -> [String] {
        var issues: [String] = []
        let total = documents.reduce(0) { $0 + $1.utf8.count }
        if total > Self.maxTotalBytes {
            issues.append("All drawings together are \(total / 1000) KB; at most \(Self.maxTotalBytes / 1000) KB. Simplify paths or use fewer frames.")
        }
        issues += Self.documentIssues(body, path: "svg.body")
        for name in moods.keys.sorted() {
            guard let mood = moods[name] else { continue }
            if mood.frames.count > Self.maxFrames {
                issues.append("\"svg.moods.\(name)\" has \(mood.frames.count) frames; at most \(Self.maxFrames).")
            }
            for (index, frame) in mood.frames.enumerated() {
                issues += Self.documentIssues(frame, path: "svg.moods.\(name).frames[\(index)]")
            }
        }
        func inside(_ point: Point, _ path: String) {
            if !(0...Self.width).contains(point.x) || !(0...Self.height).contains(point.y) {
                issues.append("\"\(path)\" (\(point.x), \(point.y)) is outside the viewBox 0 0 120 130.")
            }
        }
        for (index, eye) in anchors.eyes.enumerated() { inside(eye, "svg.anchors.eyes[\(index)]") }
        inside(anchors.mouth, "svg.anchors.mouth")
        for (index, hand) in anchors.hands.enumerated() { inside(hand, "svg.anchors.hands[\(index)]") }
        inside(anchors.top, "svg.anchors.top")
        inside(anchors.feet, "svg.anchors.feet")
        return issues
    }

    static let allowedElements: Set<String> = [
        "svg", "g", "defs", "symbol", "use", "title", "desc", "style",
        "path", "circle", "ellipse", "rect", "line", "polyline", "polygon", "text", "tspan",
        "linearGradient", "radialGradient", "stop", "pattern", "clipPath", "mask",
        "filter", "feGaussianBlur", "feOffset", "feMerge", "feMergeNode", "feTurbulence",
        "feDisplacementMap", "feColorMatrix", "feBlend", "feFlood", "feComposite", "feMorphology",
        "feDropShadow", "feComponentTransfer", "feFuncR", "feFuncG", "feFuncB", "feFuncA",
    ]

    /// Issues of one SVG document: size, well-formed XML, the viewBox, only allowed elements,
    /// no references outside the document, and that macOS can draw it.
    static func documentIssues(_ svg: String, path: String) -> [String] {
        let bytes = svg.utf8.count
        if bytes > maxDocumentBytes {
            return ["\"\(path)\" is \(bytes / 1000) KB; one drawing may be at most \(maxDocumentBytes / 1000) KB."]
        }
        let scan = SVGScan(Data(svg.utf8))
        if let error = scan.parseError {
            return ["\"\(path)\" is not well-formed XML: \(error). Escape < and & in text as &lt; and &amp;."]
        }
        var issues: [String] = []
        if scan.root != "svg" { issues.append("\"\(path)\" must start with an <svg> element.") }
        let viewBox = scan.rootViewBox?.replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").joined(separator: " ")
        if viewBox != Self.viewBox {
            issues.append("\"\(path)\" must have viewBox=\"\(Self.viewBox)\" (12 x 13 units of ten).")
        }
        for element in scan.elements.sorted() where !allowedElements.contains(element) {
            issues.append("\"\(path)\" uses <\(element)>, which is not allowed. Allowed: shapes, text, gradients, patterns, clip paths, masks, filters and <style>; never images, scripts or foreign objects.")
        }
        issues += scan.problems.map { "\"\(path)\": \($0)" }
        if issues.isEmpty, NSImage(data: Data(svg.utf8)) == nil {
            issues.append("\"\(path)\" could not be drawn by macOS. Keep to plain SVG 1.1 shapes, gradients and filters.")
        }
        return issues
    }
}

/// One pass over an SVG document: the root, every element name, and references or event
/// attributes that would reach outside the drawing.
private final class SVGScan: NSObject, XMLParserDelegate {
    private(set) var root: String?
    private(set) var rootViewBox: String?
    private(set) var elements: Set<String> = []
    private(set) var problems: [String] = []
    private(set) var parseError: String?
    private var inStyle = false

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        if !parser.parse() {
            parseError = parser.parserError?.localizedDescription ?? "unknown error"
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if root == nil {
            root = local
            rootViewBox = attributes["viewBox"]
        }
        elements.insert(local)
        inStyle = local == "style"
        for (key, value) in attributes {
            let attribute = key.lowercased()
            if attribute.hasPrefix("on") {
                note("the attribute \(key) (event handlers) is not allowed.")
            }
            if attribute == "href" || attribute.hasSuffix(":href"), !value.hasPrefix("#") {
                note("\(key)=\"\(value)\" points outside the drawing; only #id references are allowed.")
            }
            checkCSS(value, where: "\(key) on <\(local)>")
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        inStyle = false
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inStyle { checkCSS(string, where: "<style>") }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if inStyle { checkCSS(String(decoding: block, as: UTF8.self), where: "<style>") }
    }

    private func checkCSS(_ text: String, where place: String) {
        let lowered = text.lowercased()
        if lowered.contains("@import") { note("@import in \(place) is not allowed.") }
        var rest = lowered[...]
        while let range = rest.range(of: "url(") {
            let after = rest[range.upperBound...].drop { $0 == " " || $0 == "'" || $0 == "\"" }
            if !after.hasPrefix("#") { note("url(...) in \(place) points outside the drawing; only url(#id) is allowed.") }
            rest = rest[range.upperBound...]
        }
    }

    private func note(_ problem: String) {
        if !problems.contains(problem) { problems.append(problem) }
    }
}
