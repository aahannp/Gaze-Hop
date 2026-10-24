// OWNER: Tracking worker.
// `--pose-check`: full-screen guided head-pose check. Walks the user through
// straight / right / left / up / down, records poses per step and reports whether the
// signs match the HeadPose contract and how steady the readings are when still.
import AppKit

private final class CheckWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

private struct CheckStep {
    enum Kind { case straight, right, left, up, down }
    let kind: Kind
    let text: String
    let arrow: String
}

private final class PoseCheck {
    static let settle = 2.5, record = 3.0
    let steps: [CheckStep] = [
        .init(kind: .straight, text: "Look straight ahead", arrow: "●"),
        .init(kind: .right, text: "Turn your head RIGHT", arrow: "→"),
        .init(kind: .straight, text: "Look straight ahead", arrow: "●"),
        .init(kind: .left, text: "Turn your head LEFT", arrow: "←"),
        .init(kind: .straight, text: "Look straight ahead", arrow: "●"),
        .init(kind: .up, text: "Tilt your chin UP", arrow: "↑"),
        .init(kind: .straight, text: "Look straight ahead", arrow: "●"),
        .init(kind: .down, text: "Tilt your chin DOWN", arrow: "↓"),
        .init(kind: .straight, text: "Look straight ahead", arrow: "●"),
    ]

    let tracker = CameraPoseTracker()
    let window: CheckWindow
    let title = PoseCheck.label(size: 56, weight: .semibold)
    let arrow = PoseCheck.label(size: 200, weight: .bold)
    let status = PoseCheck.label(size: 28, weight: .regular)
    let result = PoseCheck.label(size: 22, weight: .regular, mono: true)
    let logPath: String?

    var lastPose: HeadPose?
    var lastPoseTime = 0.0
    var step = -1
    var stepStart = 0.0
    var samples: [[HeadPose]] = []
    var misses: [Int] = []
    var timer: Timer?
    var faceSince: Double?
    var finished = false

    static func label(size: CGFloat, weight: NSFont.Weight, mono: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        l.textColor = .white; l.alignment = .center
        l.maximumNumberOfLines = 0
        return l
    }

