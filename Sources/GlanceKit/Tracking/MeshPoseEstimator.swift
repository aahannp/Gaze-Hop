// OWNER: Tracking worker.
// MediaPipe Face Landmarker (Apache-2.0) via ONNX Runtime: BlazeFace detector (only when the
// face is lost) + 478-point face/iris mesh on a rotated crop tracked from the previous frame.
// Produces the same HeadPose contract as the Vision estimator.
//
// Pose: a face frame is built from 3D mesh points (eye outer corners 33/263, forehead 10, chin 152).
// Camera frame: X image-right, Y image-down, Z into the screen. The face's forward vector is the
// face-frame normal pointing at the camera. Contract signs (user's view, image not mirrored):
// yaw + = nose toward image-LEFT, pitch + = nose up, roll + = clockwise for the user.
import Foundation
import CoreVideo
import OnnxRuntimeBindings

struct MeshModelPaths {
    let detector: String
    let landmarks: String

    static func locate() -> MeshModelPaths? {
        var dirs = [URL]()
        if let env = ProcessInfo.processInfo.environment["GLANCE_MESH_MODELS"] { dirs.append(URL(fileURLWithPath: env)) }
        dirs.append(Bundle.module.resourceURL!.appendingPathComponent("Models"))
        if let r = Bundle.main.resourceURL {
            dirs.append(r.appendingPathComponent("GlanceSwitch_GlanceKit.bundle/Models"))
            dirs.append(r.appendingPathComponent("Models"))
        }
        for d in dirs {
            let a = d.appendingPathComponent("face_detector.onnx").path
            let b = d.appendingPathComponent("face_landmarks_detector.onnx").path
            if FileManager.default.fileExists(atPath: a), FileManager.default.fileExists(atPath: b) {
                return MeshModelPaths(detector: a, landmarks: b)
            }
        }
        return nil
    }
}

/// Thin wrapper: float tensor in -> named float tensors out.
private final class OnnxModel {
    let session: ORTSession
    let inputName: String
    let shape: [NSNumber]
    let outputNames: Set<String>
    private let input: NSMutableData

    init(path: String, env: ORTEnv, inputName: String, side: Int, outputs: [String], coreML: Bool) throws {
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(2)
        if coreML { try opts.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions()) }
        session = try ORTSession(env: env, modelPath: path, sessionOptions: opts)
        self.inputName = inputName
        shape = [1, NSNumber(value: side), NSNumber(value: side), 3]
        outputNames = Set(outputs)
        input = NSMutableData(length: side * side * 3 * MemoryLayout<Float>.size)!
    }

    /// Fill via `fill` (writes side*side*3 floats), run, return outputs.
    func run(fill: (UnsafeMutablePointer<Float>) -> Void) throws -> [String: [Float]] {
        fill(input.mutableBytes.assumingMemoryBound(to: Float.self))
        let value = try ORTValue(tensorData: input, elementType: .float, shape: shape)
        let out = try session.run(withInputs: [inputName: value], outputNames: outputNames, runOptions: nil)
        var result = [String: [Float]]()
        for (k, v) in out {
            let d = try v.tensorData() as Data
            result[k] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return result
    }
}

final class MeshPoseEstimator: FramePoseEstimator {
    fileprivate struct ROI { var cx: Double; var cy: Double; var size: Double; var angle: Double }

    private let env: ORTEnv
    private let detector: OnnxModel
    private let landmarker: OnnxModel
    private var smoother: PoseSmoother
    private var roi: ROI?
    private var anchors: [(x: Float, y: Float)] = []

    /// Stage timings of the last call, ms (for the benchmark).
    var lastDetectMs = 0.0, lastLandmarkMs = 0.0
    /// Unsmoothed channels of the last pose (yaw, pitch, roll, cx, cy, size, eyeX, eyeY).
    private(set) var lastRaw: [Double]?

    init?(coreML: Bool = ProcessInfo.processInfo.environment["GLANCE_MESH_COREML"] == "1",
          smoother: PoseSmoother.Config = PoseSmoother.mesh) {
        guard let paths = MeshModelPaths.locate(),
              let env = try? ORTEnv(loggingLevel: .warning),
              let det = try? OnnxModel(path: paths.detector, env: env, inputName: "input", side: 128,
                                       outputs: ["regressors", "classificators"], coreML: coreML),
              let lm = try? OnnxModel(path: paths.landmarks, env: env, inputName: "input_12", side: 256,
                                      outputs: ["Identity", "Identity_1"], coreML: coreML)
        else { return nil }
        self.env = env; detector = det; landmarker = lm
        self.smoother = PoseSmoother(config: smoother)
        anchors = Self.makeAnchors()
    }

    func reset() { smoother.reset(); roi = nil }

