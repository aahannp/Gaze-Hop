import XCTest
import AppKit
@testable import GlanceKit

/// The live view's motion: ~15 Hz jittery samples in, smooth display-rate frames out.
final class LiveMotionTests: XCTestCase {
    private let frame = 1.0 / 60

    private func angles(yaw: Double = 0, eyeYaw: Double = 0, openness: Double = 1) -> FaceAngles {
        var a = FaceAngles(); a.yaw = yaw; a.eyeYaw = eyeYaw; a.openness = openness; return a
    }

    // MARK: Spring

    func testSpringIsCriticallyDampedForAnyStep() {
        for dt in [1.0 / 240, 1.0 / 60, 0.05, 0.1] {
            var s = Spring(0), last = 0.0
            for _ in 0..<Int(2 / dt) {
                s.step(toward: 1, omega: 24, dt: dt)
                XCTAssertGreaterThanOrEqual(s.value, last - 1e-12)
                XCTAssertLessThanOrEqual(s.value, 1 + 1e-12)
                last = s.value
            }
            XCTAssertEqual(s.value, 1, accuracy: 1e-6)
        }
    }

    // MARK: FaceAnimator

    func testAnimatorConvergesWithoutOvershootForAStep() {
        var anim = FaceAnimator()
        anim.push(angles(yaw: 0.8, eyeYaw: -0.4, openness: 0), at: 0)
        var last = FaceAngles()
        for f in 0...120 {                                     // 2 s at 60 fps
            let o = anim.advance(to: Double(f) * frame)
            XCTAssertGreaterThanOrEqual(o.yaw, last.yaw - 1e-12)
            XCTAssertLessThanOrEqual(o.yaw, 0.8 + 1e-12)
            XCTAssertLessThanOrEqual(o.eyeYaw, last.eyeYaw + 1e-12)
            XCTAssertGreaterThanOrEqual(o.eyeYaw, -0.4 - 1e-12)
            XCTAssertLessThanOrEqual(o.openness, last.openness + 1e-12)
            last = o
        }
        XCTAssertEqual(last.yaw, 0.8, accuracy: 1e-4)
        XCTAssertEqual(last.eyeYaw, -0.4, accuracy: 1e-4)
        XCTAssertEqual(last.openness, 0, accuracy: 1e-4)
    }

    /// A steady turn sampled at a jittery 15 Hz comes out as a steady turn: monotonic, no overshoot,
    /// and an even speed from frame to frame instead of 15 Hz steps.
    func testAnimatorTurnsA15HzStaircaseIntoAnEvenMotion() {
        var rng = NoiseSource(seed: 7)
        var anim = FaceAnimator()
        let samples = (0...30).map { k -> (Double, Double) in
            let t = Double(k) / 15 + (k == 0 ? 0 : rng.uniform(-0.012, 0.012))
            return (t, min(max(t, 0), 1) * 0.8)                 // 0 -> 0.8 rad over 1 s, then hold
        }
        var next = 0, out: [Double] = []
        for f in 0...150 {
            let t = Double(f) * frame
            while next < samples.count, samples[next].0 <= t { anim.push(angles(yaw: samples[next].1), at: samples[next].0); next += 1 }
            out.append(anim.advance(to: t).yaw)
        }
        for i in 1..<out.count {
            XCTAssertGreaterThanOrEqual(out[i], out[i - 1] - 1e-12, "frame \(i) moved backwards")
            XCTAssertLessThanOrEqual(out[i], 0.8 + 1e-12)
        }
        XCTAssertEqual(out.last!, 0.8, accuracy: 1e-3)
        // Mid-turn (0.4...0.9 s) every frame advances by about the same amount: 0.8 rad/s = 0.0133 per frame.
        let deltas = (24...54).map { out[$0] - out[$0 - 1] }
        for d in deltas { XCTAssertEqual(d, 0.8 / 60, accuracy: 0.8 / 60 * 0.3) }
    }

