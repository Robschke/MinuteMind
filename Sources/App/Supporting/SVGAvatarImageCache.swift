// Purpose: SVGAvatarImageCache, the bitmaps of svg avatars: each drawing is rendered once per
//          body colour and pixel size and kept, so a creature animating at 8 frames a second only
//          blits images it already has.
// Dependencies: Sources/App/Supporting/SVGAvatarArt.swift, AppKit (NSImage draws SVG)
// Used by: Sources/App/Views/SVGCreatureCanvas.swift
// Notes: - The body colour reaches the drawing as `currentColor`: the root element gets a
//          `color` attribute (an existing one is replaced) before macOS parses it.
//        - Keys hold the avatar's content hash, so an avatar Claude edits is drawn fresh at once.
//        - The cache is cleared whole when it grows past `limit`; a few dozen creatures in a few
//          sizes stay far below it, so this only matters after many edits.

import AppKit
import Foundation

@MainActor
final class SVGAvatarImageCache {
    static let shared = SVGAvatarImageCache()

    private var images: [String: CGImage] = [:]
    private let limit = 600

    /// The drawing rendered `pixelWidth` pixels wide (its height follows the 120 x 130 viewBox),
    /// nil when it cannot be drawn.
    func image(art: SVGAvatarArt, drawing: SVGCreatureFrame.Drawing, color: UInt32, pixelWidth: Int) -> CGImage? {
        let key = "\(art.hashValue)|\(drawing)|\(color)|\(pixelWidth)"
        if let image = images[key] { return image }
        guard let svg = Self.document(art: art, drawing: drawing), pixelWidth > 0 else { return nil }
        let image = Self.render(Self.tinted(svg, color: color), pixelWidth: pixelWidth)
        if images.count >= limit { images.removeAll() }
        images[key] = image
        return image
    }

    static func document(art: SVGAvatarArt, drawing: SVGCreatureFrame.Drawing) -> String? {
        switch drawing {
        case .body:
            return art.body
        case .mood(let name, let index):
            guard let frames = art.moods[name]?.frames, frames.indices.contains(index) else { return art.body }
            return frames[index]
        }
    }

    /// Sets `color` on the root <svg> element, the value `currentColor` takes.
    static func tinted(_ svg: String, color: UInt32) -> String {
        guard let start = svg.range(of: "<svg"), let end = svg[start.upperBound...].firstIndex(of: ">") else { return svg }
        var tag = String(svg[start.upperBound..<end])
        tag = tag.replacingOccurrences(of: #"\scolor\s*=\s*("[^"]*"|'[^']*')"#, with: "", options: .regularExpression)
        return svg[..<start.lowerBound] + "<svg color=\"" + String(format: "#%06X", color) + "\"" + tag + svg[end...]
    }

    static func render(_ svg: String, pixelWidth: Int) -> CGImage? {
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        let pixelHeight = Int((Double(pixelWidth) * SVGAvatarArt.height / SVGAvatarArt.width).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return rep.cgImage
    }
}