    // MARK: pipeline

    func estimate(_ buffer: CVPixelBuffer, t: TimeInterval) -> HeadPose? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let img = Image(base: base.assumingMemoryBound(to: UInt8.self), w: w, h: h, stride: stride)
        lastDetectMs = 0

        if roi == nil {
            let t0 = ProcessInfo.processInfo.systemUptime
            roi = detect(img)
            lastDetectMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        }
        guard let r = roi else { return nil }

        let t1 = ProcessInfo.processInfo.systemUptime
        let outputs = try? landmarker.run { img.crop(r, side: 256, offset: 0, scale: 1.0 / 255.0, into: $0) }
        lastLandmarkMs = (ProcessInfo.processInfo.systemUptime - t1) * 1000
        guard let out = outputs, let flat = out["Identity"], flat.count >= 478 * 3,
              let flag = out["Identity_1"]?.first else { roi = nil; return nil }
        let presence = 1 / (1 + exp(-Double(flag)))
        guard presence >= 0.5 else { roi = nil; return nil }

        // Mesh -> image pixel space (z scaled like x/y).
        let n = 478
        var pts = [SIMD3<Double>](repeating: .zero, count: n)
        let ca = cos(r.angle), sa = sin(r.angle), k = r.size / 256
        for i in 0..<n {
            let a = Double(flat[i * 3]) / 256 - 0.5, b = Double(flat[i * 3 + 1]) / 256 - 0.5
            pts[i] = SIMD3(r.cx + r.size * (a * ca - b * sa), r.cy + r.size * (a * sa + b * ca), Double(flat[i * 3 + 2]) * k)
        }

        // Next ROI from this mesh (MediaPipe: rotation from landmarks 33 -> 263, scale 1.5, square).
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for i in 0..<468 { minX = min(minX, pts[i].x); maxX = max(maxX, pts[i].x); minY = min(minY, pts[i].y); maxY = max(maxY, pts[i].y) }
        let eyeV = pts[263] - pts[33]
        roi = ROI(cx: (minX + maxX) / 2, cy: (minY + maxY) / 2, size: max(maxX - minX, maxY - minY) * 1.5,
                  angle: atan2(eyeV.y, eyeV.x))