    func testBlinkIsFasterThanHeadMotion() {
        var anim = FaceAnimator()
        anim.push(angles(yaw: 1, openness: 0), at: 0)
        var o = FaceAngles()
        for f in 0...3 { o = anim.advance(to: Double(f) * frame) }     // 50 ms
        XCTAssertGreaterThan(1 - o.openness, 0.8)               // lids nearly shut
        XCTAssertLessThan(o.yaw, 0.35)                          // head still on its way
        anim.push(angles(yaw: 1, openness: 1), at: 0.1)
        var lids: [Double] = []
        for f in 6...24 { lids.append(anim.advance(to: Double(f) * frame).openness) }
        XCTAssertEqual(lids.last!, 1, accuracy: 0.02)           // open again within 0.3 s
        for i in 1..<lids.count { XCTAssertGreaterThanOrEqual(lids[i], lids[i - 1] - 1e-12) }
    }

    func testOneMissingFrameHoldsThePose() {
        var anim = FaceAnimator()
        anim.push(angles(yaw: 0.5, eyeYaw: 0.2), at: 0)
        anim.settle()
        anim.push(nil, at: 1)
        for f in 60...80 {
            let o = anim.advance(to: Double(f) * frame)
            XCTAssertEqual(o.yaw, 0.5, accuracy: 1e-9)
            XCTAssertEqual(anim.presence.value, 1, accuracy: 1e-9)
        }
        anim.push(angles(yaw: 0.5, eyeYaw: 0.2), at: 81 * frame)
        XCTAssertEqual(anim.advance(to: 82 * frame).yaw, 0.5, accuracy: 1e-9)
    }

    func testLostFaceEasesToNeutralAndComesBackWithoutAJump() {
        var anim = FaceAnimator()
        anim.push(angles(yaw: 0.6, eyeYaw: 0.3), at: 0)
        anim.settle()
        _ = anim.advance(to: 0)
        anim.push(nil, at: 0.5)
        var last = 0.6, maxStep = 0.0
        for f in 30...240 {                                     // 0.5 ... 4 s
            let y = anim.advance(to: Double(f) * frame).yaw
            XCTAssertLessThanOrEqual(y, last + 1e-12)
            XCTAssertGreaterThanOrEqual(y, -1e-9)
            maxStep = max(maxStep, last - y); last = y
        }
        XCTAssertEqual(last, 0, accuracy: 1e-3)
        XCTAssertLessThan(anim.presence.value, 0.05)
        XCTAssertLessThan(maxStep, 0.015)                       // eased: under 1° per frame at 60 fps

        anim.push(angles(yaw: 0.6), at: 241 * frame)
        var prev = 0.0
        maxStep = 0
        for f in 241...330 {
            let y = anim.advance(to: Double(f) * frame).yaw
            XCTAssertLessThanOrEqual(y, 0.6 + 1e-12)
            maxStep = max(maxStep, y - prev); prev = y
        }
        XCTAssertEqual(prev, 0.6, accuracy: 1e-3)
        XCTAssertLessThan(maxStep, 0.05)                        // no snap back
        XCTAssertGreaterThan(anim.presence.value, 0.95)
    }

    // MARK: GazeAnimator

    func testGazeDotGlidesKeepsAShortTrailAndFadesWhenLost() {
        var g = GazeAnimator()
        var xs: [Double] = []
        for f in 0...60 {
            let t = Double(f) * frame
            if f % 4 == 0 { g.push(GazeEstimate(point: CGPoint(x: 100 + 40 * f, y: 200), displayID: 1, confidence: 0.9), at: t) }
            g.advance(to: t)
            xs.append(Double(g.point!.x))
            XCTAssertLessThanOrEqual(t - (g.trail.first?.time ?? t), g.trailLength + 1e-9)
        }
        for i in 1..<xs.count { XCTAssertGreaterThanOrEqual(xs[i], xs[i - 1] - 1e-9) }
        XCTAssertGreaterThan(g.visibility.value, 0.95)
        XCTAssertEqual(g.offScreen.value, 0, accuracy: 1e-9)
        g.push(nil, at: 61 * frame)
        for f in 61...150 { g.advance(to: Double(f) * frame) }
        XCTAssertLessThan(g.visibility.value, 0.05)
        XCTAssertTrue(g.trail.isEmpty)
    }

    // MARK: Smoothness benchmark

