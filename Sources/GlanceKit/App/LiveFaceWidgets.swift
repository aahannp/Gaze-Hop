// OWNER: App worker. Display-rate parts of the live view: the gaze map and the head / eye gauges.
import SwiftUI
import QuartzCore

/// Main-thread motion for the SwiftUI half of the live view. Deliberately not observable: the canvases read
/// it once per display frame inside a `TimelineView`, so nothing in the view tree re-renders at camera rate.
final class LiveMotion {
    private(set) var face = FaceAnimator()
    private(set) var gaze = GazeAnimator()
    /// Recent gauge positions (-1...1, + = right / up), for the gauges' short tails.
    private(set) var headTrail: [(point: CGPoint, time: Double)] = []
    private(set) var eyeTrail: [(point: CGPoint, time: Double)] = []
    /// Eased 0...1 highlight per display: 1 on the display the gaze is on.
    private(set) var highlight: [DisplayID: Spring] = [:]
    private(set) var time = 0.0
    /// Snapshots freeze the clock so a render shows exactly what the test set up.
    var frozen = false
    static let tail = 0.35
    private var selected: DisplayID?

    func push(face a: FaceAngles?, at t: Double) { face.push(a, at: t) }

    func push(gaze e: GazeEstimate?, at t: Double) {
        gaze.push(e, at: t)
        if let e { selected = e.displayID }
    }

    /// Steps everything to `t`. Several canvases call this each frame; only the first one moves anything.
    func advance(to t: Double) {
        guard !frozen, t > time else { return }
        let dt = time > 0 ? min(t - time, 0.1) : 0
        time = t
        let o = face.advance(to: t)
        gaze.advance(to: t)
        Self.record(Self.head(o), at: t, in: &headTrail)
        Self.record(Self.eyes(o), at: t, in: &eyeTrail)
        for id in Set(highlight.keys).union(selected.map { [$0] } ?? []) {
            var s = highlight[id] ?? Spring(0)
            s.step(toward: id == selected ? 1 : 0, omega: 16, dt: dt)
            highlight[id] = s
        }
    }

    /// Jump to the latest samples (snapshots).
    func settle() {
        face.settle(); gaze.settle()
        headTrail = []; eyeTrail = []
        highlight = selected.map { [$0: Spring(1)] } ?? [:]
    }

    /// Lets snapshots draw tails without running the clock.
    func setTrails(head: [CGPoint], eyes: [CGPoint], gaze points: [CGPoint]) {
        func timed(_ ps: [CGPoint], _ len: Double) -> [(point: CGPoint, time: Double)] {
            ps.enumerated().map { ($1, time - len * Double(ps.count - 1 - $0) / Double(max(ps.count, 1))) }
        }
        headTrail = timed(head, Self.tail); eyeTrail = timed(eyes, Self.tail)
        gaze.setTrail(points, endingAt: time)
    }

    private static func record(_ p: CGPoint, at t: Double, in trail: inout [(point: CGPoint, time: Double)]) {
        trail.append((p, t))
        if let i = trail.firstIndex(where: { t - $0.time <= tail }), i > 0 { trail.removeFirst(i) }
    }

    static func head(_ a: FaceAngles) -> CGPoint {
        CGPoint(x: a.yaw / FaceMapping.signalYaw, y: a.pitch / FaceMapping.signalPitch)
    }
    static func eyes(_ a: FaceAngles) -> CGPoint {
        CGPoint(x: a.eyeYaw / FaceMapping.maxEyeYaw, y: a.eyePitch / FaceMapping.maxEyePitch)
    }
}

/// A canvas redrawn once per display frame (unless paused), after stepping the shared motion.
struct MotionCanvas: View {
    let motion: LiveMotion
    var paused = false
    let draw: (inout GraphicsContext, CGSize, LiveMotion) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: paused)) { timeline in
            Canvas { ctx, size in
                _ = timeline.date
                motion.advance(to: CACurrentMediaTime())
                draw(&ctx, size, motion)
            }
        }
    }
}

// MARK: Shared drawing

