// OWNER: Tracking worker.
//
// Camera -> Vision face landmarks -> HeadPose.
//
// Sign handling: Vision runs on the raw (un-mirrored) frame. The user's right is the image's
// left, so x-like quantities are flipped (x -> 1-x, eye dx -> -dx) to give the contract's
// "user's point of view" values. `visionYawSign` / `visionPitchSign` / `visionRollSign` map
// Vision's angle conventions onto the contract; they were verified with `--pose-debug`.
//
// Yaw: Vision's yaw alone is coarse, so it is blended 50/50 with a geometric estimate:
// nose-tip x relative to the midpoint of the face contour, normalized by face width, converted
// to an angle with asin(nx / noseGain). Vision yaw/roll are bucketed on this Mac (yaw in 45deg
// steps, roll in 30deg steps) and pitch is nil, so: yaw = 85% geometric / 15% Vision, roll =
// eye-line angle, pitch = nose-height ratio (approximate scale; the gaze regression absorbs it).
// Every field goes through a 5-sample median (spike rejection) then a One-Euro filter.
import Foundation
import AVFoundation
import Vision
import CoreImage

public enum CameraPoseError: Error, LocalizedError {
    case permissionDenied
    case noCamera
    case cannotConfigure(String)
    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera access denied. Enable it in System Settings > Privacy & Security > Camera."
        case .noCamera: return "No camera found."
        case .cannotConfigure(let why): return "Cannot configure camera: \(why)"
        }
    }
}