    /// The old first-order smoother, kept here only to compare against.
    private static func legacyStep(_ cur: FaceAngles, toward t: FaceAngles, dt: Double) -> FaceAngles {
        let k = 1 - exp(-dt / 0.07)
        var o = cur
        o.yaw = cur.yaw + (t.yaw - cur.yaw) * k
        return o
    }

    struct Metrics: CustomStringConvertible {
        var accelRMS = 0.0, accelMax = 0.0, maxStep = 0.0, lagMs = 0.0, errRMS = 0.0, errMax = 0.0
        var description: String {
            String(format: "accel rms %.0f°/s² max %.0f°/s², max step %.2f°/frame, lag %.0f ms, error rms %.2f° max %.2f°",
                   accelRMS, accelMax, maxStep, lagMs, errRMS, errMax)
        }
    }

    /// Head yaw swinging between displays, sampled at a jittery 15 Hz with noise, 8% of frames missing and
    /// 3% reported as "no face" for a single frame. Returns the yaw shown at 60 fps by both smoothers.
    static func runStream(seconds: Double = 8) -> (truth: (Double) -> Double, t: [Double], new: [Double], old: [Double]) {
        let truth = { (t: Double) in 0.45 * sin(2 * .pi * 0.6 * t) + 0.15 * sin(2 * .pi * 1.3 * t + 1) }
        var rng = NoiseSource(seed: 42)
        var samples: [(Double, Double?)] = []
        for k in 0..<Int(seconds * 15) {
            let t = Double(k) / 15 + rng.uniform(-0.012, 0.012)
            let r = rng.uniform(0, 1)
            if r < 0.08 { continue }
            samples.append((t, r < 0.11 ? nil : truth(t) + 0.006 * rng.gaussian()))
        }
        var anim = FaceAnimator(), legacy = FaceAngles(), legacyTarget = FaceAngles()
        var next = 0
        var ts: [Double] = [], new: [Double] = [], old: [Double] = []
        for f in 0..<Int(seconds * 60) {
            let t = Double(f) / 60
            while next < samples.count, samples[next].0 <= t {
                let (st, v) = samples[next]
                var a = FaceAngles(); a.yaw = v ?? 0
                anim.push(v == nil ? nil : a, at: st)
                legacyTarget = a                       // the old model snapped to neutral on a nil frame
                next += 1
            }
            ts.append(t)
            new.append(anim.advance(to: t).yaw)
            legacy = legacyStep(legacy, toward: legacyTarget, dt: 1.0 / 60)
            old.append(legacy.yaw)
        }
        return (truth, ts, new, old)
    }

    static func metrics(_ y: [Double], t: [Double], truth: (Double) -> Double, from start: Int = 60) -> Metrics {
        let deg = 180 / Double.pi, fps = 60.0
        var m = Metrics()
        let acc = (start..<(y.count - 1)).map { (y[$0 + 1] - 2 * y[$0] + y[$0 - 1]) * deg * fps * fps }
        m.accelRMS = sqrt(acc.map { $0 * $0 }.reduce(0, +) / Double(acc.count))
        m.accelMax = acc.map(abs).max() ?? 0
        m.maxStep = (start..<y.count).map { abs(y[$0] - y[$0 - 1]) * deg }.max() ?? 0
        var best = (lag: 0.0, rms: Double.infinity)
        for ms in 0...300 {
            let lag = Double(ms) / 1000
            let e = (start..<y.count).map { y[$0] - truth(t[$0] - lag) }
            let rms = sqrt(e.map { $0 * $0 }.reduce(0, +) / Double(e.count))
            if rms < best.rms { best = (lag, rms) }
        }
        m.lagMs = best.lag * 1000
        m.errRMS = best.rms * deg
        m.errMax = (start..<y.count).map { abs(y[$0] - truth(t[$0] - best.lag)) * deg }.max() ?? 0
        return m
    }

