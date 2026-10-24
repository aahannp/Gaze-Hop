// OWNER: Calibration worker.
// Guided recalibration over every connected display:
//   intro -> head-range exercise -> dot sequence -> verification (-> redo) -> finish.
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

private final class ActionButton: NSButton {
    var handler: (() -> Void)?
    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        bezelStyle = .rounded
        controlSize = .large
        font = .systemFont(ofSize: 17, weight: .semibold)
        target = self
        action = #selector(fire)
        isHidden = true
    }
    @objc private func fire() { handler?() }
}

private final class OverlayView: NSView {
    let dot = CAShapeLayer()
    let ring = CAShapeLayer()
    let header = NSTextField(labelWithString: "")
    let face = NSTextField(labelWithString: "")
    let big = NSTextField(labelWithString: "")
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let primary: ActionButton
    let secondary: ActionButton
    override var isFlipped: Bool { true }   // local coords == CG offsets from the display origin

    init(frame: NSRect, primary: ActionButton, secondary: ActionButton) {
        self.primary = primary; self.secondary = secondary
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.82).cgColor
        layer?.borderColor = NSColor.clear.cgColor

        let r: CGFloat = 13
        dot.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
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

        let specs: [(NSTextField, CGFloat, NSFont.Weight, CGFloat)] = [
            (header, 15, .medium, 0.55), (face, 15, .medium, 0.9), (big, 84, .bold, 0.95),
            (title, 28, .semibold, 1), (subtitle, 16, .regular, 0.65),
        ]
        for (f, size, weight, alpha) in specs {
            f.font = f === big ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
            f.textColor = NSColor.white.withAlphaComponent(alpha)
            f.alignment = .center
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }
        header.alignment = .left
        face.alignment = .right
        addSubview(primary); addSubview(secondary)
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
        let w = bounds.width, h = bounds.height
        header.frame = CGRect(x: 40, y: 30, width: w / 2 - 40, height: 22)
        face.frame = CGRect(x: w / 2, y: 30, width: w / 2 - 40, height: 22)
        big.frame = CGRect(x: 40, y: h * 0.5 - 190, width: w - 80, height: 110)
        title.frame = CGRect(x: 40, y: h * 0.5 + 60, width: w - 80, height: 36)
        subtitle.frame = CGRect(x: 40, y: title.frame.maxY + 6, width: w - 80, height: 22)
        let bw: CGFloat = 150, bh: CGFloat = 36, y = subtitle.frame.maxY + 28
        let both = !primary.isHidden && !secondary.isHidden
        primary.frame = CGRect(x: w / 2 - (both ? bw + 8 : bw / 2), y: y, width: bw, height: bh)
        secondary.frame = CGRect(x: w / 2 + (both ? 8 : -bw / 2), y: y, width: bw, height: bh)
    }

    func setButtons(primary p: String?, secondary s: String?) {
        primary.isHidden = p == nil; secondary.isHidden = s == nil
        if let p { primary.title = p }
        if let s { secondary.title = s }
        needsLayout = true
    }

    func setFace(_ visible: Bool) {
        face.stringValue = visible ? "●  Face detected" : "●  No face detected"
        face.textColor = (visible ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(0.95)
    }

    func highlight(_ color: NSColor?) {
        layer?.borderWidth = color == nil ? 0 : 10
        layer?.borderColor = color?.cgColor ?? NSColor.clear.cgColor
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
    struct Plan { var display: Displays.Info; var points: [CGPoint] }   // dot points, CG global

    struct Step {
        enum Kind: Equatable { case range(label: String, arrow: String), dot, eyeDot }
        var display: Displays.Info
        var target: CGPoint
        var kind: Kind
        var firstOnDisplay: Bool
    }

    private enum Phase { case idle, intro, steps, verify, summary }

    /// Timings (seconds). Defaults match the flow description; demos may shorten them.
    var settleTime: TimeInterval = 0.6
    var rangeSettleTime: TimeInterval = 1.5      // shown as a 3-2-1 countdown
    var collectTime: TimeInterval = 0.8
    var firstPointExtraDelay: TimeInterval = 1.2
    var verifySettle: TimeInterval = 1.0
    var verifyCollect: TimeInterval = 1.5
    var verifyPassFraction = 0.6
    var minPoses = 3
    var minPoseConfidence = 0.5
    /// Eyes-only phase: max spread (radians) of head yaw / pitch while a dot is collected.
    var maxHeadSpread = 0.05
    var eyePhaseExtraDelay: TimeInterval = 2.5
    /// Demo only: start and finish without waiting for the user.
    var autoAdvance = false

    private var windows: [DisplayID: OverlayWindow] = [:]
    private var plans: [Plan] = []
    private var steps: [Step] = []
    private var stepIndex = 0
    private var phase: Phase = .idle
    private var hub: PoseHub?
    private var mapper: GazeMapper?
    private var completion: ((Bool) -> Void)?
    private var observer: UUID?
    private var collected: [HeadPose] = []
    private var verifyHits: [DisplayID] = []     // estimated display per pose (0 = off-screen)
    private var verifyIndex = 0
    private var verifyResults: [DisplayID: Bool] = [:]
    private var isCollecting = false
    private var keyMonitor: Any?
    private var generation = 0          // invalidates scheduled steps after cancel/finish
    private(set) var isRunning = false
    /// Where the user is expected to look right now (CG global). The demo uses it to fake a gaze.
    private(set) var currentTarget: CGPoint?
    /// True while the eyes-only phase is on: the head should stay where it is (the demo uses it too).
    private(set) var currentEyesOnly = false

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

    /// Head-range prompts (centre + four edges) followed by the dot sequence for one display.
    static func makeSteps(for plan: Plan) -> [Step] {
        let f = plan.display.frame
        let inset = 0.03
        let range: [(String, String, Double, Double)] = [
            ("CENTER", "◎", 0.5, 0.5), ("LEFT edge", "←", inset, 0.5), ("RIGHT edge", "→", 1 - inset, 0.5),
            ("TOP edge", "↑", 0.5, inset), ("BOTTOM edge", "↓", 0.5, 1 - inset),
        ]
        var out = range.enumerated().map { i, r in
            Step(display: plan.display,
                 target: CGPoint(x: f.minX + f.width * r.2, y: f.minY + f.height * r.3),
                 kind: .range(label: r.0, arrow: r.1), firstOnDisplay: i == 0)
        }
        out += plan.points.map { Step(display: plan.display, target: $0, kind: .dot, firstOnDisplay: false) }
        return out
    }

    /// Eyes-only dots for one display: centre, four mid-edge points and the shared-edge points.
    static func makeEyeSteps(for plan: Plan) -> [Step] {
        let f = plan.display.frame
        func pt(_ fx: Double, _ fy: Double) -> CGPoint { CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy) }
        var targets = [pt(0.5, 0.5), pt(0.15, 0.5), pt(0.85, 0.5), pt(0.5, 0.15), pt(0.5, 0.85)]
        targets += plan.points.dropFirst(9)   // shared-edge points
        return targets.map { Step(display: plan.display, target: $0, kind: .eyeDot, firstOnDisplay: false) }
    }

    /// Head range + dots for every display, then the head-still eyes-only dots for every display.
    static func allSteps(for plans: [Plan]) -> [Step] {
        plans.flatMap { makeSteps(for: $0) } + plans.flatMap { makeEyeSteps(for: $0) }
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
        let plans = Self.makePlans(displays: Displays.all())
        guard !plans.isEmpty else { completion(false); return }

        self.hub = hub; self.mapper = mapper; self.completion = completion
        self.plans = plans; steps = []; stepIndex = 0
        isRunning = true
        generation += 1

        buildWindows()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e) ?? e
        }
        observer = hub.observe { [weak self] pose in self?.handlePose(pose) }
        NSApp.activate(ignoringOtherApps: true)
        showIntro()
    }

    public func cancel() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.cancel() }; return }
        guard isRunning else { return }
        try? mapper?.load()   // put the saved calibration back (no-op if none)
        finish(success: false)
    }

    // MARK: Windows & text

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
            let primary = ActionButton(title: "") { [weak self] in self?.primaryAction(on: id) }
            let secondary = ActionButton(title: "") { [weak self] in self?.secondaryAction(on: id) }
            let v = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), primary: primary, secondary: secondary)
            v.header.stringValue = displayName(id)
            v.setFace(hub?.latest.map { $0.confidence >= minPoseConfidence } ?? false)
            w.contentView = v
            w.orderFrontRegardless()
            windows[id] = w
        }
        windows[plans.first?.display.id ?? 0]?.makeKey()
    }

    private func displayName(_ id: DisplayID) -> String {
        let i = (plans.firstIndex { $0.display.id == id } ?? 0) + 1
        let f = plans.first { $0.display.id == id }?.display.frame ?? .zero
        let kind = CGDisplayIsBuiltin(id) != 0 ? " (built-in)" : ""
        return plans.count > 1 ? "Screen \(i)\(kind)  ·  \(Int(f.width))×\(Int(f.height))" : "Screen\(kind)  ·  \(Int(f.width))×\(Int(f.height))"
    }

    private func screenNumber(_ id: DisplayID) -> Int { (plans.firstIndex { $0.display.id == id } ?? 0) + 1 }

    private func view(_ id: DisplayID) -> OverlayView? { windows[id]?.contentView as? OverlayView }
    private var views: [(DisplayID, OverlayView)] { windows.compactMap { id, w in (w.contentView as? OverlayView).map { (id, $0) } } }

    /// `active` gets the main text; every other display gets `other` (default: a pointer to the active screen).
    private func setText(title: String, subtitle: String, big: String = "", active: DisplayID?, other: String? = nil,
                         titleColor: NSColor = .white) {
        for (id, v) in views {
            let isActive = active == nil || id == active
            v.title.stringValue = isActive ? title : (other ?? "Look at the dot on Screen \(screenNumber(active!))")
            v.title.textColor = isActive ? titleColor : NSColor.white.withAlphaComponent(0.7)
            v.subtitle.stringValue = subtitle
            v.big.stringValue = isActive ? big : ""
        }
    }

    private func clearButtons() { for (_, v) in views { v.setButtons(primary: nil, secondary: nil) } }
    private func clearHighlights() { for (_, v) in views { v.highlight(nil) } }
    private func hideDots() { for (_, v) in views { v.hideDot() } }

    // MARK: Input

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        switch (e.keyCode, phase) {
        case (53, _): cancel(); return nil
        case (49, .intro): startCalibration(); return nil                      // Space
        case (36, .summary), (76, .summary): finishSuccess(); return nil       // Return / Enter
        case (15, .summary): redoFailed(); return nil                          // R
        default: return e
        }
    }

    private func primaryAction(on id: DisplayID) {
        switch phase {
        case .intro: startCalibration()
        case .summary: finishSuccess()
        default: break
        }
    }

    private func secondaryAction(on id: DisplayID) {
        if phase == .summary { redoFailed() }
    }

    private func handlePose(_ pose: HeadPose?) {
        let usable = pose.flatMap { $0.confidence >= minPoseConfidence ? $0 : nil }
        for (_, v) in views { v.setFace(usable != nil) }
        guard let p = usable else {
            if phase == .verify { clearHighlights() }
            return
        }
        if phase == .verify {
            let est = mapper?.estimate(p, currentDisplay: nil, edgeBias: 0.5)?.displayID
            let target = verifyIndex < plans.count ? plans[verifyIndex].display.id : 0
            for (id, v) in views {
                v.highlight(id == est ? (est == target ? .systemGreen : .systemOrange) : nil)
            }
            if isCollecting { verifyHits.append(est ?? 0) }
        } else if isCollecting {
            collected.append(p)
        }
    }

    // MARK: Scheduling

    private func after(_ t: TimeInterval, _ block: @escaping () -> Void) {
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
            guard let self, self.isRunning, self.generation == g else { return }
            block()
        }
    }

    // MARK: 1. Intro

    private func showIntro() {
        phase = .intro
        currentTarget = nil
        hideDots(); clearHighlights()
        let n = plans.count
        let sub = n > 1 ? "We'll calibrate all \(n) screens, one at a time." : "We'll calibrate your screen."
        for (_, v) in views {
            v.title.stringValue = "Sit how you normally work"
            v.title.textColor = .white
            v.subtitle.stringValue = sub + "  Space or click Start  ·  Esc to cancel"
            v.big.stringValue = ""
            v.setButtons(primary: "Start", secondary: nil)
        }
        if autoAdvance { after(2.5) { [weak self] in self?.startCalibration() } }
    }

    private func startCalibration() {
        guard phase == .intro || phase == .idle else { return }
        mapper?.reset()   // only the current arrangement's profile
        steps = Self.allSteps(for: plans)
        stepIndex = 0
        clearButtons()
        phase = .steps
        beginStep(first: true)
    }

    // MARK: 2+3. Head range and dot sequence

    private func progressText() -> String {
        "Step \(stepIndex + 1) of \(steps.count)  ·  Esc to cancel"
    }

    private func beginStep(first: Bool = false, retry: Bool = false) {
        let step = steps[stepIndex]
        let id = step.display.id
        currentTarget = step.target
        isCollecting = false
        collected = []

        let newDisplay = step.firstOnDisplay || (stepIndex > 0 && steps[stepIndex - 1].display.id != id)
        var settle: TimeInterval
        switch step.kind {
        case .range(let label, let arrow):
            settle = rangeSettleTime
            let name = label == "CENTER" ? "Look at the CENTER of this screen" : "Look at the \(label.uppercased()) of this screen"
            setText(title: name, subtitle: progressText(), big: "\(arrow)  3", active: id, other: "Look at Screen \(screenNumber(id))")
            // 3-2-1 countdown
            for k in 1..<3 {
                after(settle * Double(k) / 3) { [weak self] in
                    guard let self else { return }
                    self.view(id)?.big.stringValue = "\(arrow)  \(3 - k)"
                }
            }
        case .dot:
            settle = settleTime
            setText(title: "Follow the dot with your eyes and head", subtitle: progressText(), active: id)
        case .eyeDot:
            settle = settleTime
            let firstEye = stepIndex == 0 || steps[stepIndex - 1].kind != .eyeDot
            setText(title: "Keep your head still, follow the dot with your eyes only", subtitle: progressText(),
                    big: "HEAD STILL", active: id)
            if firstEye { settle += eyePhaseExtraDelay }
        }
        currentEyesOnly = step.kind == .eyeDot
        if newDisplay { settle += firstPointExtraDelay }
        if retry { settle += 0.3 }

        let f = step.display.frame
        for (vid, v) in views {
            if vid == id {
                let local = CGPoint(x: step.target.x - f.minX, y: step.target.y - f.minY)
                v.showDot(at: local, animated: !newDisplay && !retry, fromHidden: newDisplay || first)
            } else {
                v.hideDot()
            }
        }
        if newDisplay { windows[id]?.makeKey() }
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
        let step = steps[stepIndex]
        guard collected.count >= minPoses, let avg = Self.average(collected) else {
            setText(title: "Can't see your face", subtitle: "Move into view of the camera — retrying…", active: step.display.id,
                    other: "Can't see your face", titleColor: .systemRed)
            after(1.2) { [weak self] in self?.beginStep(retry: true) }
            return
        }
        if step.kind == .eyeDot {
            // The head must not have moved while only the eyes were supposed to.
            func spread(_ k: (HeadPose) -> Double) -> Double {
                let v = collected.map(k); return (v.max() ?? 0) - (v.min() ?? 0)
            }
            if spread({ $0.yaw }) > maxHeadSpread || spread({ $0.pitch }) > maxHeadSpread {
                setText(title: "Hold your head still", subtitle: "Move only your eyes — retrying…", big: "HEAD STILL",
                        active: step.display.id, other: "Hold your head still", titleColor: .systemOrange)
                after(1.2) { [weak self] in self?.beginStep(retry: true) }
                return
            }
        }
        if let r = mapper as? RegressionGazeMapper {
            r.addSample(avg, target: step.target, weight: 1.0, eyesOnly: step.kind == .eyeDot)
        } else {
            mapper.addSample(avg, target: step.target, weight: 1.0)
        }
        stepIndex += 1
        if stepIndex >= steps.count { fitAndVerify() } else { beginStep() }
    }

    private func fitAndVerify() {
        guard let mapper, mapper.fit() else {
            try? mapper?.load()
            finish(success: false)
            return
        }
        do { try mapper.save() } catch { NSLog("Glance: calibration save failed: \(error)") }
        currentTarget = nil; currentEyesOnly = false
        hideDots()
        verifyResults = [:]; verifyIndex = 0
        phase = .verify
        beginVerify()
    }

    // MARK: 4. Verification

    private func beginVerify(retry: Bool = false) {
        let d = plans[verifyIndex].display
        currentTarget = CGPoint(x: d.frame.midX, y: d.frame.midY)
        isCollecting = false
        verifyHits = []
        hideDots(); clearHighlights()
        let n = plans.count
        setText(title: "Look at this screen", subtitle: "Verifying  \(verifyIndex + 1) of \(n)  ·  Esc to cancel",
                big: "", active: d.id, other: "Look at Screen \(screenNumber(d.id))")
        windows[d.id]?.makeKey()
        after(verifySettle + (retry ? 0.3 : 0)) { [weak self] in
            guard let self else { return }
            self.verifyHits = []
            self.isCollecting = true
            self.after(self.verifyCollect) { [weak self] in self?.endVerify() }
        }
    }

    private func endVerify() {
        isCollecting = false
        let d = plans[verifyIndex].display
        guard verifyHits.count >= minPoses else {
            setText(title: "Can't see your face", subtitle: "Move into view of the camera — retrying…", active: d.id,
                    other: "Can't see your face", titleColor: .systemRed)
            after(1.2) { [weak self] in self?.beginVerify(retry: true) }
            return
        }
        let hits = verifyHits.filter { $0 == d.id }.count
        let pass = Double(hits) / Double(verifyHits.count) >= verifyPassFraction
        verifyResults[d.id] = pass
        view(d.id)?.big.stringValue = pass ? "✓" : "✗"
        view(d.id)?.big.textColor = (pass ? NSColor.systemGreen : NSColor.systemRed)
        after(0.9) { [weak self] in
            guard let self else { return }
            self.view(d.id)?.big.textColor = NSColor.white.withAlphaComponent(0.95)
            self.verifyIndex += 1
            if self.verifyIndex >= self.plans.count { self.showSummary() } else { self.beginVerify() }
        }
    }

    private func showSummary() {
        phase = .summary
        currentTarget = nil
        clearHighlights(); hideDots()
        let failed = plans.map { $0.display.id }.filter { verifyResults[$0] != true }
        for (id, v) in views {
            let ok = verifyResults[id] == true
            v.big.stringValue = ok ? "✓" : "✗"
            v.big.textColor = (ok ? NSColor.systemGreen : NSColor.systemRed)
            v.title.stringValue = ok ? "\(plans.count > 1 ? "Screen \(screenNumber(id))" : "Screen") detected correctly"
                                     : "Couldn't detect \(plans.count > 1 ? "Screen \(screenNumber(id))" : "this screen") reliably"
            v.title.textColor = .white
            v.subtitle.stringValue = failed.isEmpty ? "All set.  Return or click Finish"
                                                    : "Return to finish anyway  ·  R to redo the failing screen\(failed.count > 1 ? "s" : "")"
            v.setButtons(primary: "Finish", secondary: ok || failed.isEmpty ? nil : "Redo")
        }
        if autoAdvance { after(3) { [weak self] in self?.finishSuccess() } }
    }

    private func redoFailed() {
        let failed = Set(plans.map { $0.display.id }.filter { verifyResults[$0] != true })
        guard phase == .summary, !failed.isEmpty else { return }
        steps = Self.allSteps(for: plans.filter { failed.contains($0.display.id) })
        stepIndex = 0
        for (_, v) in views { v.big.textColor = NSColor.white.withAlphaComponent(0.95) }
        clearButtons()
        phase = .steps
        beginStep(first: true)
    }

    private func finishSuccess() {
        guard phase == .summary else { return }
        do { try mapper?.save() } catch { NSLog("Glance: calibration save failed: \(error)"); finish(success: false); return }
        finish(success: true)
    }

    private func finish(success: Bool) {
        isRunning = false
        isCollecting = false
        phase = .idle
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
    /// Drives the real overlay with a synthetic PoseHub that "looks" at whatever the UI asks for.
    /// Starts and finishes on its own. Blocks in `NSApp.run()`; quits when the run finishes.
    /// Uses a temp file, never the real calibration.
    public static func runDemo(autoCancelAfter: TimeInterval? = nil) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let hub = PoseHub()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glance-demo-calibration.json")
        let mapper = RegressionGazeMapper(url: url)
        let controller = CalibrationController()
        controller.autoAdvance = true
        let displays = Displays.all()
        let bounds = displays.map { $0.frame }.reduce(CGRect.null) { $0.union($1) }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        var rng = SystemRandomNumberGenerator()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { _ in
            let t = controller.currentTarget ?? center
            func n() -> Double { Double.random(in: -0.004...0.004, using: &rng) }
            // Fake linear head model: angles proportional to target offset from desktop centre.
            // Eyes-only phase: the head stays put, only the eyes follow the target.
            let h = controller.currentEyesOnly ? center : t
            let yaw = Double(h.x - center.x) / 4500 + n(), pitch = -Double(h.y - center.y) / 3000 + n()
            let ex = Double(t.x - center.x) / 4500 * 0.3, ey = -Double(t.y - center.y) / 3000 * 0.3
            hub.publish(HeadPose(timestamp: ProcessInfo.processInfo.systemUptime, yaw: yaw, pitch: pitch, roll: 0,
                                 faceCenter: CGPoint(x: 0.5 + yaw * 0.1, y: 0.5 - pitch * 0.1), faceSize: 0.3,
                                 eyeOffset: CGVector(dx: ex + n(), dy: ey + n()), confidence: 0.9))
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