public final class CameraPoseTracker: NSObject, PoseSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    public var onPose: ((HeadPose?) -> Void)?
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    // Vision convention -> contract convention.
    static let visionYawSign = 1.0
    static let visionPitchSign = 1.0
    static let visionRollSign = 1.0
    static let noseGain = 0.6          // nx at yaw = 90deg (nose protrusion / inter-eye distance)
    static let pitchNeutralRatio = 0.5
    static let pitchGain = 2.0         // rad per unit of ratio change
    static let yawBlend = 0.85         // weight of the geometric estimate (Vision yaw is bucketed to 22.5 deg steps)
    static let minConfidence = 0.5
    static let maxFPS = 15.0

    /// Last unfiltered yaw inputs (debug output only; racy by design).
    nonisolated(unsafe) static var debugRawStorage: (Double, Double?) = (0, nil)
    private var debugRaw: (Double, Double?) { get { Self.debugRawStorage } set { Self.debugRawStorage = newValue } }

    private let lock = NSLock()
    private var running = false
    private var generation = 0          // bumps on every start/stop to drop stale async work

    private let sessionQueue = DispatchQueue(label: "glance.camera.session")
    private let videoQueue = DispatchQueue(label: "glance.camera.video")
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?

    // Touched only on videoQueue.
    private var lastFrameTime = 0.0
    private var filters = CameraPoseTracker.makeFilters()
    private var hadFace = false
    private var medians = [MedianWindow](repeating: MedianWindow(size: 5), count: 8)  // spike rejection before One-Euro
    private let sequence = VNSequenceRequestHandler()

    public override init() { super.init() }

    private static func makeFilters() -> [OneEuroFilter] {
        // yaw, pitch, roll, cx, cy, size, eyeX, eyeY
        let angle = OneEuroFilter(minCutoff: 0.8, beta: 0.6, dCutoff: 1.0)
        let pos = OneEuroFilter(minCutoff: 1.5, beta: 1.0, dCutoff: 1.0)
        let eye = OneEuroFilter(minCutoff: 1.0, beta: 1.0, dCutoff: 1.0)
        return [angle, angle, angle, pos, pos, pos, eye, eye]
    }

    // MARK: PoseSource

    public static func availableCameras() -> [CameraInfo] {
        discovery().devices.map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
    }

    static func isContinuity(_ d: AVCaptureDevice) -> Bool {
        d.deviceType == .continuityCamera || d.isContinuityCamera
    }

    static func pickDevice(cameraID: String?) -> AVCaptureDevice? {
        let all = discovery().devices
        if let id = cameraID, let d = all.first(where: { $0.uniqueID == id }) { return d }
        let usable = all.filter { !isContinuity($0) && $0.deviceType != .deskViewCamera }
        return usable.first { $0.deviceType == .external }
            ?? usable.first { $0.deviceType == .builtInWideAngleCamera }
            ?? usable.first
    }

    public func start(cameraID: String?) throws {
        stop()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: throw CameraPoseError.permissionDenied
        default: break
        }
        guard let device = Self.pickDevice(cameraID: cameraID) else { throw CameraPoseError.noCamera }

        lock.lock(); generation += 1; let gen = generation; running = true; lock.unlock()

        let begin = { [weak self] in
            self?.sessionQueue.async { self?.configureAndRun(device: device, gen: gen) }
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { begin() } else { self.lock.lock(); if self.generation == gen { self.running = false }; self.lock.unlock() }
            }
        } else {
            begin()
        }
    }

    public func stop() {
        lock.lock(); generation += 1; running = false; lock.unlock()
        sessionQueue.sync { teardown() }
    }

    // MARK: Session (sessionQueue)

    private func configureAndRun(device: AVCaptureDevice, gen: Int) {
        lock.lock(); let current = generation == gen; lock.unlock()
        guard current else { return }

        let s = AVCaptureSession()
        s.beginConfiguration()
        for preset in [AVCaptureSession.Preset.hd1280x720, .vga640x480, .medium] where s.canSetSessionPreset(preset) {
            s.sessionPreset = preset; break
        }
        guard let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) else {
            s.commitConfiguration(); markFailed(gen); return
        }
        s.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: videoQueue)
        guard s.canAddOutput(out) else { s.commitConfiguration(); markFailed(gen); return }
        s.addOutput(out)
        s.commitConfiguration()

        // Frame-rate cap (after the preset: changing a preset resets durations).
        if (try? device.lockForConfiguration()) != nil {
            let dur = CMTime(value: 1, timescale: CMTimeScale(Self.maxFPS))
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            if ranges.contains(where: { $0.minFrameDuration <= dur && dur <= $0.maxFrameDuration }) || ranges.isEmpty == false {
                device.activeVideoMinFrameDuration = max(dur, ranges.map(\.minFrameDuration).min() ?? dur)
            }
            device.unlockForConfiguration()
        }

        lock.lock(); let still = generation == gen; lock.unlock()
        guard still else { return }
        videoQueue.sync {
            lastFrameTime = 0; hadFace = false; filters = Self.makeFilters(); medians = medians.map { MedianWindow(size: $0.size) }
        }
        session = s; output = out
        s.startRunning()
    }

    private func markFailed(_ gen: Int) {
        lock.lock(); if generation == gen { running = false }; lock.unlock()
    }

    private func teardown() {
        if let s = session {
            output?.setSampleBufferDelegate(nil, queue: nil)
            s.stopRunning()
            s.beginConfiguration()
            s.inputs.forEach { s.removeInput($0) }
            s.outputs.forEach { s.removeOutput($0) }
            s.commitConfiguration()
        }
        session = nil; output = nil
    }

    // MARK: Frames (videoQueue)

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFrameTime < 1.0 / (Self.maxFPS + 1.0) { return }
        lastFrameTime = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock(); let gen = generation; lock.unlock()

        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        let pose: HeadPose?
        do {
            try sequence.perform([request], on: buffer, orientation: .up)
            pose = makePose(from: request.results ?? [], t: now)
        } catch {
            pose = nil
        }
        if pose == nil && hadFace { filters = Self.makeFilters(); medians = medians.map { MedianWindow(size: $0.size) } }
        hadFace = pose != nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let ok = self.generation == gen && self.running; self.lock.unlock()
            if ok { self.onPose?(pose) }
        }
    }

    private func makePose(from faces: [VNFaceObservation], t: TimeInterval) -> HeadPose? {
        guard let face = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
              Double(face.confidence) >= Self.minConfidence else { return nil }

        let box = face.boundingBox   // normalized, origin bottom-left, raw (un-mirrored) image
        let visionYaw = (face.yaw?.doubleValue ?? 0) * Self.visionYawSign
        var pitch = (face.pitch?.doubleValue).map { $0 * Self.visionPitchSign } ?? 0
        var roll = (face.roll?.doubleValue ?? 0) * Self.visionRollSign   // bucketed (0/±30deg) -> replaced by eye-line angle below

        var yaw = visionYaw
        var geoYaw: Double?
        var eye = CGVector.zero
        if let lm = face.landmarks {
            geoYaw = geometricYaw(lm)
            if let g = geoYaw { yaw = (1 - Self.yawBlend) * visionYaw + Self.yawBlend * g }
            eye = eyeOffset(lm)
            if let r = eyeLineRoll(lm) { roll = r }
            // Vision reports no pitch on many Macs (nil) -> landmark-based estimate.
            if face.pitch == nil, let g = geometricPitch(lm) { pitch = g }
        }

        debugRaw = (visionYaw, geoYaw)
        let cx = 1 - Double(box.midX)      // flip to user's view
        let cy = 1 - Double(box.midY)      // Vision y is up; contract y is down
        let vals = [yaw, pitch, roll, cx, cy, Double(box.width), Double(eye.dx), Double(eye.dy)]
        var out = [Double](repeating: 0, count: vals.count)
        for i in vals.indices { out[i] = filters[i].filter(medians[i].push(vals[i]), at: t) }

        return HeadPose(timestamp: t, yaw: out[0], pitch: out[1], roll: out[2],
                        faceCenter: CGPoint(x: out[3], y: out[4]), faceSize: out[5],
                        eyeOffset: CGVector(dx: out[6], dy: out[7]), confidence: Double(face.confidence))
    }

    /// Nose-tip offset from the midpoint between the eyes, in units of inter-eye distance,
    /// converted to a yaw angle in the user's frame: yaw = asin(nx / noseGain).
    /// (The face-contour midpoint was tried first and saturated: the contour is the visible
    /// silhouette and shifts with the nose when turning.)
    private func geometricYaw(_ lm: VNFaceLandmarks2D) -> Double? {
        guard let le = lm.leftEye?.normalizedPoints, let re = lm.rightEye?.normalizedPoints,
              !le.isEmpty, !re.isEmpty,
              let nose = lm.nose?.normalizedPoints, !nose.isEmpty else { return nil }
        let lx = le.map { Double($0.x) }.reduce(0, +) / Double(le.count)
        let rx = re.map { Double($0.x) }.reduce(0, +) / Double(re.count)
        let iod = abs(lx - rx)
        guard iod > 0.05 else { return nil }
        let noseX = nose.map { Double($0.x) }.reduce(0, +) / Double(nose.count)  // mean of the nose region: far steadier than any single point
        let nxImage = (noseX - (lx + rx) / 2) / iod
        let nxUser = -nxImage      // image-left is the user's right
        return asin(max(-1, min(1, nxUser / Self.noseGain)))
    }

    /// Roll from the line between the eye centers (image is not mirrored, so a user-clockwise
    /// tilt shows as the user's-right eye (image left) dropping... handled by the sign below).
    private func eyeLineRoll(_ lm: VNFaceLandmarks2D) -> Double? {
        guard let le = lm.leftEye?.normalizedPoints, let re = lm.rightEye?.normalizedPoints,
              !le.isEmpty, !re.isEmpty else { return nil }
        func c(_ p: [CGPoint]) -> (Double, Double) {
            (p.map { Double($0.x) }.reduce(0, +) / Double(p.count), p.map { Double($0.y) }.reduce(0, +) / Double(p.count))
        }
        let a = c(le), b = c(re)
        // image-left eye is the user's right eye; clockwise from user's view = user's right eye lower.
        let (l, r) = a.0 < b.0 ? (a, b) : (b, a)      // l = image-left (user's right eye)
        let dx = r.0 - l.0, dy = r.1 - l.1            // Vision y up
        return atan2(dy, dx)                          // l lower than r (dy > 0) => positive => clockwise for user
    }

    /// Pitch proxy from nose-tip height between eye line and chin: r = (eyes - nose) / (eyes - chin).
    /// Tilting the head up pulls the nose tip toward eye level (r falls), so pitch = (r0 - r) * gain.
    /// Offset/scale are approximate (r0 = typical neutral ratio); the gaze mapper's regression absorbs both.
    private func geometricPitch(_ lm: VNFaceLandmarks2D) -> Double? {
        guard let contour = lm.faceContour?.normalizedPoints, !contour.isEmpty,
              let nose = lm.nose?.normalizedPoints, !nose.isEmpty,
              let le = lm.leftEye?.normalizedPoints, let re = lm.rightEye?.normalizedPoints,
              !le.isEmpty, !re.isEmpty else { return nil }
        let eyeY = (le + re).map { Double($0.y) }.reduce(0, +) / Double(le.count + re.count)
        let chinY = Double(contour.map(\.y).min()!)
        let noseY = Double(nose.map(\.y).min()!)
        let span = eyeY - chinY
        guard span > 0.05 else { return nil }
        let r = (eyeY - noseY) / span
        return (Self.pitchNeutralRatio - r) * Self.pitchGain
    }

    /// Mean pupil position inside each eye's landmark bbox, -1...1, user's view (dx + = right, dy + = up).
    private func eyeOffset(_ lm: VNFaceLandmarks2D) -> CGVector {
        var dxs = [Double](), dys = [Double]()
        for (eye, pupil) in [(lm.leftEye, lm.leftPupil), (lm.rightEye, lm.rightPupil)] {
            guard let e = eye?.normalizedPoints, e.count > 2, let p = pupil?.normalizedPoints, !p.isEmpty else { continue }
            let minX = e.map { Double($0.x) }.min()!, maxX = e.map { Double($0.x) }.max()!
            let minY = e.map { Double($0.y) }.min()!, maxY = e.map { Double($0.y) }.max()!
            let halfW = (maxX - minX) / 2
            let halfH = max((maxY - minY) / 2, halfW * 0.25)   // floor: eye boxes are thin and noisy
            guard halfW > 1e-4 else { continue }
            let px = p.map { Double($0.x) }.reduce(0, +) / Double(p.count)
            let py = p.map { Double($0.y) }.reduce(0, +) / Double(p.count)
            dxs.append(-max(-1, min(1, (px - (minX + maxX) / 2) / halfW)))   // flip: image-right = user's left
            dys.append(max(-1, min(1, (py - (minY + maxY) / 2) / halfH)))
        }
        guard !dxs.isEmpty else { return .zero }
        return CGVector(dx: dxs.reduce(0, +) / Double(dxs.count), dy: dys.reduce(0, +) / Double(dys.count))
    }

    // MARK: Debug

    /// `--pose-debug`: print one line per pose until Ctrl-C.
    public static func runDebugCLI() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        // `--log <path>` also appends every line to a file (stdout is lost when launched via `open`).
        let args = CommandLine.arguments
        var logHandle: FileHandle?
        if let i = args.firstIndex(of: "--log"), i + 1 < args.count {
            FileManager.default.createFile(atPath: args[i + 1], contents: nil)
            logHandle = FileHandle(forWritingAtPath: args[i + 1])
        }
        func emit(_ line: String) {
            print(line)
            logHandle?.write(Data((line + "\n").utf8))
        }
        let tracker = CameraPoseTracker()
        var lastPrint = 0.0, n = 0
        tracker.onPose = { pose in
            n += 1
            let now = ProcessInfo.processInfo.systemUptime
            let hz = now > lastPrint ? 1 / (now - lastPrint) : 0
            lastPrint = now
            guard let p = pose else { emit("no face"); return }
            func d(_ r: Double) -> String { String(format: "%+6.1f", r * 180 / .pi) }
            emit("yaw \(d(p.yaw))° pitch \(d(p.pitch))° roll \(d(p.roll))° " +
                  String(format: "center (%.3f, %.3f) size %.3f eye (%+.2f, %+.2f) conf %.2f  %.1f Hz | rawV %+.1f rawG %@",
                         p.faceCenter.x, p.faceCenter.y, p.faceSize, p.eyeOffset.dx, p.eyeOffset.dy, p.confidence, hz,
                         debugRawStorage.0 * 180 / .pi, debugRawStorage.1.map { String(format: "%+.1f", $0 * 180 / .pi) } ?? "nil"))
        }
        signal(SIGINT) { _ in exit(0) }
        do {
            let cams = availableCameras().map(\.name).joined(separator: ", ")
            emit("cameras: \(cams)")
            emit("picked: \(pickDevice(cameraID: nil)?.localizedName ?? "none")")
            try tracker.start(cameraID: nil)
        } catch {
            emit("pose-debug: \(error.localizedDescription)")
            exit(1)
        }
        RunLoop.main.run()
        exit(0)
    }
}

/// Sliding median over the last `size` samples; rejects single-frame landmark spikes.
struct MedianWindow {
    let size: Int
    private var buf: [Double] = []
    init(size: Int) { self.size = size }
    mutating func push(_ x: Double) -> Double {
        buf.append(x)
        if buf.count > size { buf.removeFirst() }
        return buf.sorted()[buf.count / 2]
    }
}