        let raw = Self.channels(pts: pts, w: Double(w), h: Double(h), bbox: (minX, maxX, minY, maxY))
        lastRaw = raw
        let s = smoother.smooth(raw, at: t)
        return HeadPose(timestamp: t, yaw: s[0], pitch: s[1], roll: s[2],
                        faceCenter: CGPoint(x: s[3], y: s[4]), faceSize: s[5],
                        eyeOffset: CGVector(dx: s[6], dy: s[7]), confidence: presence)
    }

    // MARK: pose + iris

    static func channels(pts: [SIMD3<Double>], w: Double, h: Double,
                         bbox: (Double, Double, Double, Double)) -> [Double] {
        func unit(_ v: SIMD3<Double>) -> SIMD3<Double> { v / max((v * v).sum().squareRoot(), 1e-9) }
        let xAxis = unit(pts[263] - pts[33])                         // face-left (image-right when frontal)
        var down = pts[152] - pts[10]
        down = unit(down - xAxis * (down * xAxis).sum())             // forehead -> chin
        let zAxis = unit(SIMD3(xAxis.y * down.z - xAxis.z * down.y,
                               xAxis.z * down.x - xAxis.x * down.z,
                               xAxis.x * down.y - xAxis.y * down.x))  // into the head
        let f = -zAxis                                               // forward: toward the camera
        let yaw = atan2(-f.x, -f.z)
        let pitch = atan2(-f.y, (f.x * f.x + f.z * f.z).squareRoot())
        let roll = -atan2(xAxis.y, xAxis.x)

        // Iris position inside each eye (corners + lids), image-right -> user's left.
        func eye(_ outerL: Int, _ innerR: Int, _ iris: Int, _ up: Int, _ low: Int) -> (Double, Double)? {
            let a = pts[outerL], b = pts[innerR]
            let ab = b - a
            let half = (ab * ab).sum().squareRoot() / 2
            guard half > 1 else { return nil }
            let u = SIMD3(ab.x / (2 * half), ab.y / (2 * half), 0)
            let vDown = SIMD3(-u.y, u.x, 0)
            let mid = (a + b) / 2
            let d = pts[iris] - mid
            let t = (d.x * u.x + d.y * u.y) / half
            let lidMid = (pts[up] + pts[low]) / 2
            let lidHalf = max(abs(((pts[low] - pts[up]) * vDown).sum()) / 2, half * 0.2)
            let dv = ((pts[iris] - lidMid) * vDown).sum() / lidHalf
            return (max(-1, min(1, -t)), max(-1, min(1, -dv)))
        }
        // person's right eye = image-left: corners 33 (outer) .. 133 (inner); left eye: 362 (inner) .. 263 (outer)
        let e = [eye(33, 133, 468, 159, 145), eye(362, 263, 473, 386, 374)].compactMap { $0 }
        let ex = e.isEmpty ? 0 : e.map(\.0).reduce(0, +) / Double(e.count)
        let ey = e.isEmpty ? 0 : e.map(\.1).reduce(0, +) / Double(e.count)

        let (minX, maxX, minY, maxY) = bbox
        return [yaw, pitch, roll, 1 - (minX + maxX) / 2 / w, (minY + maxY) / 2 / h, (maxX - minX) / w, ex, ey]
    }

    // MARK: detector

    private func detect(_ img: Image) -> ROI? {
        let side = Double(max(img.w, img.h))
        let sq = ROI(cx: Double(img.w) / 2, cy: Double(img.h) / 2, size: side, angle: 0)
        guard let out = try? detector.run(fill: { img.crop(sq, side: 128, offset: -1, scale: 2.0 / 255.0, into: $0) }),
              let reg = out["regressors"], let cls = out["classificators"], cls.count >= anchors.count else { return nil }
        var best = -1, bestScore: Float = 0
        for i in 0..<anchors.count where cls[i] > bestScore { best = i; bestScore = cls[i] }
        guard best >= 0, 1 / (1 + exp(-Double(bestScore))) >= 0.5 else { return nil }
        let a = anchors[best], r = Array(reg[(best * 16)..<(best * 16 + 16)])
        let cx = Double(r[0] / 128 + a.x), cy = Double(r[1] / 128 + a.y)
        let bw = Double(r[2] / 128), bh = Double(r[3] / 128)
        // keypoints 0 = person's right eye (image-left), 1 = left eye
        let k0 = (x: Double(r[4] / 128 + a.x), y: Double(r[5] / 128 + a.y))
        let k1 = (x: Double(r[6] / 128 + a.x), y: Double(r[7] / 128 + a.y))
        let angle = atan2(k1.y - k0.y, k1.x - k0.x)
        return ROI(cx: sq.cx + (cx - 0.5) * side, cy: sq.cy + (cy - 0.5) * side,
                   size: max(bw, bh) * side * 1.5, angle: angle)
    }

    /// MediaPipe BlazeFace short-range SSD anchors for a 128x128 input (896 anchors, fixed size).
    private static func makeAnchors() -> [(x: Float, y: Float)] {
        var a = [(x: Float, y: Float)]()
        for (grid, per) in [(16, 2), (8, 6)] {
            for y in 0..<grid { for x in 0..<grid {
                for _ in 0..<per { a.append(((Float(x) + 0.5) / Float(grid), (Float(y) + 0.5) / Float(grid))) }
            } }
        }
        return a
    }

    // MARK: image sampling

    fileprivate struct Image {
        let base: UnsafePointer<UInt8>   // BGRA
        let w: Int, h: Int, stride: Int

        /// Rotated square crop -> `side` x `side` RGB floats: value = pixel * scale + offset.
        func crop(_ r: ROI, side: Int, offset: Float, scale: Float, into out: UnsafeMutablePointer<Float>) {
            let ca = cos(r.angle), sa = sin(r.angle)
            let step = 1.0 / Double(side)
            var o = 0
            for v in 0..<side {
                let b = (Double(v) + 0.5) * step - 0.5
                for u in 0..<side {
                    let a = (Double(u) + 0.5) * step - 0.5
                    let sx = r.cx + r.size * (a * ca - b * sa) - 0.5
                    let sy = r.cy + r.size * (a * sa + b * ca) - 0.5
                    let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                    if x0 < -1 || y0 < -1 || x0 >= w || y0 >= h {
                        out[o] = offset; out[o + 1] = offset; out[o + 2] = offset
                    } else {
                        let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                        var c: (Float, Float, Float) = (0, 0, 0)
                        for (dy, wy) in [(0, 1 - fy), (1, fy)] {
                            for (dx, wx) in [(0, 1 - fx), (1, fx)] {
                                let x = x0 + dx, y = y0 + dy
                                guard x >= 0, y >= 0, x < w, y < h else { continue }
                                let p = base + y * stride + x * 4
                                let wgt = wx * wy
                                c.0 += Float(p[2]) * wgt; c.1 += Float(p[1]) * wgt; c.2 += Float(p[0]) * wgt
                            }
                        }
                        out[o] = c.0 * scale + offset; out[o + 1] = c.1 * scale + offset; out[o + 2] = c.2 * scale + offset
                    }
                    o += 3
                }
            }
        }
    }
}
