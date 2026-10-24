// OWNER: Calibration worker.
// Ridge regression from HeadPose.features (+ distance interactions + bias) to a CG global point.
import Foundation
import CoreGraphics

// MARK: - Regression model (pure math, unit-testable)

public struct GazeModel: Codable, Equatable {
    var mean: [Double]
    var scale: [Double]
    /// Two rows (x, y). Each row = [bias, w_0 ... w_{n-1}] over standardized expanded features.
    var coef: [[Double]]

    /// Raw features + interaction terms that let the head-turn gain change with distance.
    static func expand(_ f: [Double]) -> [Double] {
        // f order: yaw, pitch, cx, cy, size, eyeDx, eyeDy, roll
        let size = f[4]
        return f + [f[0] * size, f[1] * size, f[5] * size, f[6] * size]
    }

    struct Sample { var features: [Double]; var target: CGPoint; var weight: Double }

    static func fit(_ samples: [Sample], ridge: Double = 0.002) -> GazeModel? {
        guard samples.count >= 12 else { return nil }
        let rows = samples.map { expand($0.features) }
        let n = rows[0].count
        let wsum = samples.reduce(0) { $0 + $1.weight }
        guard wsum > 0 else { return nil }

        var mean = [Double](repeating: 0, count: n)
        for (r, s) in zip(rows, samples) { for j in 0..<n { mean[j] += r[j] * s.weight } }
        mean = mean.map { $0 / wsum }
        var scale = [Double](repeating: 0, count: n)
        for (r, s) in zip(rows, samples) { for j in 0..<n { let d = r[j] - mean[j]; scale[j] += d * d * s.weight } }
        scale = scale.map { let sd = ($0 / wsum).squareRoot(); return sd < 1e-9 ? 1 : sd }

        let p = n + 1
        var a = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var bx = [Double](repeating: 0, count: p), by = bx
        for (r, s) in zip(rows, samples) {
            var z = [1.0]; for j in 0..<n { z.append((r[j] - mean[j]) / scale[j]) }
            for i in 0..<p {
                let zi = z[i] * s.weight
                for j in 0..<p { a[i][j] += zi * z[j] }
                bx[i] += zi * Double(s.target.x); by[i] += zi * Double(s.target.y)
            }
        }
        for i in 1..<p { a[i][i] += ridge * wsum }   // bias unpenalized
        guard let cx = solve(a, bx), let cy = solve(a, by) else { return nil }
        return GazeModel(mean: mean, scale: scale, coef: [cx, cy])
    }

