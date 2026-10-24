// OWNER: Calibration worker.
// Visual layer of the guided calibration: full-screen vibrancy backdrop, glowing dot target, status chrome.
// Pure presentation, no sampling logic. Everything that moves runs on the render server (Core Animation),
// and every setter below is a no-op when nothing changed, so per-pose updates cost nothing on the main thread.
import AppKit
import QuartzCore

// MARK: - Copy

enum CalibrationCopy {
    static let introTitle = "Sit how you normally work"
    static func introSubtitle(screens n: Int) -> String {
        n > 1 ? "We'll calibrate all \(n) screens, one at a time." : "We'll calibrate your screen."
    }
    static let introHint = "Space to start  ·  Esc to cancel"
    static let hint = "Esc to cancel"
    static func range(_ label: String) -> String { "Look at the \(label.lowercased()) of this screen" }
    static func elsewhere(screen n: Int) -> String { "Look at Screen \(n)" }
    static let dot = "Follow the dot"
    static let eyes = "Follow the dot with your eyes only"
    static let headStill = "HEAD STILL"
    static let noFace = "Can't see your face"
    static let noFaceSub = "Move into view of the camera. Retrying…"
    static let holdStill = "Hold your head still"
    static let holdStillSub = "Move only your eyes. Retrying…"
    static let verify = "Look at this screen"
    static func verifyHeader(_ i: Int, of n: Int) -> String { n > 1 ? "Verifying  ·  \(i) of \(n)" : "Verifying" }
    static let allSetTitle = "You're all set"
    static func allSetSubtitle(screens n: Int) -> String {
        n > 1 ? "Glance will now follow your gaze across \(n) screens." : "Glance will now follow your gaze."
    }
    static let allSetHint = "Press Return to finish"
    static func screenOK(_ name: String) -> String { "\(name) looks good" }
    static func screenFailed(_ name: String) -> String { "Couldn't detect \(name) reliably" }
    static let failedSubtitle = "Sit a little closer, face the screen, and try again."
    static let failedHint = "R to redo  ·  Return to finish anyway"
}

// MARK: - Palette

enum CalibrationPalette {
    static let head = NSColor(srgbRed: 0.33, green: 0.64, blue: 1.0, alpha: 1)
    static let eyes = NSColor(srgbRed: 0.74, green: 0.52, blue: 1.0, alpha: 1)
    static let good = NSColor(srgbRed: 0.30, green: 0.85, blue: 0.55, alpha: 1)
    static let bad = NSColor(srgbRed: 1.0, green: 0.40, blue: 0.42, alpha: 1)
    static let warn = NSColor(srgbRed: 1.0, green: 0.68, blue: 0.30, alpha: 1)
}

// MARK: - Window & button

final class CalibrationOverlayWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    private let isPrimary: Bool

    init(title: String, primary: Bool, handler: @escaping () -> Void) {
        isPrimary = primary
        super.init(frame: .zero)
        self.handler = handler
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        layer?.cornerRadius = 12
        layer?.backgroundColor = (primary ? CalibrationPalette.head : NSColor.white.withAlphaComponent(0.14)).cgColor
        target = self
        action = #selector(fire)
        isHidden = true
        self.title = title
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var title: String { didSet { refreshTitle() } }
    override var isHighlighted: Bool { didSet { layer?.opacity = isHighlighted ? 0.7 : 1 } }

    private func refreshTitle() {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: p,
        ])
    }
    @objc private func fire() { handler?() }
}

// MARK: - Backdrop

/// Dark translucent vibrancy. `snapshot` swaps the live blur (which does not render off-screen) for a faux wallpaper.
private final class Backdrop: NSView {
    private let tint = NSView()
    private let wallpaper = CAGradientLayer()

    init(frame: NSRect, snapshot: Bool) {
        super.init(frame: frame)
        wantsLayer = true
        if snapshot {
            wallpaper.colors = [NSColor(srgbRed: 0.22, green: 0.20, blue: 0.55, alpha: 1).cgColor,
                                NSColor(srgbRed: 0.10, green: 0.50, blue: 0.62, alpha: 1).cgColor,
                                NSColor(srgbRed: 0.85, green: 0.45, blue: 0.40, alpha: 1).cgColor]
            wallpaper.startPoint = CGPoint(x: 0, y: 0); wallpaper.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(wallpaper)
        } else {
            let fx = NSVisualEffectView(frame: bounds)
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.appearance = NSAppearance(named: .darkAqua)
            fx.autoresizingMask = [.width, .height]
            addSubview(fx)
        }
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: snapshot ? 0.62 : 0.34).cgColor
        tint.autoresizingMask = [.width, .height]
        tint.frame = bounds
        addSubview(tint)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wallpaper.frame = bounds
        CATransaction.commit()
    }
}