    func testAnimatorIsSmootherThanTheOldSmoother() throws {
        let r = Self.runStream()
        let new = Self.metrics(r.new, t: r.t, truth: r.truth), old = Self.metrics(r.old, t: r.t, truth: r.truth)
        let truthOnly = Self.metrics(r.t.map(r.truth), t: r.t, truth: r.truth)
        print("SMOOTHNESS truth: \(truthOnly)")
        print("SMOOTHNESS new:   \(new)")
        print("SMOOTHNESS old:   \(old)")
        XCTAssertLessThan(new.accelRMS, old.accelRMS * 0.25)    // no 15 Hz velocity stepping
        XCTAssertLessThan(new.accelMax, old.accelMax * 0.25)
        XCTAssertLessThan(new.errMax, old.errMax * 0.5)         // dropped frames no longer dip toward neutral
        XCTAssertLessThan(new.maxStep, old.maxStep)
        XCTAssertLessThan(new.lagMs, 200)

        if let dir = SnapshotDir.url {
            var csv = "t,truth,new,old\n"
            for i in r.t.indices { csv += String(format: "%.4f,%.5f,%.5f,%.5f\n", r.t[i], r.truth(r.t[i]), r.new[i], r.old[i]) }
            try csv.write(to: dir.appendingPathComponent("motion-yaw.csv"), atomically: true, encoding: .utf8)
            try SnapshotDir.png(Chart.lines(title: "Head yaw, 15 Hz samples shown at 60 fps (2 s)",
                                            series: [("truth", .systemGray, Array(r.t.map(r.truth)[120..<240])),
                                                     ("old", .systemOrange, Array(r.old[120..<240])),
                                                     ("new", .controlAccentColor, Array(r.new[120..<240]))]),
                                to: dir.appendingPathComponent("motion-yaw.png"))
        }
    }

    // MARK: Rendered frames

    /// Renders the real head at 60 fps from a 15 Hz turn and measures how much the image changes per frame.
    /// A smooth turn changes the picture by about the same amount every frame; 15 Hz stepping shows as a
    /// sawtooth (big change right after each sample, almost none before the next).
    func testRenderedFramesChangeEvenly() throws {
        let rig = FaceRig()
        let size = CGSize(width: 180, height: 210)
        guard rig.snapshot(size: size, angles: FaceAngles()) != nil else { throw XCTSkip("no Metal device") }
        var rng = NoiseSource(seed: 3)
        let samples = (0...24).map { k -> (Double, Double) in
            let t = Double(k) / 15 + (k == 0 ? 0 : rng.uniform(-0.008, 0.008))
            return (t, -0.5 + 0.7 * t)                          // a steady 40°/s turn
        }
        var anim = FaceAnimator(), legacy = FaceAngles(), legacyTarget = FaceAngles()
        anim.push(angles(yaw: -0.5), at: 0); anim.settle()
        legacy.yaw = -0.5; legacyTarget.yaw = -0.5
        var next = 0
        var newFrames: [[Float]] = [], oldFrames: [[Float]] = [], strip: [NSImage] = []
        for f in 0...78 {
            let t = Double(f) / 60
            while next < samples.count, samples[next].0 <= t {
                anim.push(angles(yaw: samples[next].1), at: samples[next].0)
                legacyTarget.yaw = samples[next].1
                next += 1
            }
            let a = anim.advance(to: t)
            legacy = Self.legacyStep(legacy, toward: legacyTarget, dt: 1.0 / 60)
            guard f >= 24 else { continue }                     // measure 0.4 ... 1.3 s, mid-turn
            let ni = try XCTUnwrap(rig.snapshot(size: size, angles: a))
            newFrames.append(Pixels.gray(ni, size))
            oldFrames.append(Pixels.gray(try XCTUnwrap(rig.snapshot(size: size, angles: legacy)), size))
            if f % 6 == 0 { strip.append(ni) }
        }
        func spread(_ frames: [[Float]]) -> (mean: Double, cv: Double, maxOverMin: Double) {
            let d = zip(frames, frames.dropFirst()).map { Pixels.meanAbsDiff($0, $1) }
            let mean = d.reduce(0, +) / Double(d.count)
            let sd = sqrt(d.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(d.count))
            return (mean, sd / mean, d.max()! / max(d.min()!, 1e-9))
        }
        let n = spread(newFrames), o = spread(oldFrames)
        print(String(format: "FRAMES new: mean change %.3f, variation %.0f%%, max/min %.1f", n.mean, n.cv * 100, n.maxOverMin))
        print(String(format: "FRAMES old: mean change %.3f, variation %.0f%%, max/min %.1f", o.mean, o.cv * 100, o.maxOverMin))
        XCTAssertLessThan(n.cv, 0.2)
        XCTAssertLessThan(n.cv, o.cv * 0.5)
        if let dir = SnapshotDir.url {
            try SnapshotDir.png(Chart.strip(strip, cell: size), to: dir.appendingPathComponent("motion-filmstrip.png"))
            let nd = zip(newFrames, newFrames.dropFirst()).map { Pixels.meanAbsDiff($0, $1) }
            let od = zip(oldFrames, oldFrames.dropFirst()).map { Pixels.meanAbsDiff($0, $1) }
            try SnapshotDir.png(Chart.lines(title: "Image change per rendered frame during a steady turn",
                                            series: [("old", .systemOrange, od), ("new", .controlAccentColor, nd)], fromZero: true),
                                to: dir.appendingPathComponent("motion-frame-deltas.png"))
        }
    }
}