    func predict(_ f: [Double]) -> CGPoint {
        let r = GazeModel.expand(f)
        var x = coef[0][0], y = coef[1][0]
        for j in 0..<r.count {
            let z = (r[j] - mean[j]) / scale[j]
            x += coef[0][j + 1] * z; y += coef[1][j + 1] * z
        }
        return CGPoint(x: x, y: y)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        let n = b0.count
        var a = a0, b = b0
        for c in 0..<n {
            var piv = c
            for r in c..<n where abs(a[r][c]) > abs(a[piv][c]) { piv = r }
            if abs(a[piv][c]) < 1e-12 { return nil }
            a.swapAt(c, piv); b.swapAt(c, piv)
            for r in (c + 1)..<max(n, c + 1) {
                let f = a[r][c] / a[c][c]
                if f == 0 { continue }
                for k in c..<n { a[r][k] -= f * a[c][k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<max(n, r + 1) { s -= a[r][k] * x[k] }
            x[r] = s / a[r][r]
        }
        return x
    }
}

// MARK: - Point -> display resolution

enum DisplayResolver {
    /// Fraction of display size past an outer edge that still counts as "that display".
    static let offscreenMargin = 0.15
    /// Extra crossing distance (fraction of display size) required to leave the current display.
    static let hysteresis = 0.04

    struct Result { var id: DisplayID?; var edgeDistance: CGFloat }

    /// Per-display rect after placing every shared boundary according to `edgeBias`.
    /// 0.5 = middle of the gap; each 0.1 step moves the line by 5% of the smaller display extent
    /// toward the right/lower display (bias > 0.5) or the left/upper one (bias < 0.5).
    static func effectiveRects(_ displays: [Displays.Info], edgeBias: Double) -> [CGRect] {
        var rects = displays.map { $0.frame }
        let eps: CGFloat = 1
        let shiftK = CGFloat((min(max(edgeBias, 0), 1) - 0.5) * 0.5)
        for i in displays.indices {
            for j in displays.indices where i != j {
                let a = displays[i].frame, b = displays[j].frame
                // b to the right of a
                if b.minX >= a.maxX - eps, min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0 {
                    let gap = b.minX - a.maxX
                    let lo = a.maxX - 0.25 * a.width, hi = b.minX + 0.25 * b.width
                    let line = min(max(a.maxX + gap / 2 + shiftK * min(a.width, b.width), lo), hi)
                    rects[i].size.width = line - rects[i].minX
                    let r = rects[j].maxX; rects[j].origin.x = line; rects[j].size.width = r - line
                }
                // b below a
                if b.minY >= a.maxY - eps, min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0 {
                    let gap = b.minY - a.maxY
                    let lo = a.maxY - 0.25 * a.height, hi = b.minY + 0.25 * b.height
                    let line = min(max(a.maxY + gap / 2 + shiftK * min(a.height, b.height), lo), hi)
                    rects[i].size.height = line - rects[i].minY
                    let r = rects[j].maxY; rects[j].origin.y = line; rects[j].size.height = r - line
                }
            }
        }
        return rects
    }

    static func resolve(_ p: CGPoint, displays: [Displays.Info], current: DisplayID?, edgeBias: Double) -> Result {
        guard !displays.isEmpty else { return Result(id: nil, edgeDistance: 0) }
        let rects = effectiveRects(displays, edgeBias: edgeBias)

        func insideDist(_ r: CGRect) -> CGFloat {
            min(p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y)
        }
        // Current display keeps the point until it is `hysteresis` past the boundary.
        if let cur = current, let ci = displays.firstIndex(where: { $0.id == cur }) {
            let f = displays[ci].frame
            let h = CGFloat(hysteresis) * min(f.width, f.height)
            let grown = rects[ci].insetBy(dx: -h, dy: -h)
            if grown.contains(p) { return Result(id: cur, edgeDistance: insideDist(rects[ci])) }
        }
        for i in displays.indices where rects[i].contains(p) {
            return Result(id: displays[i].id, edgeDistance: insideDist(rects[i]))
        }
        // Outside all displays: nearest one if within the off-screen margin.
        var best: (Int, CGFloat)?
        for (i, d) in displays.enumerated() {
            let f = d.frame
            let dx = max(f.minX - p.x, 0, p.x - f.maxX), dy = max(f.minY - p.y, 0, p.y - f.maxY)
            let mx = CGFloat(offscreenMargin) * f.width * (d.id == current ? 1.3 : 1)
            let my = CGFloat(offscreenMargin) * f.height * (d.id == current ? 1.3 : 1)
            guard dx <= mx, dy <= my else { continue }
            let dist = (dx * dx + dy * dy).squareRoot()
            if best == nil || dist < best!.1 { best = (i, dist) }
        }
        if let b = best { return Result(id: displays[b.0].id, edgeDistance: 0) }
        return Result(id: nil, edgeDistance: 0)
    }
}

// MARK: - Mapper

public final class RegressionGazeMapper: GazeMapper {
    struct StoredSample: Codable { var f: [Double]; var x: Double; var y: Double; var w: Double; var click: Bool }
    struct StoredDisplay: Codable, Equatable { var id: UInt32; var x: Double; var y: Double; var w: Double; var h: Double }
    struct Persisted: Codable {
        var version = 1
        var arrangement: [StoredDisplay]
        var samples: [StoredSample]
        var model: GazeModel?
    }

    public static let defaultURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlanceSwitch/calibration.json")
    }()

    public static let minConfidence = 0.3
    static let maxClickSamples = 150
    static let clickWeightThreshold = 0.9
    static let refitEveryClicks = 10
    static let driftAlpha = 0.1

    private let lock = NSLock()
    private let url: URL
    private let displaysProvider: () -> [Displays.Info]
    private var calibration: [StoredSample] = []
    private var clicks: [StoredSample] = []     // bounded rolling buffer, oldest dropped first
    private var model: GazeModel?
    private var arrangement: [StoredDisplay] = []
    private var drift = 0.0
    private var clicksSinceFit = 0

    public init(url: URL = RegressionGazeMapper.defaultURL,
                displays: @escaping () -> [Displays.Info] = { Displays.all() }) {
        self.url = url
        self.displaysProvider = displays
    }

    static func arrangement(of d: [Displays.Info]) -> [StoredDisplay] {
        d.map { StoredDisplay(id: $0.id, x: $0.frame.minX, y: $0.frame.minY, w: $0.frame.width, h: $0.frame.height) }
            .sorted { $0.id < $1.id }
    }

    public var isCalibrated: Bool {
        lock.lock(); defer { lock.unlock() }
        return model != nil && arrangement == Self.arrangement(of: displaysProvider())
    }

    public var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return calibration.count + clicks.count }

    public var driftScore: Double { lock.lock(); defer { lock.unlock() }; return drift }

    public func estimate(_ pose: HeadPose, currentDisplay: DisplayID?, edgeBias: Double) -> GazeEstimate? {
        estimate(pose, currentDisplay: currentDisplay, edgeBias: edgeBias, displays: displaysProvider())
    }

    /// Core entry with explicit displays (used by tests).
    func estimate(_ pose: HeadPose, currentDisplay: DisplayID?, edgeBias: Double,
                  displays: [Displays.Info]) -> GazeEstimate? {
        lock.lock(); let m = model; lock.unlock()
        guard let m, pose.confidence >= Self.minConfidence else { return nil }
        let p = m.predict(pose.features)
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let r = DisplayResolver.resolve(p, displays: displays, current: currentDisplay, edgeBias: edgeBias)
        var conf = pose.confidence
        if let id = r.id, let d = displays.first(where: { $0.id == id }) {
            let ref = 0.1 * Double(min(d.frame.width, d.frame.height))
            conf *= 0.5 + 0.5 * min(1, max(0, Double(r.edgeDistance)) / ref)
        } else {
            conf *= 0.5
        }
        return GazeEstimate(point: p, displayID: r.id, confidence: conf)
    }

    public func addSample(_ pose: HeadPose, target: CGPoint, weight: Double) {
        guard pose.features.allSatisfy({ $0.isFinite }) else { return }
        let s = StoredSample(f: pose.features, x: Double(target.x), y: Double(target.y),
                             w: weight, click: weight < Self.clickWeightThreshold)
        lock.lock()
        if s.click {
            clicks.append(s)
            if clicks.count > Self.maxClickSamples { clicks.removeFirst(clicks.count - Self.maxClickSamples) }
            clicksSinceFit += 1
        } else {
            calibration.append(s)
        }
        let refit = model != nil && clicksSinceFit >= Self.refitEveryClicks
        lock.unlock()
        if refit { fit() }
    }

    @discardableResult public func fit() -> Bool {
        lock.lock()
        let all = (calibration + clicks).map {
            GazeModel.Sample(features: $0.f, target: CGPoint(x: $0.x, y: $0.y), weight: $0.w)
        }
        lock.unlock()
        guard let m = GazeModel.fit(all) else { return false }
        let arr = Self.arrangement(of: displaysProvider())
        lock.lock()
        model = m; arrangement = arr; clicksSinceFit = 0
        lock.unlock()
        return true
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        calibration = []; clicks = []; model = nil; arrangement = []; drift = 0; clicksSinceFit = 0
    }

    public func save() throws {
        lock.lock()
        let blob = Persisted(arrangement: arrangement, samples: calibration + clicks, model: model)
        lock.unlock()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(blob).write(to: url, options: .atomic)
    }

    public func load() throws {
        let blob = try JSONDecoder().decode(Persisted.self, from: Data(contentsOf: url))
        lock.lock(); defer { lock.unlock() }
        calibration = blob.samples.filter { !$0.click }
        clicks = Array(blob.samples.filter { $0.click }.suffix(Self.maxClickSamples))
        model = blob.model
        arrangement = blob.arrangement
        drift = 0; clicksSinceFit = 0
    }

    public func recordClickOutcome(predicted: DisplayID?, actual: DisplayID) {
        let miss = predicted == actual ? 0.0 : 1.0
        lock.lock(); defer { lock.unlock() }
        drift = drift * (1 - Self.driftAlpha) + miss * Self.driftAlpha
    }
}