/// Hosts all non-text layers (bar, highlight, dot, badge) so their z-order is deterministic.
private final class Stage: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Overlay view

final class CalibrationOverlayView: NSView {
    enum Layout { case range, message, compact }

    struct Content {
        var title = ""
        var subtitle = ""
        var big = ""
        var hint = CalibrationCopy.hint
        var titleColor = NSColor.white
        var pill = false
        var layout = Layout.compact
    }

    let header = NSTextField(labelWithString: "")
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let big = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")
    let face = NSTextField(labelWithString: "")
    let primary: ActionButton
    let secondary: ActionButton
    override var isFlipped: Bool { true }   // local coords == CG offsets from the display origin

    private let backdrop: Backdrop
    private let stage: Stage
    private let chip = NSView()
    private let chipDot = CALayer()
    private let pill = NSView()
    private let pillLabel = NSTextField(labelWithString: "")

    private let barTrack = CALayer()
    private let barFill = CALayer()
    private let highlightLayer = CAShapeLayer()
    private let target = CALayer()
    private let glow = CAGradientLayer()
    private let ring = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let burst = CAShapeLayer()
    private let core = CAShapeLayer()
    private let badge = CALayer()
    private let badgeCircle = CAShapeLayer()
    private let badgeMark = CAShapeLayer()

    private var layoutMode = Layout.compact
    private var showsPill = false
    private var badgeVisible = false
    private var progress: CGFloat?
    private var lastFace: Bool?
    private var lastHighlight: NSColor?
    private var eyesAccent = false

    private static let ringRadius: CGFloat = 36
    private static let glide = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    init(frame: NSRect, primary: ActionButton, secondary: ActionButton, snapshot: Bool = false) {
        self.primary = primary; self.secondary = secondary
        backdrop = Backdrop(frame: CGRect(origin: .zero, size: frame.size), snapshot: snapshot)
        stage = Stage(frame: CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        addSubview(backdrop)
        addSubview(stage)
        buildStageLayers()
        buildChrome()
        addSubview(primary); addSubview(secondary)
        setAccent(eyes: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func buildStageLayers() {
        guard let root = stage.layer else { return }
        barTrack.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        barFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        barTrack.opacity = 0; barFill.opacity = 0

        highlightLayer.fillColor = nil
        highlightLayer.lineWidth = 8
        highlightLayer.shadowOpacity = 0.9
        highlightLayer.shadowRadius = 22
        highlightLayer.shadowOffset = .zero
        highlightLayer.opacity = 0

        let r = Self.ringRadius
        let circle = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        glow.bounds = CGRect(x: 0, y: 0, width: 170, height: 170)
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
        ring.path = circle; ring.fillColor = nil
        ring.strokeColor = NSColor.white.withAlphaComponent(0.2).cgColor; ring.lineWidth = 2
        let arcPath = CGMutablePath()
        arcPath.addArc(center: .zero, radius: r, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        arc.path = arcPath; arc.fillColor = nil; arc.lineWidth = 4; arc.lineCap = .round; arc.opacity = 0
        burst.path = circle; burst.fillColor = nil; burst.lineWidth = 3; burst.opacity = 0
        core.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
        core.fillColor = NSColor.white.cgColor
        core.shadowOpacity = 1; core.shadowRadius = 8; core.shadowOffset = .zero
        for l in [glow, ring, arc, burst, core] as [CALayer] { target.addSublayer(l) }
        target.opacity = 0

        badge.bounds = CGRect(x: 0, y: 0, width: 88, height: 88)
        badgeCircle.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: 84, height: 84), transform: nil)
        badgeCircle.lineWidth = 3
        badgeMark.fillColor = nil; badgeMark.lineWidth = 7; badgeMark.lineCap = .round; badgeMark.lineJoin = .round
        badge.addSublayer(badgeCircle); badge.addSublayer(badgeMark)
        badgeCircle.frame = badge.bounds; badgeMark.frame = badge.bounds
        badge.opacity = 0

        for l in [barTrack, barFill, highlightLayer, target, badge] { root.addSublayer(l) }
    }

    private func buildChrome() {
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 12
        chip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        chipDot.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        chipDot.cornerRadius = 4
        chipDot.position = CGPoint(x: 15, y: 12)
        chip.layer?.addSublayer(chipDot)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 14
        pill.layer?.borderWidth = 1
        pill.isHidden = true
        pillLabel.attributedStringValue = NSAttributedString(string: CalibrationCopy.headStill, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: CalibrationPalette.eyes,
            .kern: 1.6,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
        ])
        pillLabel.alignment = .center
        pillLabel.isHidden = true
        for v in [chip, pill] { addSubview(v) }
        let specs: [(NSTextField, NSFont, CGFloat)] = [
            (header, .monospacedDigitSystemFont(ofSize: 14, weight: .medium), 0.6),
            (face, .systemFont(ofSize: 13, weight: .medium), 0.85),
            (big, .monospacedDigitSystemFont(ofSize: 88, weight: .thin), 0.95),
            (title, .systemFont(ofSize: 26, weight: .medium), 1),
            (subtitle, .systemFont(ofSize: 17, weight: .regular), 0.6),
            (hint, .systemFont(ofSize: 13, weight: .regular), 0.4),
        ]
        for (f, font, alpha) in specs {
            f.font = font
            f.textColor = NSColor.white.withAlphaComponent(alpha)
            f.alignment = .center
            f.lineBreakMode = .byTruncatingTail
            f.wantsLayer = true
            addSubview(f)
        }
        header.alignment = .left
        face.alignment = .left
        addSubview(pillLabel)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        backdrop.frame = bounds
        stage.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        barTrack.frame = CGRect(x: 0, y: 0, width: w, height: 3)
        barFill.bounds = CGRect(x: 0, y: 0, width: w * (progress ?? 0), height: 3)
        barFill.position = CGPoint(x: 0, y: 1.5)
        highlightLayer.frame = bounds
        highlightLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 7, dy: 7), cornerWidth: 22, cornerHeight: 22, transform: nil)
        badge.position = CGPoint(x: w / 2, y: layoutMode == .compact ? h * 0.5 : h * 0.5 - 118)
        CATransaction.commit()

