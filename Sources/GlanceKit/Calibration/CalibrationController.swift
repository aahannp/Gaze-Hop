// OWNER: Calibration worker.
// Full-screen dot calibration: one overlay window per display, a dot visits a grid plus
// points along edges shared with neighbouring displays.
import AppKit
import QuartzCore

// MARK: - Overlay views

private final class OverlayWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private final class OverlayView: NSView {
    let dot = CAShapeLayer()
    let ring = CAShapeLayer()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }   // local coords == CG offsets from the display origin

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.82).cgColor

        let r: CGFloat = 13
        let circle = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        dot.path = circle
        dot.fillColor = NSColor.systemOrange.cgColor
        dot.strokeColor = NSColor.white.cgColor
        dot.lineWidth = 2
        dot.opacity = 0
        let rr: CGFloat = 30
        ring.path = CGPath(ellipseIn: CGRect(x: -rr, y: -rr, width: 2 * rr, height: 2 * rr), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.systemOrange.withAlphaComponent(0.6).cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)

        for (f, size, weight, alpha) in [(title, 26.0, NSFont.Weight.semibold, 1.0), (subtitle, 15.0, .regular, 0.65)] {
            f.font = .systemFont(ofSize: size, weight: weight)
            f.textColor = NSColor.white.withAlphaComponent(alpha)
            f.alignment = .center
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }
        ring.add(pulse(), forKey: "pulse")
    }
    required init?(coder: NSCoder) { fatalError() }

    private func pulse() -> CAAnimationGroup {
        let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 0.55; s.toValue = 1.0
        let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = 1.0; o.toValue = 0.0
        let g = CAAnimationGroup(); g.animations = [s, o]; g.duration = 1.1; g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return g
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = CGRect(x: 40, y: bounds.height * 0.5 + 60, width: w - 80, height: 34)
        subtitle.frame = CGRect(x: 40, y: title.frame.maxY + 6, width: w - 80, height: 22)
    }

    func showDot(at p: CGPoint, animated: Bool, fromHidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.55)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        dot.position = p; ring.position = p
        CATransaction.commit()
        if fromHidden {
            let pop = CABasicAnimation(keyPath: "transform.scale"); pop.fromValue = 0.1; pop.toValue = 1
            pop.duration = 0.35; pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dot.add(pop, forKey: "pop")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.opacity = 1; ring.opacity = 1
        CATransaction.commit()
    }

    func hideDot() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.opacity = 0; ring.opacity = 0
        CATransaction.commit()
    }
}

// MARK: - Controller

public final class CalibrationController: Calibrating {
    struct Plan { var display: Displays.Info; var points: [CGPoint] }   // CG global points

    /// Timings (seconds). Defaults match the spec; tests / demos may shorten them.
    var settleTime: TimeInterval = 0.6
    var collectTime: TimeInterval = 0.8
    var firstPointExtraDelay: TimeInterval = 1.2
    var minPoses = 3
    var minPoseConfidence = 0.5

    private var windows: [DisplayID: OverlayWindow] = [:]
    private var plans: [Plan] = []
    private var planIndex = 0, pointIndex = 0
    private var hub: PoseHub?
    private var mapper: GazeMapper?
    private var completion: ((Bool) -> Void)?
    private var observer: UUID?
    private var collected: [HeadPose] = []
    private var keyMonitor: Any?
    private var generation = 0          // invalidates scheduled steps after cancel/finish
    private(set) var isRunning = false
    /// Target of the dot currently shown (CG global). Used by the demo to fake a gaze.
    private(set) var currentTarget: CGPoint?

    public init() {}

    // MARK: Planning (pure, testable)

