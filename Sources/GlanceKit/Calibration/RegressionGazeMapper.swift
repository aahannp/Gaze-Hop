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
    /// Indices into `expand(f)` this model uses (nil = all, models saved before gaze modes).
    var columns: [Int]? = nil

    /// Expanded-feature columns of the head component: everything except the eye terms.
    static let headColumns = [0, 1, 2, 3, 4, 7, 8, 9]

    static func select(_ r: [Double], _ columns: [Int]?) -> [Double] { columns.map { c in c.map { r[$0] } } ?? r }

    /// Raw features + interaction terms that let the head-turn gain change with distance.
    static func expand(_ f: [Double]) -> [Double] {
        // f order: yaw, pitch, cx, cy, size, eyeDx, eyeDy, roll
        let size = f[4]
        return f + [f[0] * size, f[1] * size, f[5] * size, f[6] * size]
    }

    struct Sample { var features: [Double]; var target: CGPoint; var weight: Double }

    /// `columns` restricts the model to a subset of the expanded features; `penalty` scales the ridge per selected column.
    static func fit(_ samples: [Sample], ridge: Double = 0.03, columns: [Int]? = nil, penalty: [Double]? = nil) -> GazeModel? {
        guard samples.count >= 12 else { return nil }
        let rows = samples.map { select(expand($0.features), columns) }
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
        for i in 1..<p { a[i][i] += ridge * wsum * (penalty?[i - 1] ?? 1) }   // bias unpenalized
        guard let cx = solve(a, bx), let cy = solve(a, by) else { return nil }
        return GazeModel(mean: mean, scale: scale, coef: [cx, cy], columns: columns)
    }

    func predict(_ f: [Double]) -> CGPoint {
        let r = GazeModel.select(GazeModel.expand(f), columns)
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

// MARK: - Display classifier

/// Picks WHICH display is being looked at, independently of the (noisy) point regression.
/// Linear discriminant analysis with a shrunk pooled covariance over the gaze-relevant features:
/// robust with few samples and gives calibrated probabilities for hysteresis / edgeBias.
struct DisplayClassifier: Codable, Equatable {
    /// Feature indices into HeadPose.features: yaw 0, pitch 1, faceCenter.x 2, faceCenter.y 3, eyeDx 5, eyeDy 6.
    /// Left/right is decided by horizontal evidence only; up/down by vertical evidence only.
    static let minPerClass = 4
    static let edgeBiasStrength = 6.0     // nats of log-odds at edgeBias 0 / 1
    static let enterPrimaryThreshold = 0.65 // returning to the largest display is allowed to be easier
    static var leaveThreshold = 0.85      // posterior needed to LEAVE the current display
    static let pitchIndex = 1

    var featureIndex: [Int]
    var pitchFloor: Double                // below => looking down at keyboard/desk: off-screen
    var pitchCeiling: Double              // above => looking up: off-screen
    var classes: [UInt32]
    var mean: [Double]
    var scale: [Double]
    var centroids: [[Double]]
    var invCov: [[Double]]
    var maxD2: Double                     // beyond this from every class => outlier (off-screen)

    struct Sample { var features: [Double]; var label: DisplayID; var weight: Double }

    private func pick(_ f: [Double]) -> [Double] { featureIndex.map { f[$0] } }

    /// Feature set for an arrangement: horizontal evidence for side-by-side, vertical for stacked,
    /// both when the displays are offset in both directions.
    enum Source { case head, eyes }

    /// Head: yaw / faceCenter. Eyes: eye offset, with head pose only compensating.
    static func features(for displays: [Displays.Info], source: Source = .head) -> [Int] {
        let horizontalFeatures = source == .head ? [0, 2] : [5, 0]
        let verticalFeatures = source == .head ? [1, 3] : [6, 1]
        let cx = displays.map { $0.frame.midX }, cy = displays.map { $0.frame.midY }
        let sx = (cx.max() ?? 0) - (cx.min() ?? 0), sy = (cy.max() ?? 0) - (cy.min() ?? 0)
        if sx >= sy { return sy > 0.25 * sx ? horizontalFeatures + verticalFeatures : horizontalFeatures }
        return sx > 0.25 * sy ? horizontalFeatures + verticalFeatures : verticalFeatures
    }

    static func fit(_ samples: [Sample], featureIndex: [Int], shrinkage: Double = 0.3) -> DisplayClassifier? {
        let classes = Array(Set(samples.map { $0.label })).sorted()
        guard !classes.isEmpty,
              classes.allSatisfy({ c in samples.filter { $0.label == c }.count >= minPerClass }) else { return nil }
        let x = samples.map { s in featureIndex.map { s.features[$0] } }
        let n = featureIndex.count
        let wsum = samples.reduce(0) { $0 + $1.weight }
        var mean = [Double](repeating: 0, count: n)
        for (r, s) in zip(x, samples) { for j in 0..<n { mean[j] += r[j] * s.weight } }
        mean = mean.map { $0 / wsum }
        var scale = [Double](repeating: 0, count: n)
        for (r, s) in zip(x, samples) { for j in 0..<n { let d = r[j] - mean[j]; scale[j] += d * d * s.weight } }
        scale = scale.map { let sd = ($0 / wsum).squareRoot(); return sd < 1e-9 ? 1 : sd }
        let z = x.map { r in (0..<n).map { (r[$0] - mean[$0]) / scale[$0] } }

        var cents: [[Double]] = []
        var cov = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for c in classes {
            let idx = samples.indices.filter { samples[$0].label == c }
            let w = idx.reduce(0) { $0 + samples[$1].weight }
            var cen = [Double](repeating: 0, count: n)
            for i in idx { for j in 0..<n { cen[j] += z[i][j] * samples[i].weight } }
            cen = cen.map { $0 / w }
            for i in idx {
                for a in 0..<n { for b in 0..<n { cov[a][b] += samples[i].weight * (z[i][a] - cen[a]) * (z[i][b] - cen[b]) } }
            }
            cents.append(cen)
        }
        let tr = (0..<n).reduce(0) { $0 + cov[$1][$1] / wsum } / Double(n)
        for a in 0..<n { for b in 0..<n {
            cov[a][b] = (1 - shrinkage) * cov[a][b] / wsum + (a == b ? shrinkage * max(tr, 1e-6) : 0)
        } }
        // Invert via column solves.
        var inv = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for j in 0..<n {
            var e = [Double](repeating: 0, count: n); e[j] = 1
            guard let col = GazeModel.solve(cov, e) else { return nil }
            for i in 0..<n { inv[i][j] = col[i] }
        }
        let pitches = samples.map { $0.features[pitchIndex] }
        let pLo = pitches.min()!, pHi = pitches.max()!, span = pHi - pLo
        var model = DisplayClassifier(featureIndex: featureIndex, pitchFloor: pLo - max(0.03, 0.25 * span),
                                      pitchCeiling: pHi + max(0.05, 0.4 * span), classes: classes, mean: mean, scale: scale, centroids: cents, invCov: inv, maxD2: .infinity)
        let own = samples.indices.map { i -> Double in
            model.d2(z[i], model.centroids[classes.firstIndex(of: samples[i].label)!])
        }.sorted()
        let q95 = own[min(own.count - 1, Int(Double(own.count) * 0.95))]
        model.maxD2 = max(25, 3 * q95)
        return model
    }

    func d2(_ z: [Double], _ c: [Double]) -> Double {
        let n = z.count
        var d = [Double](repeating: 0, count: n)
        for i in 0..<n { d[i] = z[i] - c[i] }
        var s = 0.0
        for a in 0..<n { for b in 0..<n { s += d[a] * invCov[a][b] * d[b] } }
        return s
    }

    struct Result { var id: DisplayID; var probability: Double; var minD2: Double }

    func isOffscreenPitch(_ pitch: Double) -> Bool { pitch < pitchFloor || pitch > pitchCeiling }

    /// Class posteriors (same order as `classes`) with the edgeBias log-odds shift applied.
    func posterior(_ f: [Double], edgeBias: Double, positions: [DisplayID: Double]) -> (post: [Double], minD2: Double) {
        let raw = pick(f)
        let z = (0..<raw.count).map { (raw[$0] - mean[$0]) / scale[$0] }
        var scores: [Double] = [], minD2 = Double.infinity
        let k = DisplayClassifier.edgeBiasStrength * (min(max(edgeBias, 0), 1) - 0.5)
        for (i, c) in classes.enumerated() {
            let d = d2(z, centroids[i])
            minD2 = min(minD2, d)
            scores.append(-0.5 * d - k * (positions[c] ?? 0))
        }
        let top = scores.max()!
        let exps = scores.map { exp($0 - top) }
        let total = exps.reduce(0, +)
        return (exps.map { $0 / total }, minD2)
    }

    /// Leaving `current` needs a posterior >= `leaveThreshold`; entering from nowhere takes the argmax.
    static func decide(classes: [DisplayID], post: [Double], current: DisplayID?, primary: DisplayID?) -> (id: DisplayID, probability: Double) {
        let best = post.indices.max { post[$0] < post[$1] }!
        if let cur = current, let ci = classes.firstIndex(of: cur), ci != best,
           post[best] < (classes[best] == primary ? enterPrimaryThreshold : leaveThreshold) {
            return (cur, post[ci])
        }
        return (classes[best], post[best])
    }

    /// `positions`: per-display coordinate in -1...1 along the arrangement's main axis (for edgeBias).
    func classify(_ f: [Double], current: DisplayID?, edgeBias: Double, positions: [DisplayID: Double], primary: DisplayID? = nil) -> Result {
        let (post, minD2) = posterior(f, edgeBias: edgeBias, positions: positions)
        let d = Self.decide(classes: classes, post: post, current: current, primary: primary)
        return Result(id: d.id, probability: d.probability, minD2: minD2)
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
    struct StoredSample: Codable {
        var f: [Double]; var x: Double; var y: Double; var w: Double; var click: Bool
        /// Captured with the head held still (eyes-only phase). nil in profiles saved before gaze modes.
        var eyes: Bool? = nil
    }
    struct StoredDisplay: Codable, Equatable { var id: UInt32; var x: Double; var y: Double; var w: Double; var h: Double }
    /// One calibration for one display arrangement.
    struct Profile: Codable {
        var arrangement: [StoredDisplay]
        var samples: [StoredSample]
        var model: GazeModel?
        var classifier: DisplayClassifier?
        var eyeModel: GazeModel?
        var eyeClassifier: DisplayClassifier?
    }
    struct Persisted: Codable {
        var version = 2
        var profiles: [String: Profile] = [:]
        // v1 (single calibration) fields, read for migration only.
        var arrangement: [StoredDisplay]?
        var samples: [StoredSample]?
        var model: GazeModel?
    }

    public static let defaultURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlanceSwitch/calibration.json")
    }()

    public static let minConfidence = 0.3
    static let blinkThreshold = 0.5
    static let minEyeSamplesPerDisplay = 4
    static let maxClickSamples = 150
    static let clickWeightThreshold = 0.9
    static let refitEveryClicks = 10
    static let driftAlpha = 0.1

    private let lock = NSLock()
    private let url: URL
    private let displaysProvider: () -> [Displays.Info]
    /// Every known profile except the active one's live edits, which sit in the fields below.
    private var profiles: [String: Profile] = [:]
    private var activeSignature: String?
    private var calibration: [StoredSample] = []
    private var clicks: [StoredSample] = []     // bounded rolling buffer, oldest dropped first
    private var model: GazeModel?
    private var classifier: DisplayClassifier?
    private var classifierTried = false
    private var eyeModel: GazeModel?
    private var eyeClassifier: DisplayClassifier?
    private var lastEye: (dx: Double, dy: Double)?
    /// Test hook: treat every calibration sample as eyes-only data when training the eye component.
    var treatAllAsEyes = false
    /// Test hook: false = old pipeline (regression point -> DisplayResolver only).
    var useClassifier = true
    var ridge = 0.03
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

    /// Stable key for a display arrangement (ids, sizes, positions).
    static func signature(of d: [Displays.Info]) -> String {
        arrangement(of: d).sorted { $0.id < $1.id }.map { "\($0.id):\(Int($0.x.rounded())),\(Int($0.y.rounded())),\(Int($0.w.rounded()))x\(Int($0.h.rounded()))" }
            .joined(separator: "|")
    }

    /// Switch the live state to the profile for `sig` (caller holds the lock).
    private func activate(_ sig: String, displays: [Displays.Info]) {
        guard sig != activeSignature else { return }
        stashActive(displays: nil)
        let p = profiles[sig]
        calibration = p?.samples.filter { !$0.click } ?? []
        clicks = Array((p?.samples.filter { $0.click } ?? []).suffix(Self.maxClickSamples))
        model = p?.model
        classifier = p?.classifier
        eyeModel = p?.eyeModel
        eyeClassifier = p?.eyeClassifier
        classifierTried = false
        lastEye = nil
        drift = 0; clicksSinceFit = 0
        activeSignature = sig
        // Profiles saved before gaze modes hold a model that mixed in the eye terms: refit as head + eye parts.
        if model != nil, model?.columns != GazeModel.headColumns
            || (classifier != nil && classifier?.featureIndex != DisplayClassifier.features(for: displays, source: .head)) {
            _ = retrainLocked(displays: displays)
        }
    }

    /// Write the live state back into `profiles` (caller holds the lock).
    private func stashActive(displays: [Displays.Info]?) {
        guard let sig = activeSignature else { return }
        if model == nil && calibration.isEmpty && clicks.isEmpty { profiles[sig] = nil; return }
        let arr = displays.map { Self.arrangement(of: $0) } ?? profiles[sig]?.arrangement ?? []
        profiles[sig] = Profile(arrangement: arr, samples: calibration + clicks, model: model, classifier: classifier,
                               eyeModel: eyeModel, eyeClassifier: eyeClassifier)
    }

    private func syncToCurrent() -> [Displays.Info] {
        let d = displaysProvider()
        activate(Self.signature(of: d), displays: d)
        return d
    }

    public var isCalibrated: Bool {
        lock.lock(); defer { lock.unlock() }
        _ = syncToCurrent()
        return model != nil
    }

    /// Number of known arrangement profiles (including the active one).
    public var profileCount: Int {
        lock.lock(); defer { lock.unlock() }
        _ = syncToCurrent(); stashActive(displays: displaysProvider())
        return profiles.count
    }

    public var sampleCount: Int { lock.lock(); defer { lock.unlock() }; _ = syncToCurrent(); return calibration.count + clicks.count }

    public var driftScore: Double { lock.lock(); defer { lock.unlock() }; return drift }
    /// Which signal decides (set from Settings). Eyes / both need eye calibration; without it they use the head.
    public var gazeMode: GazeMode = .both
    /// 0...1, share of the decision given to the eyes in `.both`.
    public var eyeWeight: Double = 0.7

    /// True when the profile for the current arrangement has no eyes-only calibration, so eyes / both
    /// fall back to head. The UI can use it to suggest recalibrating for eye tracking.
    public var needsEyeCalibration: Bool {
        lock.lock(); defer { lock.unlock() }
        _ = syncToCurrent()
        return model != nil && (eyeModel == nil || eyeClassifier == nil)
    }

    public func estimate(_ pose: HeadPose, currentDisplay: DisplayID?, edgeBias: Double) -> GazeEstimate? {
        estimate(pose, currentDisplay: currentDisplay, edgeBias: edgeBias, displays: displaysProvider())
    }

    /// Core entry with explicit displays (used by tests).
    func estimate(_ pose: HeadPose, currentDisplay: DisplayID?, edgeBias: Double,
                  displays: [Displays.Info]) -> GazeEstimate? {
        lock.lock()
        activate(Self.signature(of: displays), displays: displays)
        let m = model, em = eyeModel, eclf = eyeClassifier
        if classifier == nil, m != nil, !classifierTried {
            classifierTried = true
            classifier = trainClassifier(displays: displays)
        }
        let hclf = classifier.flatMap { Set($0.classes) == Set(displays.map { $0.id }) ? $0 : nil }
        // A blink makes the eye values junk: hold the last good ones.
        let blink = pose.eyeOpenness < Self.blinkThreshold
        var f = pose.features
        var haveEye = true
        if blink {
            if let e = lastEye { f[5] = e.dx; f[6] = e.dy } else { haveEye = false }
        } else if pose.confidence >= Self.minConfidence {
            lastEye = (f[5], f[6])
        }
        let mode = gazeMode, ew = min(max(eyeWeight, 0), 1)
        lock.unlock()
        guard let m, pose.confidence >= Self.minConfidence else { return nil }

        // Eyes / both need the eye component; otherwise (old profile, or no eye frame yet) use the head.
        let eyesUsable = em != nil && eclf != nil && haveEye
        let w: Double = !eyesUsable ? 0 : mode == .head ? 0 : mode == .eyes ? 1 : ew
        let ph = m.predict(f)
        var p = ph
        if w > 0, let em { let pe = em.predict(f); p = CGPoint(x: (1 - w) * ph.x + w * pe.x, y: (1 - w) * ph.y + w * pe.y) }
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let r = DisplayResolver.resolve(p, displays: displays, current: currentDisplay, edgeBias: edgeBias)
        var conf = pose.confidence
        if useClassifier, let clf = hclf {
            // Looking down at the keyboard/desk (or up) is off-screen, never another display.
            if clf.isOffscreenPitch(pose.pitch) {
                return GazeEstimate(point: p, displayID: nil, confidence: conf * 0.5)
            }
            let pos = Self.positions(of: displays)
            var (post, minD2) = clf.posterior(f, edgeBias: edgeBias, positions: pos)
            var outlier = minD2 / clf.maxD2
            if w > 0, let eclf, eclf.classes == clf.classes {
                let e = eclf.posterior(f, edgeBias: edgeBias, positions: pos)
                post = zip(post, e.post).map { (1 - w) * $0 + w * $1 }
                outlier = (1 - w) * outlier + w * e.minD2 / eclf.maxD2
            }
            let primary = displays.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.id
            let d = DisplayClassifier.decide(classes: clf.classes, post: post, current: currentDisplay, primary: primary)
            // A blink in an eye-driven mode never moves focus.
            if blink && w > 0, let cur = currentDisplay, d.id != cur {
                return GazeEstimate(point: p, displayID: cur, confidence: conf * 0.5)
            }
            // Off-screen only when the pose is an outlier for every display AND the regressed
            // point also lies outside every display's margin (the point alone is noisy in y).
            let union = displays.map { $0.frame }.reduce(CGRect.null) { $0.union($1) }
            let slack = CGFloat(DisplayResolver.offscreenMargin) * union.width / CGFloat(max(displays.count, 1))
            let beyondX = p.x < union.minX - slack || p.x > union.maxX + slack
            if r.id == nil && (outlier > 1 || beyondX) {
                return GazeEstimate(point: p, displayID: nil, confidence: conf * 0.5)
            }
            return GazeEstimate(point: p, displayID: d.id, confidence: conf * (0.5 + 0.5 * d.probability))
        }
        if let id = r.id, let d = displays.first(where: { $0.id == id }) {
            let ref = 0.1 * Double(min(d.frame.width, d.frame.height))
            conf *= 0.5 + 0.5 * min(1, max(0, Double(r.edgeDistance)) / ref)
        } else {
            conf *= 0.5
        }
        return GazeEstimate(point: p, displayID: r.id, confidence: conf)
    }

    /// Position of each display along the arrangement's main axis, -1...1 (0 when there is one display).
    static func positions(of displays: [Displays.Info]) -> [DisplayID: Double] {
        let cx = displays.map { $0.frame.midX }, cy = displays.map { $0.frame.midY }
        guard let x0 = cx.min(), let x1 = cx.max(), let y0 = cy.min(), let y1 = cy.max() else { return [:] }
        let horizontal = (x1 - x0) >= (y1 - y0)
        let (lo, hi) = horizontal ? (x0, x1) : (y0, y1)
        var out: [DisplayID: Double] = [:]
        for d in displays {
            out[d.id] = hi - lo < 1 ? 0 : Double(((horizontal ? d.frame.midX : d.frame.midY) - lo) / (hi - lo)) * 2 - 1
        }
        return out
    }

    private static func label(_ p: CGPoint, _ displays: [Displays.Info]) -> DisplayID? {
        displays.min { a, b in dist(p, a.frame) < dist(p, b.frame) }?.id
    }
    private static func dist(_ p: CGPoint, _ f: CGRect) -> CGFloat {
        let dx = max(f.minX - p.x, 0, p.x - f.maxX), dy = max(f.minY - p.y, 0, p.y - f.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func trainClassifier(displays: [Displays.Info], source: DisplayClassifier.Source = .head,
                                 eyesOnlyBoost: Double = 1) -> DisplayClassifier? {
        let samples = (calibration + clicks).compactMap { s -> DisplayClassifier.Sample? in
            guard let l = Self.label(CGPoint(x: s.x, y: s.y), displays) else { return nil }
            let boost = isEyes(s) ? eyesOnlyBoost : 1
            return DisplayClassifier.Sample(features: s.f, label: l, weight: s.w * boost)
        }
        return DisplayClassifier.fit(samples, featureIndex: DisplayClassifier.features(for: displays, source: source))
    }

    private func isEyes(_ s: StoredSample) -> Bool { s.eyes == true || (treatAllAsEyes && !s.click) }

    /// Refit the head model, and the eye model + classifiers when there is enough eyes-only data.
    /// Caller holds the lock. Returns false (leaving state untouched) when there is too little data.
    private func retrainLocked(displays: [Displays.Info]) -> Bool {
        let all = calibration + clicks
        func samples(_ boost: Double) -> [GazeModel.Sample] {
            all.map { GazeModel.Sample(features: $0.f, target: CGPoint(x: $0.x, y: $0.y), weight: $0.w * (isEyes($0) ? boost : 1)) }
        }
        guard let head = GazeModel.fit(samples(1), ridge: ridge, columns: GazeModel.headColumns) else { return false }
        model = head; clicksSinceFit = 0
        classifier = trainClassifier(displays: displays); classifierTried = true
        eyeModel = nil; eyeClassifier = nil
        // Eye component: needs head-still samples on every display.
        let eyeCounts = Dictionary(grouping: calibration.filter { isEyes($0) }.compactMap { Self.label(CGPoint(x: $0.x, y: $0.y), displays) }, by: { $0 })
        if displays.allSatisfy({ (eyeCounts[$0.id]?.count ?? 0) >= Self.minEyeSamplesPerDisplay }) {
            // Eye-in-head drives it; head columns are heavily regularised so they only compensate.
            let cols = Array(0..<12)
            let pen = cols.map { GazeModel.headColumns.contains($0) ? 8.0 : 1.0 }
            if let em = GazeModel.fit(samples(2), ridge: ridge, columns: cols, penalty: pen),
               let ec = trainClassifier(displays: displays, source: .eyes, eyesOnlyBoost: 2) {
                eyeModel = em; eyeClassifier = ec
            }
        }
        return true
    }

    public func addSample(_ pose: HeadPose, target: CGPoint, weight: Double) {
        addSample(pose, target: target, weight: weight, eyesOnly: false)
    }

    /// `eyesOnly`: the head was held still while the eyes followed the target (guided eye phase).
    public func addSample(_ pose: HeadPose, target: CGPoint, weight: Double, eyesOnly: Bool) {
        guard pose.features.allSatisfy({ $0.isFinite }) else { return }
        let s = StoredSample(f: pose.features, x: Double(target.x), y: Double(target.y),
                             w: weight, click: weight < Self.clickWeightThreshold, eyes: eyesOnly ? true : nil)
        lock.lock()
        _ = syncToCurrent()
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
        lock.lock(); defer { lock.unlock() }
        _ = syncToCurrent()
        return retrainLocked(displays: displaysProvider())
    }

    /// Clears only the profile for the current arrangement.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        let d = displaysProvider()
        let sig = Self.signature(of: d)
        profiles[sig] = nil
        activeSignature = sig
        calibration = []; clicks = []; model = nil; classifier = nil; eyeModel = nil; eyeClassifier = nil; lastEye = nil; classifierTried = false; drift = 0; clicksSinceFit = 0
    }

    public func save() throws {
        lock.lock()
        let d = syncToCurrent()
        stashActive(displays: d)
        let blob = Persisted(profiles: profiles)
        lock.unlock()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(blob).write(to: url, options: .atomic)
    }

    /// Loads all profiles and activates the one matching the current arrangement.
    public func load() throws {
        let blob = try JSONDecoder().decode(Persisted.self, from: Data(contentsOf: url))
        var loaded = blob.profiles
        if let arr = blob.arrangement, let samples = blob.samples {   // v1 migration
            let sig = arr.map { "\($0.id):\(Int($0.x.rounded())),\(Int($0.y.rounded())),\(Int($0.w.rounded()))x\(Int($0.h.rounded()))" }
                .joined(separator: "|")
            if loaded[sig] == nil { loaded[sig] = Profile(arrangement: arr, samples: samples, model: blob.model) }
        }
        lock.lock(); defer { lock.unlock() }
        profiles = loaded
        activeSignature = nil
        _ = syncToCurrent()
    }

    public func recordClickOutcome(predicted: DisplayID?, actual: DisplayID) {
        let miss = predicted == actual ? 0.0 : 1.0
        lock.lock(); defer { lock.unlock() }
        drift = drift * (1 - Self.driftAlpha) + miss * Self.driftAlpha
    }
}