private enum Draw {
    /// A soft dot in the style of Maps' location dot: glow, white ring, coloured core.
    /// `room`: distance to the canvas edge, so the glow fades out inside it instead of being cut off.
    static func dot(_ ctx: inout GraphicsContext, at p: CGPoint, color: Color, alpha: Double, radius r: CGFloat = 5.5,
                    room: CGFloat = .infinity) {
        guard alpha > 0.01 else { return }
        let glow = max(min(r * 3.2, room), r + 2)
        ctx.fill(circle(p, glow), with: .radialGradient(
            Gradient(colors: [color.opacity(0.42 * alpha), color.opacity(0)]), center: p, startRadius: r, endRadius: glow))
        ctx.fill(circle(p, r + 2), with: .color(.white.opacity(alpha)))
        ctx.fill(circle(p, r), with: .color(color.opacity(alpha)))
    }

    /// A fading tail: newest end solid and wide, oldest end transparent and thin.
    static func trail(_ ctx: inout GraphicsContext, _ points: [(CGPoint, Double)], now: Double, length: Double,
                      color: Color, alpha: Double, width: CGFloat) {
        guard points.count > 1, alpha > 0.01 else { return }
        for i in 1..<points.count {
            let fresh = max(0, 1 - (now - points[i].1) / length)
            guard fresh > 0 else { continue }
            var seg = Path(); seg.move(to: points[i - 1].0); seg.addLine(to: points[i].0)
            ctx.stroke(seg, with: .color(color.opacity(0.5 * fresh * fresh * alpha)),
                       style: StrokeStyle(lineWidth: width * (0.35 + 0.65 * fresh), lineCap: .round))
        }
    }

    static func circle(_ p: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
}

// MARK: Gaze map

/// The displays to scale in their real arrangement, the display under the gaze in the accent colour, the
/// display with keyboard focus badged, and the gaze itself as a glowing dot with a short fading trail.
struct GazeMapView: View {
    let motion: LiveMotion
    let displays: [Displays.Info]
    let labels: [DisplayID: LiveFaceModel.DisplayLabel]
    let focused: DisplayID?
    let calibrated: Bool
    var paused = false
    private let fitted = FittedNames()

    var body: some View {
        MotionCanvas(motion: motion, paused: paused, draw: draw)
            .accessibilityElement()
            .accessibilityLabel("Display map")
    }

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ m: LiveMotion) {
        guard !displays.isEmpty else { return }
        let layout = MiniMapLayout(displays: displays, size: size, padding: 14)
        let shown = calibrated ? m.gaze.visibility.value : 0
        for d in displays {
            let r = layout.rect(of: d).insetBy(dx: 1.5, dy: 1.5)
            let shape = Path(roundedRect: r, cornerRadius: min(7, min(r.width, r.height) * 0.1), style: .continuous)
            let h = (m.highlight[d.id]?.value ?? 0) * shown
            ctx.fill(shape, with: .color(.primary.opacity(0.07)))
            if d.frame.origin == .zero {        // the primary display carries the menu bar, as in System Settings
                var bar = ctx
                bar.clip(to: shape)
                bar.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: max(3, r.height * 0.045))),
                         with: .color(.primary.opacity(0.13)))
            }
            if h > 0.005 { ctx.fill(shape, with: .color(.accentColor.opacity(0.18 * h))) }
            ctx.stroke(shape, with: .color(.primary.opacity(0.16)), lineWidth: 1)
            if h > 0.005 { ctx.stroke(shape, with: .color(.accentColor.opacity(h)), lineWidth: 2) }
            label(&ctx, d, in: r)
            if d.id == focused { focusBadge(&ctx, in: r) }
        }

        guard calibrated, let gp = m.gaze.point, shown > 0.01 else { return }
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)    // an off-screen gaze pins to the edge
        let trail = m.gaze.trail.map { (layout.point($0.point, clampedTo: bounds), $0.time) }
        let p = layout.point(gp, clampedTo: bounds)
        let off = m.gaze.offScreen.value
        for (color, a) in [(Color.accentColor, 1 - off), (Color.orange, off)] where a > 0.01 {
            Draw.trail(&ctx, trail, now: m.time, length: m.gaze.trailLength, color: color, alpha: a * shown, width: 4)
            Draw.dot(&ctx, at: p, color: color, alpha: a * shown, radius: 6,
                     room: min(p.x, p.y, size.width - p.x, size.height - p.y))
        }
    }

    private func label(_ ctx: inout GraphicsContext, _ d: Displays.Info, in r: CGRect) {
        guard r.width > 30, r.height > 22 else { return }
        let l = labels[d.id] ?? LiveFaceModel.DisplayLabel(name: "Display", builtin: false)
        let symbol = Image(systemName: l.builtin ? "laptopcomputer" : "display")
        let font = Font.system(size: 10, weight: .medium)
        func resolve(_ name: String?) -> GraphicsContext.ResolvedText {
            ctx.resolve((name.map { Text("\(symbol)  \($0)") } ?? Text(symbol)).font(font).foregroundStyle(.secondary))
        }
        let name = fitted.name(for: d.id, l.name, width: r.width - 14) {
            resolve($0).measure(in: CGSize(width: 1000, height: 100)).width
        }
        ctx.draw(resolve(name), at: CGPoint(x: r.minX + 7, y: r.minY + max(5, r.height * 0.045) + 4), anchor: .topLeading)
    }

    private func focusBadge(_ ctx: inout GraphicsContext, in r: CGRect) {
        let font = Font.system(size: 9.5, weight: .semibold)
        let full = r.width > 76 && r.height > 40
        let text = ctx.resolve(Text(full ? "\(Image(systemName: "keyboard"))  Focus" : "\(Image(systemName: "keyboard"))")
            .font(font).foregroundStyle(.secondary))
        let s = text.measure(in: CGSize(width: 200, height: 40))
        let pill = CGRect(x: r.minX + 6, y: r.maxY - 6 - s.height - 4, width: s.width + 12, height: s.height + 4)
        ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.primary.opacity(0.09)))
        ctx.draw(text, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
    }
}