    init(logPath: String?) {
        self.logPath = logPath
        if let p = logPath { FileManager.default.createFile(atPath: p, contents: nil) }
        let screen = NSScreen.screens.first { s in
            Displays.displayID(of: s).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        } ?? NSScreen.main ?? NSScreen.screens[0]
        window = CheckWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.backgroundColor = NSColor(white: 0.05, alpha: 1)
        window.isOpaque = true
        window.onEscape = { [weak self] in self?.quit() }

        let stack = NSStackView(views: [title, arrow, status, result])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: screen.frame)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.9),
        ])
        window.contentView = content
    }

    func log(_ s: String) {
        print(s)
        if let p = logPath, let h = FileHandle(forWritingAtPath: p) {
            h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); h.closeFile()
        }
    }

    func run() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        title.stringValue = "Glance pose check"
        arrow.stringValue = "…"
        status.stringValue = "Starting camera. Sit facing the screen. Esc quits."
        tracker.onPose = { [weak self] pose in self?.handle(pose) }
        do { try tracker.start(cameraID: nil) } catch {
            title.stringValue = "Camera error"
            status.stringValue = error.localizedDescription
            log("pose-check: \(error.localizedDescription)")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func quit() { timer?.invalidate(); tracker.stop(); exit(0) }

    func handle(_ pose: HeadPose?) {
        let now = ProcessInfo.processInfo.systemUptime
        if let p = pose {
            lastPose = p; lastPoseTime = now
            if step >= 0, step < steps.count, recording(now) { samples[step].append(p) }
        } else if step >= 0, step < steps.count, recording(now) {
            misses[step] += 1
        }
    }

    func recording(_ now: Double) -> Bool {
        let t = now - stepStart
        return t >= Self.settle && t < Self.settle + Self.record
    }

    func tick() {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let faceVisible = now - lastPoseTime < 0.6

        if step < 0 {
            arrow.stringValue = faceVisible ? "✓" : "…"
            status.stringValue = faceVisible ? "Face detected. Starting…" : "Waiting for your face. Sit facing the screen."
            if faceVisible { faceSince = faceSince ?? now } else { faceSince = nil }
            if let f = faceSince, now - f > 1.5 { advance(now) }
            return
        }
        let t = now - stepStart
        let s = steps[step]
        title.stringValue = "\(s.text)   (\(step + 1)/\(steps.count))"
        arrow.stringValue = s.arrow
        var face = faceVisible ? "● face detected" : "○ NO FACE"
        if faceVisible, let p = lastPose {
            face += String(format: "   yaw %+.0f°  pitch %+.0f°", p.yaw * 180 / .pi, p.pitch * 180 / .pi)
        }
        if t < Self.settle {
            status.stringValue = "Get ready… \(Int(ceil(Self.settle - t)))    \(face)"
        } else if t < Self.settle + Self.record {
            status.stringValue = "HOLD…  recording \(String(format: "%.1f", Self.settle + Self.record - t))s    \(face)"
        } else {
            advance(now)
        }
    }

    func advance(_ now: Double) {
        step += 1
        stepStart = now
        if step == 0 { samples = Array(repeating: [], count: steps.count); misses = Array(repeating: 0, count: steps.count) }
        if step >= steps.count { finish() }
    }

    // MARK: results

    func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    func std(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let m = mean(v); return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
    }
    func deg(_ r: Double) -> Double { r * 180 / .pi }

    func finish() {
        finished = true
        tracker.stop()
        var rows = [String]()
        var stillStd = (yaw: 0.0, pitch: 0.0), stillCount = 0
        var means = [(yaw: Double, pitch: Double, roll: Double)]()
        for i in steps.indices {
            let ys = samples[i].map { deg($0.yaw) }, ps = samples[i].map { deg($0.pitch) }, rs = samples[i].map { deg($0.roll) }
            means.append((mean(ys), mean(ps), mean(rs)))
            if steps[i].kind == .straight, ys.count > 3 {
                stillStd.yaw += std(ys); stillStd.pitch += std(ps); stillCount += 1
            }
        }
        let straightIdx = steps.indices.filter { steps[$0].kind == .straight }
        let base = (yaw: mean(straightIdx.map { means[$0].yaw }), pitch: mean(straightIdx.map { means[$0].pitch }))
        var allOK = true
        for i in steps.indices {
            let m = means[i], k = steps[i].kind
            var verdict = "", ok = true
            switch k {
            case .straight: verdict = "-"
            case .right: ok = m.yaw - base.yaw > 5; verdict = "yaw delta \(fmt(m.yaw - base.yaw)) (want > +5)"
            case .left: ok = m.yaw - base.yaw < -5; verdict = "yaw delta \(fmt(m.yaw - base.yaw)) (want < -5)"
            case .up: ok = m.pitch - base.pitch > 3; verdict = "pitch delta \(fmt(m.pitch - base.pitch)) (want > +3)"
            case .down: ok = m.pitch - base.pitch < -3; verdict = "pitch delta \(fmt(m.pitch - base.pitch)) (want < -3)"
            }
            if samples[i].count < 10 { ok = false; verdict += " too few frames" }
            if k != .straight { allOK = allOK && ok }
            rows.append(String(format: "%@ %-26@ yaw %+6.1f pitch %+6.1f roll %+6.1f  n=%d miss=%d  %@",
                               k == .straight ? " " : (ok ? "✓" : "✗"), steps[i].text as NSString,
                               m.yaw, m.pitch, m.roll, samples[i].count, misses[i], verdict as NSString))
        }
        let jy = stillCount > 0 ? stillStd.yaw / Double(stillCount) : 0
        let jp = stillCount > 0 ? stillStd.pitch / Double(stillCount) : 0
        let jitterOK = jy < 1.0 && jp < 1.0
        rows.append(String(format: "%@ jitter when still: yaw std %.2f°, pitch std %.2f° (want < 1°)", jitterOK ? "✓" : "✗", jy, jp))
        let ranges = samples.flatMap { $0 }
        if !ranges.isEmpty {
            let y = ranges.map { deg($0.yaw) }, p = ranges.map { deg($0.pitch) }
            rows.append(String(format: "ranges: yaw %.1f...%.1f  pitch %.1f...%.1f", y.min()!, y.max()!, p.min()!, p.max()!))
        }
        rows.forEach(log)
        for i in steps.indices {
            let series = samples[i].enumerated().filter { $0.offset % 3 == 0 }
                .map { String(format: "%.0f/%.0f", deg($0.element.yaw), deg($0.element.pitch)) }.joined(separator: " ")
            log("series \(i) \(steps[i].text): \(series)")
        }
        title.stringValue = allOK && jitterOK ? "All checks passed ✓" : "Some checks failed ✗"
        arrow.stringValue = ""
        status.stringValue = "Esc to close"
        result.stringValue = rows.joined(separator: "\n")
        log("DONE")
    }

    func fmt(_ v: Double) -> String { String(format: "%+.1f", v) }
}

extension CameraPoseTracker {
    /// `--pose-check [--log path]`: guided on-screen check of pose signs and stability. Never returns.
    public static func runGuidedCheck(logPath: String? = nil) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let check = PoseCheck(logPath: logPath)
        withExtendedLifetime(check) {
            check.run()
            app.run()
        }
        exit(0)
    }
}