        header.frame = CGRect(x: 40, y: 12, width: w / 2 - 40, height: 20)
        chip.frame = CGRect(x: w - 40 - 150, y: 9, width: 150, height: 24)
        face.frame = CGRect(x: chip.frame.minX + 28, y: 12, width: 118, height: 17)
        hint.frame = CGRect(x: 40, y: h - 52, width: w - 80, height: 18)

        let titleH: CGFloat = 44
        let ty: CGFloat
        switch layoutMode {
        case .range: ty = h * 0.5 + 76
        case .message: ty = badgeVisible ? h * 0.5 - 52 : h * 0.5 - 70
        case .compact: ty = h * 0.27
        }
        big.frame = CGRect(x: 40, y: h * 0.5 - 200, width: w - 80, height: 120)
        title.frame = CGRect(x: 40, y: ty, width: w - 80, height: titleH)
        subtitle.frame = CGRect(x: 40, y: title.frame.maxY + 2, width: w - 80, height: 24)
        pill.frame = CGRect(x: w / 2 - 78, y: ty - 44, width: 156, height: 28)
        pillLabel.frame = CGRect(x: pill.frame.minX, y: pill.frame.minY + 5, width: 156, height: 17)
        let bw: CGFloat = 160, bh: CGFloat = 44, by = subtitle.frame.maxY + 32
        let both = !primary.isHidden && !secondary.isHidden
        primary.frame = CGRect(x: w / 2 - (both ? bw + 8 : bw / 2), y: by, width: bw, height: bh)
        secondary.frame = CGRect(x: w / 2 + (both ? 8 : -bw / 2), y: by, width: bw, height: bh)
    }

    // MARK: Text

    private func set(_ f: NSTextField, _ s: String, color: NSColor? = nil, animated: Bool) {
        let colorChanged = color.map { f.textColor != $0 } ?? false
        guard f.stringValue != s || colorChanged else { return }
        if animated, f.window != nil, let l = f.layer {
            let t = CATransition(); t.type = .fade; t.duration = 0.18
            l.add(t, forKey: "fade")
        }
        f.stringValue = s
        if let color { f.textColor = color }
    }

    func apply(_ c: Content, animated: Bool = true) {
        if c.layout != layoutMode || c.pill != showsPill {
            layoutMode = c.layout; showsPill = c.pill
            let (tSize, tWeight): (CGFloat, NSFont.Weight) = {
                switch c.layout {
                case .range: return (30, .semibold)
                case .message: return (34, .semibold)
                case .compact: return (26, .medium)
                }
            }()
            title.font = .systemFont(ofSize: tSize, weight: tWeight)
            subtitle.font = .systemFont(ofSize: c.layout == .compact ? 16 : 18, weight: .regular)
            pill.isHidden = !c.pill; pillLabel.isHidden = !c.pill
            needsLayout = true
        }
        set(title, c.title, color: c.titleColor, animated: animated)
        set(subtitle, c.subtitle, animated: animated)
        set(big, c.big, animated: false)
        set(hint, c.hint, animated: animated)
    }

    func setHeader(_ s: String) { set(header, s, animated: false) }
    func setBig(_ s: String) { set(big, s, animated: true) }

    func setButtons(primary p: String?, secondary s: String?) {
        let wasBoth = !primary.isHidden && !secondary.isHidden
        let hidden = (primary.isHidden, secondary.isHidden)
        primary.isHidden = p == nil; secondary.isHidden = s == nil
        if let p { primary.title = p }
        if let s { secondary.title = s }
        if hidden != (primary.isHidden, secondary.isHidden) || wasBoth != (!primary.isHidden && !secondary.isHidden) {
            needsLayout = true
        }
    }

    /// nil hides the bar; otherwise 0...1 of the whole sequence.
    func setProgress(_ f: Double?) {
        let value = f.map { CGFloat(min(max($0, 0), 1)) }
        guard value != progress else { return }
        let wasHidden = progress == nil
        progress = value
        CATransaction.begin()
        CATransaction.setDisableActions(wasHidden)
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(Self.glide)
        barTrack.opacity = value == nil ? 0 : 1
        barFill.opacity = value == nil ? 0 : 1
        barFill.bounds = CGRect(x: 0, y: 0, width: bounds.width * (value ?? 0), height: 3)
        CATransaction.commit()
    }

    func setFace(_ visible: Bool) {
        guard visible != lastFace else { return }
        lastFace = visible
        face.stringValue = visible ? "Face detected" : "No face detected"
        CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
        chipDot.backgroundColor = (visible ? CalibrationPalette.good : CalibrationPalette.bad).cgColor
        CATransaction.commit()
    }

    func highlight(_ color: NSColor?) {
        guard color != lastHighlight else { return }
        lastHighlight = color
        CATransaction.begin(); CATransaction.setAnimationDuration(0.18)
        if let color {
            highlightLayer.strokeColor = color.cgColor
            highlightLayer.shadowColor = color.cgColor
        }
        highlightLayer.opacity = color == nil ? 0 : 1
        CATransaction.commit()
    }

    // MARK: Badge

    /// true = green check, false = red cross, nil = hidden.
    func setBadge(_ ok: Bool?, animated: Bool = true) {
        let visible = ok != nil
        if visible != badgeVisible { badgeVisible = visible; needsLayout = true }
        guard let ok else {
            if badge.opacity != 0 {
                CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
                badge.opacity = 0
                CATransaction.commit()
            }
            return
        }
        let color = ok ? CalibrationPalette.good : CalibrationPalette.bad
        let p = CGMutablePath()
        if ok {
            p.move(to: CGPoint(x: 27, y: 46)); p.addLine(to: CGPoint(x: 40, y: 59)); p.addLine(to: CGPoint(x: 63, y: 31))
        } else {
            p.move(to: CGPoint(x: 31, y: 31)); p.addLine(to: CGPoint(x: 57, y: 57))
            p.move(to: CGPoint(x: 57, y: 31)); p.addLine(to: CGPoint(x: 31, y: 57))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        badgeMark.path = p
        badgeMark.strokeColor = color.cgColor
        badgeCircle.strokeColor = color.withAlphaComponent(0.9).cgColor
        badgeCircle.fillColor = color.withAlphaComponent(0.16).cgColor
        badge.opacity = 1
        CATransaction.commit()
        guard animated else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.6, 1.08, 1]; pop.keyTimes = [0, 0.6, 1]; pop.duration = 0.42
        pop.timingFunction = Self.glide
        badge.add(pop, forKey: "pop")
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0; draw.toValue = 1; draw.duration = 0.38; draw.beginTime = CACurrentMediaTime() + 0.12
        draw.fillMode = .backwards; draw.timingFunction = Self.glide
        badgeMark.add(draw, forKey: "draw")
    }

    // MARK: Target dot

    private func setAccent(eyes: Bool) {
        eyesAccent = eyes
        let c = eyes ? CalibrationPalette.eyes : CalibrationPalette.head
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.colors = [c.withAlphaComponent(0.5).cgColor, c.withAlphaComponent(0.16).cgColor, c.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.4, 1]
        arc.strokeColor = c.cgColor
        burst.strokeColor = c.cgColor
        core.shadowColor = c.cgColor
        pill.layer?.backgroundColor = CalibrationPalette.eyes.withAlphaComponent(0.18).cgColor
        pill.layer?.borderColor = CalibrationPalette.eyes.withAlphaComponent(0.6).cgColor
        barFill.backgroundColor = c.cgColor
        CATransaction.commit()
    }

    /// Moves the target. `animated` glides with a long ease-out; `fromHidden` fades and pops it in instead.
    func showDot(at p: CGPoint, animated: Bool, fromHidden: Bool, eyesOnly: Bool = false) {
        if eyesOnly != eyesAccent { setAccent(eyes: eyesOnly) }
        resetArc()
        let hidden = fromHidden || target.opacity < 0.5
        let from = target.presentation()?.position ?? target.position
        CATransaction.begin(); CATransaction.setDisableActions(true)
        target.position = p
        target.opacity = 1
        CATransaction.commit()
        if hidden {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.25
            let pop = CABasicAnimation(keyPath: "transform.scale"); pop.fromValue = 0.4; pop.toValue = 1
            pop.duration = 0.5; pop.timingFunction = Self.glide
            target.add(fade, forKey: "fade"); target.add(pop, forKey: "pop")
            target.removeAnimation(forKey: "glide")
        } else if animated, from != p {
            let a = CABasicAnimation(keyPath: "position")
            a.fromValue = NSValue(point: from); a.toValue = NSValue(point: p)
            a.duration = 0.6; a.timingFunction = Self.glide
            target.add(a, forKey: "glide")
        }
        if glow.animation(forKey: "breathe") == nil {
            let b = CABasicAnimation(keyPath: "transform.scale")
            b.fromValue = 0.92; b.toValue = 1.12; b.duration = 1.6; b.autoreverses = true; b.repeatCount = .infinity
            b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(b, forKey: "breathe")
        }
    }

    func hideDot() {
        guard target.opacity != 0 else { return }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
        target.opacity = 0
        CATransaction.commit()
    }

    private func resetArc() {
        arc.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arc.opacity = 0; arc.strokeEnd = 1
        CATransaction.commit()
    }

    /// Progress ring that shrinks to nothing while the samples are being collected.
    func startArc(duration: TimeInterval) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arc.opacity = 1; arc.strokeEnd = 0
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 1; a.toValue = 0; a.duration = duration; a.timingFunction = CAMediaTimingFunction(name: .linear)
        arc.add(a, forKey: "collect")
    }

    /// Static arc for snapshots.
    func setArcProgress(_ p: CGFloat) {
        arc.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arc.opacity = 1; arc.strokeEnd = p
        CATransaction.commit()
    }

    /// Completion pop: the core swells, the arc vanishes, a ring bursts outwards.
    func pop() {
        let k = CAKeyframeAnimation(keyPath: "transform.scale")
        k.values = [1, 1.6, 1]; k.keyTimes = [0, 0.35, 1]; k.duration = 0.4; k.timingFunction = Self.glide
        core.add(k, forKey: "pop")
        let b = CAAnimationGroup()
        let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 1; s.toValue = 2.6
        let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = 0.9; o.toValue = 0
        b.animations = [s, o]; b.duration = 0.5; b.timingFunction = CAMediaTimingFunction(name: .easeOut)
        burst.add(b, forKey: "burst")
        arc.removeAllAnimations()
        CATransaction.begin(); CATransaction.setAnimationDuration(0.15)
        arc.opacity = 0
        CATransaction.commit()
    }
}