// MARK: - Helpers

/// Deterministic random numbers for synthetic streams.
private struct NoiseSource {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u = max(uniform(0, 1), 1e-12), v = uniform(0, 1)
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}

/// Where review PNGs go: `GLANCE_SNAPSHOT_DIR` if set (nil otherwise, so plain `swift test` writes nothing).
enum SnapshotDir {
    static var url: URL? {
        guard let path = ProcessInfo.processInfo.environment["GLANCE_SNAPSHOT_DIR"] else { return nil }
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func png(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { throw XCTSkip("no png") }
        try data.write(to: url)
    }
}

enum Pixels {
    static func gray(_ image: NSImage, _ size: CGSize) -> [Float] {
        let w = Int(size.width), h = Int(size.height)
        var data = [UInt8](repeating: 0, count: w * h)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            var rect = CGRect(x: 0, y: 0, width: w, height: h)
            if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { ctx.draw(cg, in: rect) }
        }
        return data.map { Float($0) / 255 }
    }

    static func meanAbsDiff(_ a: [Float], _ b: [Float]) -> Double {
        Double(zip(a, b).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }) / Double(a.count) * 100
    }
}

/// Tiny AppKit charts for the review PNGs.
enum Chart {
    static func lines(title: String, series: [(String, NSColor, [Double])], fromZero: Bool = false) -> NSImage {
        let size = CGSize(width: 720, height: 300), plot = CGRect(x: 40, y: 30, width: 660, height: 230)
        let all = series.flatMap(\.2)
        var lo = all.min() ?? 0, hi = all.max() ?? 1
        if fromZero { lo = 0 }
        if hi - lo < 1e-9 { hi = lo + 1 }
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        NSColor(white: 0.9, alpha: 1).setStroke(); NSBezierPath(rect: plot).stroke()
        (title as NSString).draw(at: CGPoint(x: 40, y: 272), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        var lx = plot.maxX
        for (name, color, ys) in series.reversed() {
            let n = max(ys.count - 1, 1)
            let path = NSBezierPath()
            for (i, y) in ys.enumerated() {
                let p = CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(n),
                                y: plot.minY + plot.height * CGFloat((y - lo) / (hi - lo)))
                i == 0 ? path.move(to: p) : path.line(to: p)
            }
            path.lineWidth = 2; color.usingColorSpace(.sRGB)?.setStroke(); path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color]
            let w = (name as NSString).size(withAttributes: attrs).width
            lx -= w + 14
            (name as NSString).draw(at: CGPoint(x: lx, y: 8), withAttributes: attrs)
        }
        img.unlockFocus()
        return img
    }

    static func strip(_ images: [NSImage], cell: CGSize) -> NSImage {
        let img = NSImage(size: CGSize(width: cell.width * CGFloat(images.count), height: cell.height))
        img.lockFocus()
        NSColor(white: 0.95, alpha: 1).setFill(); NSRect(origin: .zero, size: img.size).fill()
        for (i, im) in images.enumerated() { im.draw(in: NSRect(x: CGFloat(i) * cell.width, y: 0, width: cell.width, height: cell.height)) }
        img.unlockFocus()
        return img
    }
}
