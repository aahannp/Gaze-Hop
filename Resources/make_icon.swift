// Generates AppIcon.iconset PNGs: white eye glyph on a blue gradient squircle.
import AppKit
let dir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
        let path = NSBezierPath(roundedRect: r.insetBy(dx: s * 0.06, dy: s * 0.06), xRadius: s * 0.22, yRadius: s * 0.22)
        NSGradient(colors: [NSColor(red: 0.20, green: 0.42, blue: 0.95, alpha: 1),
                            NSColor(red: 0.45, green: 0.25, blue: 0.85, alpha: 1)])!.draw(in: path, angle: -60)
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .regular).applying(.init(paletteColors: [.white]))
        if let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let es = eye.size
            eye.draw(in: NSRect(x: (s - es.width) / 2, y: (s - es.height) / 2, width: es.width, height: es.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256),
                   ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    try render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name.replacingOccurrences(of: "@2x", with: ""))x\(name.replacingOccurrences(of: "@2x", with: ""))\(name.hasSuffix("@2x") ? "@2x" : "").png"))
}
