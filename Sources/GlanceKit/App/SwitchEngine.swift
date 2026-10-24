// OWNER: App worker. Pure decision logic: pose stream in, focus actions out.
import Foundation
import CoreGraphics

public final class SwitchEngine {
    public enum Hold: Equatable { case typing, mouse }

    public struct State: Equatable {
        public var estimate: GazeEstimate?
        public var currentDisplay: DisplayID?
        public var hold: Hold?
        public var paused: Bool
    }

    private let mapper: GazeMapper
    private let focus: FocusController
    private let input: InputActivityMonitoring
    private let settings: () -> Settings
    private let now: () -> TimeInterval
    private let displayFrame: (DisplayID) -> CGRect?
    private let displayAt: (CGPoint) -> DisplayID?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let latencyLog: LatencyLogging?
    private let traceLog: TraceLogging?

    public private(set) var currentDisplay: DisplayID?
    public private(set) var state: State
    public var onStateChange: ((State) -> Void)?
    /// Fired once when `mapper.driftScore` first exceeds `driftThreshold`.
    public var onDriftSuggested: (() -> Void)?

    public var driftThreshold = 0.4
    public var refitDebounce: TimeInterval = 5
    public var steadyTime: TimeInterval = 0.4
    public var paneMoveFraction = 0.15      // of display width
    public var paneStableFraction = 0.05
    /// A brief nil-display estimate (bezel gap / margin) shorter than this keeps the dwell alive.
    public var offScreenGrace: TimeInterval = 0.15
    /// How often to ask the focus controller which display is focused while the mouse is active.
    public var focusQueryInterval: TimeInterval = 0.25
    // Fast path: switch after `fastFrames` consecutive decisive frames instead of the full dwell.
    public var decisiveFraction = 0.12        // of the target display's width, beyond the shared edge
    public var fastMinConfidence = 0.6
    public var fastFrames = 2
    public var flickerWindow: TimeInterval = 0.5   // after a switch, going back needs the full dwell
    // Diagnostics
    public var missLogThreshold: TimeInterval = 0.1
    public var faceLostLogThreshold: TimeInterval = 0.3
    public var summaryInterval: TimeInterval = 30

    private var latestPose: HeadPose?
    private var latestPoseAt: TimeInterval = 0

    // display dwell
    private var candidateDisplay: DisplayID?
    private var candidateSince: TimeInterval = 0
    private var candidatePoseTime: TimeInterval = 0   // pose.timestamp when the gaze first left the current display
    private var offScreenSince: TimeInterval?
    private var decisiveFrames = 0
    private var lastSwitchAt: TimeInterval = -.infinity
    private var faceLostSince: TimeInterval?
    private var statStart: TimeInterval?
    private var statFrames = 0, statNoFace = 0, statOffScreen = 0, statConfidenceCount = 0
    private var statConfidenceSum = 0.0
    private var dwellDoneAt: TimeInterval?
    private var holdSeen: Hold?
    private var lastFocusQuery: TimeInterval = -.infinity
    private var cachedFocused: DisplayID?
    // pane dwell
    private var focusedPoint: CGPoint?
    private var paneCandidate: CGPoint?
    private var paneCandidateSince: TimeInterval = 0
    // steady gaze (for click learning)
    private var steadyAnchor: CGPoint?
    private var steadySince: TimeInterval = 0
    // click learning
    private var refitPending = false
    private var driftNotified = false

