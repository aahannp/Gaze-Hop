import AppKit

/// GazeHop's mark, drawn in code: two panes, with the gaze hopping (a dotted arc) onto the right
/// one, which holds the eye. Uses AppKit/CoreGraphics only, so Resources/make_icon.swift can compile
/// this file on its own to render the .icns.
enum BrandMark {
    enum Glyph { case tracking, paused, calibrating }

    // MARK: App icon

    /// The app icon on Apple's 1024 grid: an 824-unit continuous-corner tile with a soft drop shadow.
    /// Draws into `ctx` over a `side` × `side` square. Below ~64 px it drops the fine details.
    static func drawAppIcon(in ctx: CGContext, side: CGFloat) {
        let k = side / 1024
        let pixels = side * abs(ctx.userSpaceToDeviceSpaceTransform.a)
        ctx.saveGState()
        ctx.scaleBy(x: k, y: k)
        drawIcon(ctx, shadowScale: pixels / 1024, small: pixels <= 64)
        ctx.restoreGState()
    }

    /// The app icon as an image (for SwiftUI/AppKit views), redrawn at whatever scale it's shown.
    static func appIcon(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawAppIcon(in: ctx, side: r.width)
            return true
        }
        img.accessibilityDescription = "GazeHop"
        return img
    }

    private static let top = color(0x4F9BFF), bottom = color(0x5B34D6), ink = color(0x0D1240)
    private static let body = CGRect(x: 100, y: 100, width: 824, height: 824)

    private static func drawIcon(_ ctx: CGContext, shadowScale k: CGFloat, small: Bool) {
        // Tile: shadow, diagonal gradient, top sheen, hairline rim.
        let tile = continuousRect(body, radius: 185.4)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 22 * k, color: color(0, 0.32))
        ctx.addPath(tile); ctx.setFillColor(bottom); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(tile); ctx.clip()
        ctx.drawLinearGradient(gradient(top, bottom), start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.drawLinearGradient(gradient(color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)),
                               start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
        ctx.restoreGState()
        ctx.addPath(continuousRect(body.insetBy(dx: 2, dy: 2), radius: 183.4))
        ctx.setStrokeColor(color(0xFFFFFF, 0.18)); ctx.setLineWidth(4); ctx.strokePath()

        // Two panes; small sizes get bigger panes and no hop arc.
        let w: CGFloat = small ? 300 : 272, h: CGFloat = small ? 420 : 348, gap: CGFloat = small ? 64 : 84
        let y: CGFloat = small ? 302 : 240
        let left = CGRect(x: 512 - gap / 2 - w, y: y, width: w, height: h)
        let right = CGRect(x: 512 + gap / 2, y: y, width: w, height: h)

        ctx.addPath(roundedRect(left, 64)); ctx.setFillColor(color(0xFFFFFF, 0.16)); ctx.fillPath()
        ctx.addPath(roundedRect(left.insetBy(dx: small ? 15 : 9, dy: small ? 15 : 9), small ? 50 : 56))
        ctx.setStrokeColor(color(0xFFFFFF, 0.6)); ctx.setLineWidth(small ? 30 : 18); ctx.strokePath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * k), blur: 24 * k, color: color(0x1A0B5C, 0.35))
        ctx.addPath(roundedRect(right, 64)); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(right, 64)); ctx.clip()
        ctx.drawLinearGradient(gradient(color(0xFFFFFF), color(0xE6EAFF)), start: CGPoint(x: 0, y: right.maxY),
                               end: CGPoint(x: 0, y: right.minY), options: [])
        ctx.restoreGState()

        // The eye in the focused pane: gradient iris, dark pupil, catch-light.
        let c = CGPoint(x: right.midX, y: right.midY), ir: CGFloat = small ? 104 : 86
        ctx.saveGState()
        ctx.addEllipse(in: circle(c, ir)); ctx.clip()
        ctx.drawLinearGradient(gradient(top, bottom), start: CGPoint(x: c.x, y: c.y + ir),
                               end: CGPoint(x: c.x, y: c.y - ir), options: [])
        ctx.restoreGState()
        ctx.addEllipse(in: circle(c, ir * 0.46)); ctx.setFillColor(ink); ctx.fillPath()
        if !small {
            ctx.addEllipse(in: circle(CGPoint(x: c.x + ir * 0.34, y: c.y + ir * 0.34), ir * 0.17))
            ctx.setFillColor(color(0xFFFFFF, 0.95)); ctx.fillPath()
        }

        // The hop: dots growing and brightening along an arc from the left pane to the right one.
        guard !small else { return }
        let p0 = CGPoint(x: left.midX, y: left.maxY + 52), p1 = CGPoint(x: 512, y: 900)
        let p2 = CGPoint(x: right.midX, y: right.maxY + 56)
        for (i, t) in [0.06, 0.26, 0.47, 0.68, 0.88].enumerated() {
            let t = CGFloat(t), u = 1 - t, i = CGFloat(i)
            let p = CGPoint(x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
                            y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y)
            ctx.addEllipse(in: circle(p, 13 + i * 4)); ctx.setFillColor(color(0xFFFFFF, 0.35 + 0.15 * i)); ctx.fillPath()
        }
    }

    // MARK: Menu bar

    /// An 18 pt template image for the status item, redrawn crisply at 1x and 2x.
    static func menuBarImage(_ glyph: Glyph) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawGlyph(glyph, in: ctx)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "GazeHop"
        return img
    }

    /// Two panes in an 18-unit box. Tracking: the right pane is filled, with a pupil cut out.
    /// Paused: the tracking mark without its pupil, struck through. Calibrating: a dot in each, like the calibration targets.
    static func drawGlyph(_ glyph: Glyph, in ctx: CGContext) {
        let left = CGRect(x: 1.25, y: 3.5, width: 6.75, height: 11), right = CGRect(x: 10, y: 3.5, width: 6.75, height: 11)
        // A transparency layer keeps the .clear cut-outs inside the glyph.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(.black); ctx.setStrokeColor(.black); ctx.setLineWidth(1.5); ctx.setLineCap(.round)
        ctx.addPath(roundedRect(left.insetBy(dx: 0.75, dy: 0.75), 1.6)); ctx.strokePath()
        switch glyph {
        case .tracking:
            ctx.addPath(roundedRect(right, 2.2)); ctx.fillPath()
            ctx.setBlendMode(.clear)
            ctx.addEllipse(in: circle(CGPoint(x: right.midX, y: right.midY), 1.9)); ctx.fillPath()
        case .paused:
            ctx.addPath(roundedRect(right, 2.2)); ctx.fillPath()
            let a = CGPoint(x: 2, y: 1.25), b = CGPoint(x: 16, y: 16.75)
            ctx.setBlendMode(.clear); ctx.setLineWidth(4)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            ctx.setBlendMode(.normal); ctx.setLineWidth(1.5)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        case .calibrating:
            ctx.addPath(roundedRect(right.insetBy(dx: 0.75, dy: 0.75), 1.6)); ctx.strokePath()
            ctx.addEllipse(in: circle(CGPoint(x: left.midX, y: left.midY), 1.5)); ctx.fillPath()
            ctx.addEllipse(in: circle(CGPoint(x: right.midX, y: right.midY), 1.5)); ctx.fillPath()
        }
        ctx.endTransparencyLayer()
    }

    // MARK: Geometry

    /// Apple-style continuous-curvature rounded rect (the macOS icon "squircle").
    static func continuousRect(_ r: CGRect, radius rad: CGFloat) -> CGPath {
        // Each corner: its point, the direction back along the incoming edge, and along the outgoing one.
        let corners: [(CGPoint, CGVector, CGVector)] = [
            (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
            (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
            (CGPoint(x: r.minX, y: r.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
        ]
        func pt(_ c: (CGPoint, CGVector, CGVector), _ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: c.0.x + rad * (u * c.1.dx + v * c.2.dx), y: c.0.y + rad * (u * c.1.dy + v * c.2.dy))
        }
        let p = CGMutablePath()
        p.move(to: pt(corners[3], 0, 1.52866483))
        for c in corners {
            p.addLine(to: pt(c, 1.52866483, 0))
            p.addCurve(to: pt(c, 0.66993427, 0.06549600), control1: pt(c, 1.08849323, 0), control2: pt(c, 0.86840689, 0))
            p.addLine(to: pt(c, 0.63149399, 0.07491100))
            p.addCurve(to: pt(c, 0.07491100, 0.63149399),
                       control1: pt(c, 0.37282392, 0.16905899), control2: pt(c, 0.16905899, 0.37282392))
            p.addLine(to: pt(c, 0.06549600, 0.66993427))
            p.addCurve(to: pt(c, 0, 1.52866483), control1: pt(c, 0, 0.86840689), control2: pt(c, 0, 1.08849323))
        }
        p.closeSubpath()
        return p
    }

    private static func roundedRect(_ r: CGRect, _ rad: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
    }
    private static func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }
    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    private static func gradient(_ a: CGColor, _ b: CGColor) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a, b] as CFArray, locations: [0, 1])!
    }
}