    static func makePlans(displays: [Displays.Info]) -> [Plan] {
        let ordered = displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        return ordered.map { d in
            let f = d.frame
            func pt(_ fx: Double, _ fy: Double) -> CGPoint {
                CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy)
            }
            let g = [0.08, 0.5, 0.92]
            // Boustrophedon order so the dot never jumps across the whole screen.
            var points: [CGPoint] = []
            for (row, fy) in g.enumerated() {
                let xs = row % 2 == 0 ? g : g.reversed()
                for fx in xs { points.append(pt(fx, fy)) }
            }
            // Extra points hugging every edge shared with a neighbour.
            let inset = 0.025
            for o in ordered where o.id != d.id {
                let e = o.frame
                let ox = (max(f.minX, e.minX), min(f.maxX, e.maxX))
                let oy = (max(f.minY, e.minY), min(f.maxY, e.maxY))
                let touchesX = oy.1 - oy.0 > 1, touchesY = ox.1 - ox.0 > 1
                if touchesX, e.minX >= f.maxX - 1 || e.maxX <= f.minX + 1 {
                    let fxEdge = e.minX >= f.maxX - 1 ? 1 - inset : inset
                    for t in [0.2, 0.5, 0.8] {
                        let y = oy.0 + (oy.1 - oy.0) * t
                        points.append(CGPoint(x: f.minX + f.width * fxEdge, y: y))
                    }
                } else if touchesY, e.minY >= f.maxY - 1 || e.maxY <= f.minY + 1 {
                    let fyEdge = e.minY >= f.maxY - 1 ? 1 - inset : inset
                    for t in [0.2, 0.5, 0.8] {
                        let x = ox.0 + (ox.1 - ox.0) * t
                        points.append(CGPoint(x: x, y: f.minY + f.height * fyEdge))
                    }
                }
            }
            return Plan(display: d, points: points)
        }
    }

    static func average(_ poses: [HeadPose]) -> HeadPose? {
        guard !poses.isEmpty else { return nil }
        let n = Double(poses.count)
        func m(_ k: (HeadPose) -> Double) -> Double { poses.reduce(0) { $0 + k($1) } / n }
        return HeadPose(timestamp: poses.last!.timestamp, yaw: m { $0.yaw }, pitch: m { $0.pitch }, roll: m { $0.roll },
                        faceCenter: CGPoint(x: m { Double($0.faceCenter.x) }, y: m { Double($0.faceCenter.y) }),
                        faceSize: m { $0.faceSize },
                        eyeOffset: CGVector(dx: m { Double($0.eyeOffset.dx) }, dy: m { Double($0.eyeOffset.dy) }),
                        confidence: m { $0.confidence })
    }

    // MARK: Calibrating

    public func run(hub: PoseHub, mapper: GazeMapper, completion: @escaping (Bool) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.run(hub: hub, mapper: mapper, completion: completion) }
            return
        }
        guard !isRunning else { completion(false); return }
        let displays = Displays.all()
        let plans = Self.makePlans(displays: displays)
        guard !plans.isEmpty else { completion(false); return }

        self.hub = hub; self.mapper = mapper; self.completion = completion
        self.plans = plans; planIndex = 0; pointIndex = 0
        isRunning = true
        generation += 1
        mapper.reset()   // a fresh calibration replaces the old one (restored via load() on cancel)

        buildWindows()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancel(); return nil }
            return e
        }
        observer = hub.observe { [weak self] pose in
            guard let self, let p = pose, p.confidence >= self.minPoseConfidence else { return }
            if self.isCollecting { self.collected.append(p) }
        }
        NSApp.activate(ignoringOtherApps: true)
        beginPoint(first: true)
    }

    public func cancel() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.cancel() }; return }
        guard isRunning else { return }
        try? mapper?.load()   // put the previous calibration back (no-op if none saved)
        finish(success: false)
    }

    // MARK: Windows

    private func buildWindows() {
        for screen in NSScreen.screens {
            guard let id = Displays.displayID(of: screen) else { continue }
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.onEscape = { [weak self] in self?.cancel() }
            w.contentView = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            w.orderFrontRegardless()
            windows[id] = w
        }
        // Make the first display's overlay key so Esc is delivered.
        windows[plans.first?.display.id ?? 0]?.makeKey()
    }

    private func view(_ id: DisplayID) -> OverlayView? { windows[id]?.contentView as? OverlayView }

    private func setText(_ title: String, _ subtitle: String, active: DisplayID?) {
        for (id, w) in windows {
            guard let v = w.contentView as? OverlayView else { continue }
            if id == active || active == nil {
                v.title.stringValue = title
                v.subtitle.stringValue = subtitle
            } else {
                v.title.stringValue = "Look at the dot on the other screen"
                v.subtitle.stringValue = subtitle
            }
        }
    }

    // MARK: Sequence

    private var isCollecting = false
    private var totalPoints: Int { plans.reduce(0) { $0 + $1.points.count } }
    private var donePoints: Int { plans[..<planIndex].reduce(0) { $0 + $1.points.count } + pointIndex }

    private func progressText(retry: Bool = false) -> String {
        let screens = plans.count > 1 ? "Screen \(planIndex + 1) of \(plans.count)  ·  " : ""
        return "\(screens)Point \(donePoints + 1) of \(totalPoints)  ·  Esc to cancel"
    }

    private func after(_ t: TimeInterval, _ block: @escaping () -> Void) {
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
            guard let self, self.isRunning, self.generation == g else { return }
            block()
        }
    }

    private func beginPoint(first: Bool = false, retry: Bool = false) {
        let plan = plans[planIndex]
        let target = plan.points[pointIndex]
        let newDisplay = pointIndex == 0
        currentTarget = target
        isCollecting = false
        collected = []

        setText("Follow the dot with your eyes and head", progressText(), active: plan.display.id)
        for (id, w) in windows {
            guard let v = w.contentView as? OverlayView else { continue }
            if id == plan.display.id {
                let f = plan.display.frame
                let local = CGPoint(x: target.x - f.minX, y: target.y - f.minY)
                v.showDot(at: local, animated: !newDisplay && !retry, fromHidden: newDisplay || first)
            } else {
                v.hideDot()
            }
        }
        if newDisplay { windows[plan.display.id]?.makeKey() }

        let settle = settleTime + (newDisplay ? firstPointExtraDelay : 0) + (retry ? 0.3 : 0)
        after(settle) { [weak self] in self?.startCollecting() }
    }

    private func startCollecting() {
        collected = []
        isCollecting = true
        after(collectTime) { [weak self] in self?.endCollecting() }
    }

    private func endCollecting() {
        isCollecting = false
        guard let mapper else { return }
        guard collected.count >= minPoses, let avg = Self.average(collected) else {
            let id = plans[planIndex].display.id
            setText("Can't see your face", "Move into view of the camera — retrying…", active: id)
            after(1.2) { [weak self] in self?.beginPoint(retry: true) }
            return
        }
        mapper.addSample(avg, target: plans[planIndex].points[pointIndex], weight: 1.0)
        pointIndex += 1
        if pointIndex >= plans[planIndex].points.count { planIndex += 1; pointIndex = 0 }
        if planIndex >= plans.count {
            let ok = mapper.fit()
            if ok { do { try mapper.save() } catch { NSLog("Glance: calibration save failed: \(error)"); finish(success: false); return } }
            else { try? mapper.load() }
            finish(success: ok)
        } else {
            beginPoint()
        }
    }

    private func finish(success: Bool) {
        isRunning = false
        isCollecting = false
        generation += 1
        currentTarget = nil
        if let o = observer { hub?.remove(o) }
        observer = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        for w in windows.values { w.orderOut(nil); w.close() }
        windows = [:]
        let c = completion
        completion = nil; hub = nil; mapper = nil
        c?(success)
    }
}

