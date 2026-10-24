// Generates AppIcon.iconset PNGs from the vector mark in Sources/GlanceKit/App/BrandMark.swift.
// Build together with it:
//   swiftc -parse-as-library Resources/make_icon.swift Sources/GlanceKit/App/BrandMark.swift -o make_icon
//   ./make_icon <dir>/AppIcon.iconset
import AppKit

@main
enum MakeIcon {
    static func main() throws {
        let dir = CommandLine.arguments[1]
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
                try render(pt * scale).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
            }
        }
    }

    /// Renders at an exact pixel size (independent of the screen's backing scale).
    static func render(_ px: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        BrandMark.drawAppIcon(in: g.cgContext, side: CGFloat(px))
        g.flushGraphics()
        return rep.representation(using: .png, properties: [:])!
    }
}
