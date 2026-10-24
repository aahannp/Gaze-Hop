// Draws the DMG window background (an arrow between the app and Applications) at 1x and 2x.
//   swift Resources/make_dmg_background.swift <out-dir>      -> background.png, background@2x.png
import AppKit

func render(scale: CGFloat, to path: String) {
    let w = 540, h = 380
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(CGFloat(w) * scale), pixelsHigh: Int(CGFloat(h) * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    NSGradient(colors: [NSColor(white: 0.97, alpha: 1), NSColor(white: 0.90, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

    let title = NSAttributedString(string: "Drag GazeHop to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor(white: 0.25, alpha: 1)])
    title.draw(at: NSPoint(x: (CGFloat(w) - title.size().width) / 2, y: 312))

    // Arrow at icon height (icons sit at y=190 from the top => 190 from the bottom of this 380 canvas).
    ctx.setStrokeColor(NSColor(white: 0.45, alpha: 1).cgColor)
    ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let y: CGFloat = 190, x0: CGFloat = 215, x1: CGFloat = 325
    ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x1, y: y)); ctx.strokePath()
    ctx.move(to: CGPoint(x: x1 - 18, y: y + 18)); ctx.addLine(to: CGPoint(x: x1, y: y)); ctx.addLine(to: CGPoint(x: x1 - 18, y: y - 18))
    ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
render(scale: 1, to: "\(out)/background.png")
render(scale: 2, to: "\(out)/background@2x.png")