// MARK: - Demo (no camera)

extension CalibrationController {
    /// Drives the real overlay with a synthetic PoseHub that "looks" at whatever dot is shown.
    /// Blocks in `NSApp.run()`; quits when the run finishes. Uses a temp file, never the real calibration.
    public static func runDemo(autoCancelAfter: TimeInterval? = nil) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let hub = PoseHub()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glance-demo-calibration.json")
        let mapper = RegressionGazeMapper(url: url)
        let controller = CalibrationController()
        let displays = Displays.all()
        let bounds = displays.map { $0.frame }.reduce(CGRect.null) { $0.union($1) }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        var rng = SystemRandomNumberGenerator()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { _ in
            guard let t = controller.currentTarget else { hub.publish(nil); return }
            func n() -> Double { Double.random(in: -0.004...0.004, using: &rng) }
            // Fake linear head model: angles proportional to target offset from desktop centre.
            let yaw = Double(t.x - center.x) / 4500 + n(), pitch = -Double(t.y - center.y) / 3000 + n()
            hub.publish(HeadPose(timestamp: ProcessInfo.processInfo.systemUptime, yaw: yaw, pitch: pitch, roll: 0,
                                 faceCenter: CGPoint(x: 0.5 + yaw * 0.1, y: 0.5 - pitch * 0.1), faceSize: 0.3,
                                 eyeOffset: CGVector(dx: yaw * 0.3, dy: pitch * 0.3), confidence: 0.9))
        }
        controller.run(hub: hub, mapper: mapper) { ok in
            timer.invalidate()
            print("Calibration demo finished: success=\(ok) samples=\(mapper.sampleCount) calibrated=\(mapper.isCalibrated)")
            try? FileManager.default.removeItem(at: url)
            NSApp.terminate(nil)
        }
        if let s = autoCancelAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { controller.cancel() }
        }
        app.run()
    }
}