/// Display names shortened with "…" to fit their rectangle (nil: only the symbol fits). Worked out once
/// per name and width, not every frame.
private final class FittedNames {
    private var cache: [DisplayID: (name: String, width: CGFloat, fitted: String?)] = [:]

    func name(for id: DisplayID, _ name: String, width: CGFloat, measure: (String?) -> CGFloat) -> String? {
        if let c = cache[id], c.name == name, abs(c.width - width) < 0.5 { return c.fitted }
        var fitted: String?
        if measure(name) <= width {
            fitted = name
        } else if measure(nil) <= width {
            var chars = Array(name)
            while chars.count > 6, fitted == nil {
                chars.removeLast()
                let s = String(chars).trimmingCharacters(in: .whitespaces) + "…"
                if measure(s) <= width { fitted = s }
            }
        }
        cache[id] = (name, width, fitted)
        return fitted
    }
}

// MARK: Gauges

/// A small round "pad" showing where the head (yaw / pitch) or the eyes (x / y) point, with a short tail,
/// and the two values beside or below it.
struct MotionGauge: View {
    enum Kind { case head, eyes }
    let kind: Kind
    let motion: LiveMotion
    /// "70% weight", "In use" or "Not used".
    let note: String
    let active: Bool
    var paused = false

    var tint: Color { kind == .head ? .blue : .green }
    private var title: String { kind == .head ? "Head" : "Eyes" }

    var body: some View {
        MotionCanvas(motion: motion, paused: paused, draw: draw)
            .accessibilityElement()
            .accessibilityLabel(kind == .head ? "Head direction" : "Eye direction")
            .accessibilityValue(note)
    }

