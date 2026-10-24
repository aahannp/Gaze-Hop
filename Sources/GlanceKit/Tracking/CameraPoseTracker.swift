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

    static let maxFPS = 15.0

    private let lock = NSLock()
    private var running = false
    private var generation = 0          // bumps on every start/stop to drop stale async work

    private let sessionQueue = DispatchQueue(label: "glance.camera.session")
    private let videoQueue = DispatchQueue(label: "glance.camera.video")
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?

    // Touched only on videoQueue.
    private var lastFrameTime = 0.0
    private var hadFace = false
    private let estimator: FramePoseEstimator

    public override convenience init() { self.init(estimator: VisionPoseEstimator()) }
    init(estimator: FramePoseEstimator) { self.estimator = estimator; super.init() }

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
            lastFrameTime = 0; hadFace = false; estimator.reset()
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
        // Frames arrive ~66 ms apart with jitter; a tight gate drops every other early frame.
        if now - lastFrameTime < 0.7 / Self.maxFPS { return }
        lastFrameTime = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock(); let gen = generation; lock.unlock()

        let pose = estimator.estimate(buffer, t: now)
        if pose == nil && hadFace { estimator.reset() }
        hadFace = pose != nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let ok = self.generation == gen && self.running; self.lock.unlock()
            if ok { self.onPose?(pose) }
        }
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
                         VisionPoseEstimator.debugRawStorage.0 * 180 / .pi, VisionPoseEstimator.debugRawStorage.1.map { String(format: "%+.1f", $0 * 180 / .pi) } ?? "nil"))
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
