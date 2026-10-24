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

    private var latestPose: HeadPose?
    private var latestPoseAt: TimeInterval = 0

    // display dwell
    private var candidateDisplay: DisplayID?
    private var candidateSince: TimeInterval = 0
    private var candidatePoseTime: TimeInterval = 0   // pose.timestamp when the gaze first left the current display
    private var offScreenSince: TimeInterval?
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
                latencyLog: LatencyLogging? = LatencyLog()) {
        self.latencyLog = latencyLog
        self.mapper = mapper; self.focus = focus; self.input = input
        self.settings = settings; self.now = now
        self.displayFrame = displayFrame; self.displayAt = displayAt; self.schedule = schedule
        self.state = State(estimate: nil, currentDisplay: nil, hold: nil, paused: false)
        input.onUserClick = { [weak self] p in self?.handleClick(p) }
    }

    /// Forget all dwell state (call on pause, camera restart, recalibration).
    public func reset() {
        clearCandidate(); paneCandidate = nil; focusedPoint = nil
        steadyAnchor = nil; latestPose = nil; lastFocusQuery = -.infinity
        currentDisplay = nil
        publish(estimate: nil, hold: nil)
    }

    // MARK: Pose handling

    public func handle(pose: HeadPose?) {
        let s = settings()
        guard !s.paused else {
            clearCandidate(); paneCandidate = nil; steadyAnchor = nil
            publish(estimate: nil, hold: nil)
            return
        }
        let t = now()
        guard let pose else {
            clearCandidate(); paneCandidate = nil; steadyAnchor = nil
            publish(estimate: nil, hold: nil)
            return
        }
        latestPose = pose; latestPoseAt = t

        if currentDisplay == nil { currentDisplay = focus.focusedDisplay() }
        let mouseActive = input.lastMouseTime > 0 && t - input.lastMouseTime < s.mousePriorityMs / 1000
        if mouseActive, let d = throttledFocusedDisplay(t), d != currentDisplay {
            // User moved focus by hand; follow it so hysteresis is relative to reality.
            currentDisplay = d; clearCandidate(); paneCandidate = nil; focusedPoint = nil
        }

        guard let est = mapper.estimate(pose, currentDisplay: currentDisplay, edgeBias: s.headTurnThreshold) else {
            clearCandidate(); paneCandidate = nil; steadyAnchor = nil
            publish(estimate: nil, hold: nil)
            return
        }
        updateSteady(est, at: t)

        // Off-screen gaze never switches anything.
        guard let display = est.displayID else {
            paneCandidate = nil
            // A short gap (bezel / margin between displays) must not restart the dwell.
            if candidateDisplay != nil {
                let since = offScreenSince ?? t
                offScreenSince = since
                if t - since > offScreenGrace { clearCandidate() }
            }
            publish(estimate: est, hold: nil)
            return
        }
        offScreenSince = nil

        let hold = activeHold(s, t)
        if display != currentDisplay {
            paneCandidate = nil
            if candidateDisplay != display {
                clearCandidate()
                candidateDisplay = display; candidateSince = t; candidatePoseTime = pose.timestamp
            }
            if t - candidateSince >= s.switchDelayMs / 1000 {
                if dwellDoneAt == nil { dwellDoneAt = t }
                if let h = hold { holdSeen = h }
                else {
                    let focusStart = now()
                    focus.focusDisplay(display, gazePoint: est.point, movePointer: s.movePointer)
                    logSwitch(to: display, pose: pose, dwellDone: dwellDoneAt ?? t, switchedAt: focusStart,
                              focusDuration: now() - focusStart, poseAge: t - pose.timestamp)
                    currentDisplay = display
                    cachedFocused = display; lastFocusQuery = t   // don't let a stale cache revert us
                    clearCandidate()
                    focusedPoint = est.point
                }
            }
        } else {
            clearCandidate()
            if s.windowFocusEnabled { updatePane(est.point, display: display, settings: s, t: t, hold: hold) }
        }
        publish(estimate: est, hold: hold)
    }

    private func clearCandidate() {
        candidateDisplay = nil; offScreenSince = nil; dwellDoneAt = nil; holdSeen = nil
    }

    private func throttledFocusedDisplay(_ t: TimeInterval) -> DisplayID? {
        if t - lastFocusQuery >= focusQueryInterval {
            lastFocusQuery = t
            cachedFocused = focus.focusedDisplay()
        }
        return cachedFocused
    }

    private func logSwitch(to display: DisplayID, pose: HeadPose, dwellDone: TimeInterval, switchedAt: TimeInterval,
                           focusDuration: TimeInterval, poseAge: TimeInterval) {
        guard let log = latencyLog, log.isEnabled else { return }
        func ms(_ x: TimeInterval) -> String { String(format: "%.0f", x * 1000) }
        let holdText = holdSeen.map { "\($0 == .typing ? "typing" : "mouse") \(ms(switchedAt - dwellDone))ms" } ?? "none"
        log.log("switch display=\(display) leftAt=\(String(format: "%.3f", candidatePoseTime)) "
                + "dwellDoneAt=\(String(format: "%.3f", dwellDone)) dwell=\(ms(dwellDone - candidateSince))ms "
                + "poseAge=\(ms(poseAge))ms hold=\(holdText) focus=\(ms(focusDuration))ms "
                + "total=\(ms(switchedAt + focusDuration - candidatePoseTime))ms")
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
            if d != currentDisplay { currentDisplay = d; clearCandidate(); paneCandidate = nil; lastFocusQuery = -.infinity }
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