    private func values(_ a: FaceAngles) -> [(String, String)] {
        func signed(_ v: Double, _ format: String) -> String {
            String(format: format, v).replacingOccurrences(of: "-", with: "−")
        }
        switch kind {
        case .head:
            func deg(_ r: Double) -> String {
                let d = (r * 180 / .pi).rounded()
                return d == 0 ? "0°" : signed(d, "%+.0f°")
            }
            return [("Yaw", deg(a.yaw)), ("Pitch", deg(a.pitch))]
        case .eyes:
            let p = LiveMotion.eyes(a)
            func num(_ v: Double) -> String { abs(v) < 0.005 ? "0.00" : signed(v, "%+.2f") }
            return [("X", num(p.x)), ("Y", num(p.y))]
        }
    }

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ m: LiveMotion) {
        if !active { ctx.opacity = 0.45 }
        let presence = m.face.presence.value
        let lost = m.face.isLost && presence < 0.5
        let vals = lost ? values(FaceAngles()).map { ($0.0, "—") } : values(m.face.output)
        let point = kind == .head ? LiveMotion.head(m.face.output) : LiveMotion.eyes(m.face.output)
        let trail = kind == .head ? m.headTrail : m.eyeTrail
        let titleText = ctx.resolve(Text(title).font(.system(size: 13, weight: .semibold)))
        let noteText = ctx.resolve(Text(note).font(.caption2).foregroundStyle(.secondary))
        func label(_ s: String) -> GraphicsContext.ResolvedText {
            ctx.resolve(Text(s).font(.caption).foregroundStyle(.secondary))
        }
        func value(_ s: String) -> GraphicsContext.ResolvedText {
            ctx.resolve(Text(s).font(.system(size: 13, weight: .medium).monospacedDigit()))
        }

        if size.width >= size.height * 1.7 {
            // Pad on the left, title and values on the right.
            let d = min(size.height - 20, 104), x0 = 12 + d + 16
            pad(&ctx, center: CGPoint(x: 12 + d / 2, y: size.height / 2), radius: d / 2, point: point,
                trail: trail, now: m.time, presence: presence)
            let top = (size.height - 64) / 2
            ctx.draw(titleText, at: CGPoint(x: x0, y: top), anchor: .topLeading)
            ctx.draw(noteText, at: CGPoint(x: size.width - 12, y: top + 2), anchor: .topTrailing)
            for (i, (name, v)) in vals.enumerated() {
                let y = top + 26 + CGFloat(i) * 20
                ctx.draw(label(name), at: CGPoint(x: x0, y: y), anchor: .topLeading)
                ctx.draw(value(v), at: CGPoint(x: size.width - 12, y: y - 1), anchor: .topTrailing)
            }
        } else {
            // Title on top, pad in the middle, values underneath.
            ctx.draw(titleText, at: CGPoint(x: 10, y: 8), anchor: .topLeading)
            ctx.draw(noteText, at: CGPoint(x: size.width - 10, y: 10), anchor: .topTrailing)
            let d = max(min(size.height - 30 - 26, size.width - 20), 20)
            pad(&ctx, center: CGPoint(x: size.width / 2, y: 30 + d / 2), radius: d / 2, point: point,
                trail: trail, now: m.time, presence: presence)
            for (i, (name, v)) in vals.enumerated() {
                let cx = size.width * (i == 0 ? 0.27 : 0.73), y = size.height - 8
                let l = label(name), val = value(v)
                let lw = l.measure(in: size).width, vw = val.measure(in: size).width
                let x = cx - (lw + 5 + vw) / 2
                ctx.draw(l, at: CGPoint(x: x, y: y), anchor: .bottomLeading)
                ctx.draw(val, at: CGPoint(x: x + lw + 5, y: y + 1), anchor: .bottomLeading)
            }
        }
    }

    private func pad(_ ctx: inout GraphicsContext, center c: CGPoint, radius r: CGFloat, point: CGPoint,
                     trail: [(point: CGPoint, time: Double)], now: Double, presence: Double) {
        let disc = Draw.circle(c, r)
        ctx.fill(disc, with: .color(.primary.opacity(0.05)))
        ctx.stroke(Draw.circle(c, r / 2), with: .color(.primary.opacity(0.07)), lineWidth: 1)
        var cross = Path()
        cross.move(to: CGPoint(x: c.x - r + 5, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r - 5, y: c.y))
        cross.move(to: CGPoint(x: c.x, y: c.y - r + 5)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r - 5))
        ctx.stroke(cross, with: .color(.primary.opacity(0.09)), lineWidth: 1)
        ctx.stroke(disc, with: .color(.primary.opacity(0.13)), lineWidth: 1)

        let reach = r - 8
        func place(_ p: CGPoint) -> CGPoint {
            let len = hypot(p.x, p.y), k = len > 1 ? 1 / len : 1
            return CGPoint(x: c.x + p.x * k * reach, y: c.y - p.y * k * reach)
        }
        let alpha = 0.35 + 0.65 * presence
        Draw.trail(&ctx, trail.map { (place($0.point), $0.time) }, now: now, length: LiveMotion.tail,
                   color: tint, alpha: alpha, width: 3.5)
        Draw.dot(&ctx, at: place(point), color: tint, alpha: alpha, radius: 5)
    }
}