    public init(mapper: GazeMapper,
                focus: FocusController,
                input: InputActivityMonitoring,
                settings: @escaping () -> Settings,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                displayFrame: @escaping (DisplayID) -> CGRect? = { id in Displays.all().first { $0.id == id }?.frame },
                displayAt: @escaping (CGPoint) -> DisplayID? = { Displays.display(containing: $0) },
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
                },
                latencyLog: LatencyLogging? = LatencyLog(),
                traceLog: TraceLogging? = TraceLog()) {
        self.latencyLog = latencyLog
        self.traceLog = traceLog
        self.mapper = mapper; self.focus = focus; self.input = input
        self.settings = settings; self.now = now
        self.displayFrame = displayFrame; self.displayAt = displayAt; self.schedule = schedule
        self.state = State(estimate: nil, currentDisplay: nil, hold: nil, paused: false)
        input.onUserClick = { [weak self] p in self?.handleClick(p) }
    }

    /// Forget all dwell state (call on pause, camera restart, recalibration).
    public func reset() {
        clearCandidate("reset"); paneCandidate = nil; focusedPoint = nil
        steadyAnchor = nil; latestPose = nil; lastFocusQuery = -.infinity
        currentDisplay = nil
        publish(estimate: nil, hold: nil)
    }

    // MARK: Pose handling

    public func handle(pose: HeadPose?) {
        let t0 = now()
        process(pose)
        traceFrame(pose, t: t0)
    }

    private func process(_ pose: HeadPose?) {
        let s = settings()
        guard !s.paused else {
            clearCandidate("paused"); paneCandidate = nil; steadyAnchor = nil
            publish(estimate: nil, hold: nil)
            return
        }
        let t = now()
        recordFrame(t, hasFace: pose != nil)
        guard let pose else {
            clearCandidate("faceLost"); paneCandidate = nil; steadyAnchor = nil
            publish(estimate: nil, hold: nil)
            return
        }
        latestPose = pose; latestPoseAt = t

        if currentDisplay == nil { currentDisplay = focus.focusedDisplay() }
        let mouseActive = input.lastMouseTime > 0 && t - input.lastMouseTime < s.mousePriorityMs / 1000
        if mouseActive, let d = throttledFocusedDisplay(t), d != currentDisplay {
            // User moved focus by hand; follow it so hysteresis is relative to reality.
            currentDisplay = d; clearCandidate("manual"); paneCandidate = nil; focusedPoint = nil
        }

        guard let est = mapper.estimate(pose, currentDisplay: currentDisplay, edgeBias: s.headTurnThreshold) else {
            clearCandidate("faceLost"); paneCandidate = nil; steadyAnchor = nil
            publish(estimate: nil, hold: nil)
            return
        }
        statConfidenceSum += est.confidence; statConfidenceCount += 1
        updateSteady(est, at: t)

        // Off-screen gaze never switches anything.
        guard let display = est.displayID else {
            statOffScreen += 1
            paneCandidate = nil
            // A short gap (bezel / margin between displays) must not restart the dwell.
            if candidateDisplay != nil {
                let since = offScreenSince ?? t
                offScreenSince = since
                if t - since > offScreenGrace { clearCandidate("offscreen") }
            }
            publish(estimate: est, hold: nil)
            return
        }
        offScreenSince = nil

        let hold = activeHold(s, t)
        if display != currentDisplay {
            paneCandidate = nil
            if candidateDisplay != display {
                clearCandidate("returned")
                candidateDisplay = display; candidateSince = t; candidatePoseTime = pose.timestamp
                decisiveFrames = 0
            }
            decisiveFrames = isDecisive(est, display: display) ? decisiveFrames + 1 : 0
            // Anti-flicker: right after a switch, going back needs the full dwell.
            let flickerGuard = t - lastSwitchAt < flickerWindow
            let fast = !flickerGuard && decisiveFrames >= fastFrames
            if fast || t - candidateSince >= s.switchDelayMs / 1000 {
                if dwellDoneAt == nil { dwellDoneAt = t }
                if let h = hold { holdSeen = h }
                else {
                    let focusStart = now()
                    focus.focusDisplay(display, gazePoint: est.point, movePointer: s.movePointer)
                    logSwitch(to: display, pose: pose, dwellDone: dwellDoneAt ?? t, switchedAt: focusStart,
                              focusDuration: now() - focusStart, poseAge: t - pose.timestamp,
                              fast: fast && t - candidateSince < s.switchDelayMs / 1000)
                    currentDisplay = display
                    cachedFocused = display; lastFocusQuery = t   // don't let a stale cache revert us
                    lastSwitchAt = t
                    clearCandidate(nil)
                    focusedPoint = est.point
                }
            }
        } else {
            clearCandidate("returned")
            if s.windowFocusEnabled { updatePane(est.point, display: display, settings: s, t: t, hold: hold) }
        }
        publish(estimate: est, hold: hold)
    }

    /// Estimate is well inside `display`: past the edge it shares with the current display by
    /// `decisiveFraction` of its width, and confident enough to trust over the full dwell.
    private func isDecisive(_ est: GazeEstimate, display: DisplayID) -> Bool {
        guard est.confidence >= fastMinConfidence,
              let cur = currentDisplay, let curFrame = displayFrame(cur),
              let frame = displayFrame(display), frame.width > 0 else { return false }
        let dx = max(curFrame.minX - est.point.x, 0, est.point.x - curFrame.maxX)
        let dy = max(curFrame.minY - est.point.y, 0, est.point.y - curFrame.maxY)
        return hypot(dx, dy) >= decisiveFraction * frame.width
    }

    /// Drops the pending candidate. A non-nil `reason` logs a `miss` if it had been pending >= 100 ms.
    private func clearCandidate(_ reason: String? = nil) {
        if let cand = candidateDisplay, let reason, let log = latencyLog, log.isEnabled {
            let pending = now() - candidateSince
            if pending >= missLogThreshold {
                let why = holdSeen != nil ? "hold" : reason
                let holdText = holdSeen.map { $0 == .typing ? "typing" : "mouse" } ?? "none"
                log.log("miss display=\(cand) pending=\(Int(pending * 1000))ms reason=\(why) cause=\(reason) hold=\(holdText)")
            }
        }
        candidateDisplay = nil; offScreenSince = nil; dwellDoneAt = nil; holdSeen = nil; decisiveFrames = 0
    }

    // MARK: Diagnostics

    /// One CSV row per frame (numbers only) so real misses can be replayed against another mapper.
    private func traceFrame(_ pose: HeadPose?, t: TimeInterval) {
        guard let trace = traceLog, trace.isEnabled else { return }
        func f(_ x: Double, _ digits: Int = 4) -> String { String(format: "%.\(digits)f", x) }
        var cols = [String(format: "%.3f", pose?.timestamp ?? t)]
        if let p = pose {
            cols += [f(p.yaw), f(p.pitch), f(p.roll), f(Double(p.faceCenter.x)), f(Double(p.faceCenter.y)),
                     f(p.faceSize), f(Double(p.eyeOffset.dx)), f(Double(p.eyeOffset.dy)), f(p.confidence, 3)]
        } else {
            cols += Array(repeating: "", count: 9)
        }
        if let e = state.estimate {
            cols += [f(Double(e.point.x), 1), f(Double(e.point.y), 1), e.displayID.map { String($0) } ?? ""]
        } else {
            cols += ["", "", ""]
        }
        cols.append(currentDisplay.map { String($0) } ?? "")
        cols.append(state.hold.map { $0 == .typing ? "typing" : "mouse" } ?? "")
        cols.append(candidateDisplay.map { String($0) } ?? "")
        trace.write(cols.joined(separator: ","))
    }

    private func recordFrame(_ t: TimeInterval, hasFace: Bool) {
        guard let log = latencyLog, log.isEnabled else { return }
        if statStart == nil { statStart = t }
        statFrames += 1
        if hasFace {
            if let lost = faceLostSince {
                faceLostSince = nil
                if t - lost >= faceLostLogThreshold { log.log("faceLost span=\(Int((t - lost) * 1000))ms") }
            }
        } else {
            statNoFace += 1
            if faceLostSince == nil { faceLostSince = t }
        }
        if let start = statStart, t - start >= summaryInterval, statFrames > 0 {
            let n = Double(statFrames)
            let conf = statConfidenceCount > 0 ? statConfidenceSum / Double(statConfidenceCount) : 0
            log.log(String(format: "summary frames=%d noFace=%.0f%% offScreen=%.0f%% meanConf=%.2f",
                           statFrames, Double(statNoFace) / n * 100, Double(statOffScreen) / n * 100, conf))
            statStart = t; statFrames = 0; statNoFace = 0; statOffScreen = 0
            statConfidenceSum = 0; statConfidenceCount = 0
        }
    }

    private func throttledFocusedDisplay(_ t: TimeInterval) -> DisplayID? {
        if t - lastFocusQuery >= focusQueryInterval {
            lastFocusQuery = t
            cachedFocused = focus.focusedDisplay()
        }
        return cachedFocused
    }

    private func logSwitch(to display: DisplayID, pose: HeadPose, dwellDone: TimeInterval, switchedAt: TimeInterval,
                           focusDuration: TimeInterval, poseAge: TimeInterval, fast: Bool) {
        guard let log = latencyLog, log.isEnabled else { return }
        func ms(_ x: TimeInterval) -> String { String(format: "%.0f", x * 1000) }
        let holdText = holdSeen.map { "\($0 == .typing ? "typing" : "mouse") \(ms(switchedAt - dwellDone))ms" } ?? "none"
        log.log("switch display=\(display) leftAt=\(String(format: "%.3f", candidatePoseTime)) "
                + "dwellDoneAt=\(String(format: "%.3f", dwellDone)) dwell=\(ms(dwellDone - candidateSince))ms "
                + "poseAge=\(ms(poseAge))ms hold=\(holdText) focus=\(ms(focusDuration))ms "
                + "total=\(ms(switchedAt + focusDuration - candidatePoseTime))ms fast=\(fast ? 1 : 0)")
    }

    private func activeHold(_ s: Settings, _ t: TimeInterval) -> Hold? {
        if input.lastMouseTime > 0, t - input.lastMouseTime < s.mousePriorityMs / 1000 { return .mouse }
        if s.typingProtection, input.lastKeyTime > 0, t - input.lastKeyTime < s.typingPauseSec { return .typing }
        return nil
    }

    private func updatePane(_ p: CGPoint, display: DisplayID, settings s: Settings, t: TimeInterval, hold: Hold?) {
        guard let width = displayFrame(display)?.width, width > 0 else { return }
        guard let anchor = focusedPoint else { focusedPoint = p; return }
        if hypot(p.x - anchor.x, p.y - anchor.y) <= paneMoveFraction * width {
            paneCandidate = nil
            return
        }
        if let c = paneCandidate, hypot(p.x - c.x, p.y - c.y) <= paneStableFraction * width {
            // still dwelling
        } else {
            paneCandidate = p; paneCandidateSince = t
        }
        if t - paneCandidateSince >= s.paneDelayMs / 1000, hold == nil {
            focus.focusWithinDisplay(at: p, clickFallback: s.paneClickFallback)
            focusedPoint = p
            paneCandidate = nil
        }
    }

    private func updateSteady(_ est: GazeEstimate, at t: TimeInterval) {
        let width = est.displayID.flatMap { displayFrame($0)?.width } ?? 1000
        if let a = steadyAnchor, hypot(est.point.x - a.x, est.point.y - a.y) <= paneStableFraction * width {
            return
        }
        steadyAnchor = est.point; steadySince = t
    }

    private func publish(estimate: GazeEstimate?, hold: Hold?) {
        let new = State(estimate: estimate, currentDisplay: currentDisplay, hold: hold, paused: settings().paused)
        guard new != state else { return }
        state = new
        onStateChange?(new)
    }

    // MARK: Click learning

    func handleClick(_ click: CGPoint) {
        let s = settings()
        guard !s.paused else { return }
        let t = now()
        if let d = displayAt(click) {
            // A manual click always defines where focus is now.
            if d != currentDisplay { currentDisplay = d; clearCandidate("manual"); paneCandidate = nil; lastFocusQuery = -.infinity }
            focusedPoint = click
        }
        guard s.learnFromClicks, let pose = latestPose, t - latestPoseAt < 0.5,
              steadyAnchor != nil, t - steadySince >= steadyTime,
              let actual = displayAt(click) else { return }
        let predicted = state.estimate?.displayID
        mapper.addSample(pose, target: click, weight: 0.3)
        mapper.recordClickOutcome(predicted: predicted, actual: actual)
        scheduleRefit()
        if !driftNotified, mapper.driftScore > driftThreshold {
            driftNotified = true
            onDriftSuggested?()
        }
    }

    /// Allow the drift suggestion to fire again (after the user recalibrated).
    public func clearDriftNotice() { driftNotified = false }

    private func scheduleRefit() {
        guard !refitPending else { return }
        refitPending = true
        schedule(refitDebounce) { [weak self] in
            guard let self else { return }
            self.refitPending = false
            if self.mapper.fit() { try? self.mapper.save() }
        }
    }
}
