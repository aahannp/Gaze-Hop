// OWNER: Tracking worker.
// `--mesh-bench [--secs N] [--fps F] [--log path]`: headless. Runs Vision, mesh (CPU) and mesh (CoreML EP)
// on the SAME live frames and prints only statistics. No window; frames are never stored.
import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

final class MeshBenchmark: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Sample { var t: Double; var yaw: Double?; var eyeDx: Double?; var openness: Double?; var rawYaw: Double?; var rawEye: Double? }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "glance.meshbench")
    private let vision = VisionPoseEstimator()
    private let meshCPU = MeshPoseEstimator(coreML: false)
    private let meshML = MeshPoseEstimator(coreML: true)
    private let fps: Double
    private let secs: Double
    private let emit: (String) -> Void
    private var last = 0.0, frames = 0, startT = 0.0
    private var visMs: [Double] = [], cpuMs: [Double] = [], mlMs: [Double] = [], lat: [Double] = [], latML: [Double] = []
    private var vis: [Sample] = [], cpu: [Sample] = []

    init(secs: Double, fps: Double, emit: @escaping (String) -> Void) { self.secs = secs; self.fps = fps; self.emit = emit }

    static func run() -> Never {
        let args = CommandLine.arguments
        func val(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        var handle: FileHandle?
        if let p = val("--log") { FileManager.default.createFile(atPath: p, contents: nil); handle = FileHandle(forWritingAtPath: p) }
        let emit: (String) -> Void = { print($0); handle?.write(Data(($0 + "\n").utf8)) }
        let b = MeshBenchmark(secs: Double(val("--secs") ?? "") ?? 60, fps: Double(val("--fps") ?? "") ?? 15, emit: emit)
        guard b.meshCPU != nil else { emit("mesh models not found"); exit(1) }
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok, let dev = CameraPoseTracker.pickDevice(cameraID: nil),
                  let input = try? AVCaptureDeviceInput(device: dev) else { emit("no camera access"); exit(1) }
            emit("camera: \(dev.localizedName), fps cap \(b.fps), run \(b.secs)s")
            b.session.beginConfiguration()
            b.session.sessionPreset = .hd1280x720
            if b.session.canAddInput(input) { b.session.addInput(input) }
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(b, queue: b.queue)
            if b.session.canAddOutput(out) { b.session.addOutput(out) }
            b.session.commitConfiguration()
            b.session.startRunning()
        }
        RunLoop.main.run(); exit(0)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - last < 0.7 / fps { return }
        last = now
        if startT == 0 { startT = now }
        guard let buf = CMSampleBufferGetImageBuffer(sb), let cpuE = meshCPU, let mlE = meshML else { return }
        let captured = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))   // host clock (== uptime)
        func ms(_ f: () -> HeadPose?) -> (HeadPose?, Double, Double) {
            let t0 = ProcessInfo.processInfo.systemUptime; let p = f(); let t1 = ProcessInfo.processInfo.systemUptime
            return (p, (t1 - t0) * 1000, t1)
        }
        let (vp, vms, _) = ms { vision.estimate(buf, t: now) }
        let (cp, cms, cdone) = ms { cpuE.estimate(buf, t: now) }
        let craw = cpuE.lastRaw
        let (_, mms, mdone) = ms { mlE.estimate(buf, t: now) }
        visMs.append(vms)
        if cp != nil { cpuMs.append(cms); lat.append((cdone - captured) * 1000) }
        if cp != nil { mlMs.append(mms); latML.append((mdone - captured) * 1000) }
        vis.append(Sample(t: now, yaw: vp.map { $0.yaw * 180 / .pi }, eyeDx: vp.map { Double($0.eyeOffset.dx) }, openness: vp?.eyeOpenness, rawYaw: nil, rawEye: nil))
        cpu.append(Sample(t: now, yaw: cp.map { $0.yaw * 180 / .pi }, eyeDx: cp.map { Double($0.eyeOffset.dx) }, openness: cp?.eyeOpenness,
                          rawYaw: craw.map { $0[0] * 180 / .pi }, rawEye: craw?[6]))
        frames += 1
        if now - startT >= secs { session.stopRunning(); report(); exit(0) }
    }

    // MARK: stats

    private func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? .nan : a.sorted()[min(a.count - 1, Int(Double(a.count) * p))] }
    private func line(_ n: String, _ a: [Double]) { emit(String(format: "%-26@ p50 %6.1f  p95 %6.1f  (n=%d)", n as NSString, pct(a, 0.5), pct(a, 0.95), a.count)) }

    /// Noise at rest: std of frame-to-frame differences / sqrt(2), over frames where the signal barely moves.
    private func restJitter(_ x: [Double]) -> Double {
        let d = zip(x, x.dropFirst()).map { $1 - $0 }
        guard d.count > 10 else { return .nan }
        let cut = pct(d.map(abs), 0.8)             // drop the 20% largest steps (real motion)
        let q = d.filter { abs($0) <= cut }
        let m = q.reduce(0, +) / Double(q.count)
        return (q.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(q.count)).squareRoot() / 2.0.squareRoot()
    }

    private func report() {
        emit(String(format: "frames %d (%.1f Hz), face found: vision %d%%  mesh %d%%", frames,
                    Double(frames) / (ProcessInfo.processInfo.systemUptime - startT),
                    100 * vis.filter { $0.yaw != nil }.count / max(frames, 1), 100 * cpu.filter { $0.yaw != nil }.count / max(frames, 1)))
        line("vision inference ms", visMs)
        line("mesh CPU inference ms", cpuMs)
        line("mesh CoreML inference ms", mlMs)
        line("mesh CPU frame->pose ms", lat)
        line("mesh CoreML frame->pose ms", latML)
        let vy = vis.compactMap(\.yaw), cy = cpu.compactMap(\.yaw), ry = cpu.compactMap(\.rawYaw)
        let ve = vis.compactMap(\.eyeDx), ce = cpu.compactMap(\.eyeDx), re = cpu.compactMap(\.rawEye)
        emit(String(format: "rest jitter yaw deg   vision %.2f  mesh %.2f (raw %.2f)", restJitter(vy), restJitter(cy), restJitter(ry)))
        emit(String(format: "rest jitter eye dx    vision %.3f  mesh %.3f (raw %.3f)", restJitter(ve), restJitter(ce), restJitter(re)))
        emit(String(format: "yaw range deg: vision %.1f..%.1f  mesh %.1f..%.1f; eye dx range: vision %.2f..%.2f mesh %.2f..%.2f",
                    vy.min() ?? 0, vy.max() ?? 0, cy.min() ?? 0, cy.max() ?? 0, ve.min() ?? 0, ve.max() ?? 0, ce.min() ?? 0, ce.max() ?? 0))
        emit("blinks (mesh openness<0.35): \(cpu.filter { ($0.openness ?? 1) < 0.35 && $0.yaw != nil }.count)")
        leadReport()
    }

    /// For motions where yaw sweeps >= 8 deg within 1 s: time eye dx crosses 30% of its range vs yaw crossing 30% of its range.
    private func leadReport() {
        var leads: [Double] = []
        let n = cpu.count
        var i = 0
        while i + 15 < n {
            let w = cpu[i..<(i + 15)].filter { $0.yaw != nil && $0.rawEye != nil }
            if w.count >= 12, let y0 = w.first?.rawYaw, let y1 = w.last?.rawYaw, abs(y1 - y0) >= 8 {
                let e0 = w.first!.rawEye!, e1 = w.last!.rawEye!
                func cross(_ v: (Sample) -> Double, _ a: Double, _ b: Double) -> Double? {
                    w.first { ($0.t >= 0) && (v($0) - a) / (b - a) >= 0.3 }?.t
                }
                if abs(e1 - e0) > 0.1, let ty = cross({ $0.rawYaw! }, y0, y1), let te = cross({ $0.rawEye! }, e0, e1) { leads.append((ty - te) * 1000) }
                i += 15
            } else { i += 1 }
        }
        emit(leads.isEmpty ? "iris-vs-yaw lead: no head motions >= 8 deg seen (user away?)"
             : String(format: "iris leads yaw by median %.0f ms (n=%d)", pct(leads, 0.5), leads.count))
    }
}
