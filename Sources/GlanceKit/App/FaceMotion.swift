// OWNER: App worker. Display-rate motion for the live view: ~15 Hz jittery samples in, smooth frames out.
import Foundation
import CoreGraphics

/// Critically damped spring, integrated exactly: stable for any dt, and from rest it never overshoots
/// a fixed target or the end of a ramp.
public struct Spring: Equatable {
    public var value: Double
    public var velocity = 0.0
    public init(_ value: Double = 0) { self.value = value }

    public mutating func step(toward target: Double, omega: Double, dt: Double) {
        guard dt > 0 else { return }
        let y = value - target, c = velocity + omega * y, e = exp(-omega * dt)
        value = target + (y + c * dt) * e
        velocity = (c - omega * (y + c * dt)) * e
    }
}

/// N channels that follow timestamped samples. Each sample starts a linear ramp from wherever the target
/// is now, lasting one measured sample interval, so a steady movement sampled at 15 Hz becomes a steady
/// target instead of a staircase. A spring per channel follows the ramp, so velocity stays continuous.
struct RampFollower {
    private(set) var springs: [Spring]
    private var from: [Double], to: [Double]
    private var start = 0.0, duration = 0.0, eased = false
    /// Running estimate of the time between samples (starts at the tracker's nominal 15 Hz).
    private(set) var interval = 1.0 / 15
    private var lastSample: Double?

    init(_ values: [Double]) { springs = values.map { Spring($0) }; from = values; to = values }

    var values: [Double] { springs.map(\.value) }
    var goal: [Double] { to }

    func target(at t: Double) -> [Double] {
        var u = duration > 0 ? min(max((t - start) / duration, 0), 1) : 1
        if eased { u = u * u * (3 - 2 * u) }
        return zip(from, to).map { $0 + ($1 - $0) * u }
    }

    /// A fresh sample: updates the interval estimate (ignoring gaps such as a lost face) and ramps to it.
    mutating func sample(_ v: [Double], at t: Double, over d: Double? = nil) {
        if let last = lastSample, t - last < 0.25 {
            interval += 0.25 * (min(max(t - last, 1.0 / 120), 0.2) - interval)
        }
        lastSample = t
        retarget(v, at: t, over: d ?? interval)
    }

    mutating func retarget(_ v: [Double], at t: Double, over d: Double, eased e: Bool = false) {
        from = target(at: t); to = v; start = t; duration = d; eased = e
    }

    /// Advances every spring by `dt` toward the ramp at `t`; `omega(channel, target, value)` picks stiffness.
    mutating func step(to t: Double, dt: Double, omega: (Int, Double, Double) -> Double,
                       override: (Int) -> Double? = { _ in nil }) {
        let goal = target(at: t)
        for i in springs.indices {
            let g = override(i) ?? goal[i]
            springs[i].step(toward: g, omega: omega(i, g, springs[i].value), dt: dt)
        }
    }

    /// Jump straight to the latest sample (first frame, snapshots).
    mutating func settle() {
        for i in springs.indices { springs[i] = Spring(to[i]) }
        from = to; duration = 0
    }
}

extension FaceAngles {
    static let channelCount = 9
    var channels: [Double] { [yaw, pitch, roll, eyeYaw, eyePitch, openness, leanX, leanY, scale] }
    init(channels c: [Double]) {
        self.init()
        yaw = c[0]; pitch = c[1]; roll = c[2]; eyeYaw = c[3]; eyePitch = c[4]
        openness = min(max(c[5], 0), 1); leanX = c[6]; leanY = c[7]; scale = c[8]
    }
}

/// Turns ~15 Hz face samples (jittery, sometimes missing) into one pose per display frame.
///
/// Head and eyes ramp + spring (see `RampFollower`). Lids skip the ramp, since a blink is often a single
/// camera frame, and close faster than they reopen. Lean and distance are only hints, so they move slowly.
/// A missing face holds still for `hold` (one dropped frame never moves the face), then eases to neutral
/// while `presence` fades to 0. When the face comes back it ramps there without a jump.
public struct FaceAnimator {
    public struct Tuning {
        /// Spring stiffness (rad/s). Lag for a steady movement is about 2/ω plus half a sample interval.
        public var head = 24.0, eyes = 30.0, body = 7.0
        public var lidClose = 75.0, lidOpen = 36.0, presence = 7.0
        public var hold = 0.45, toNeutral = 1.1, reacquire = 0.22
        public init() {}
    }
    public var tuning = Tuning()
    public private(set) var output = FaceAngles()
    /// 1 while a face is tracked; eases to 0 once it has been missing for longer than `hold`.
    public private(set) var presence = Spring(1)
    public var isLost: Bool { lostSince != nil }

    private var follower = RampFollower(FaceAngles().channels)
    private var lostSince: Double?
    private var easingToNeutral = false
    private var now: Double?

    public init() {}

    public mutating func push(_ a: FaceAngles?, at t: Double) {
        if let a {
            let wasGone = easingToNeutral
            lostSince = nil; easingToNeutral = false
            follower.sample(a.channels, at: t, over: wasGone ? tuning.reacquire : nil)
        } else if lostSince == nil {
            lostSince = t
        }
    }

    /// Steps to time `t` (seconds, any monotonic clock shared with `push`) and returns the pose to show.
    @discardableResult
    public mutating func advance(to t: Double) -> FaceAngles {
        let dt = now.map { min(max(t - $0, 0), 0.1) } ?? 0
        now = t
        if let lost = lostSince, t - lost >= tuning.hold, !easingToNeutral {
            easingToNeutral = true
            follower.retarget(FaceAngles().channels, at: t, over: tuning.toNeutral, eased: true)
        }
        let tu = tuning, latestLid = follower.goal[5]
        follower.step(to: t, dt: dt, omega: { i, goal, value in
            switch i {
            case 0...2: return tu.head
            case 3, 4: return tu.eyes
            case 5: return goal < value ? tu.lidClose : tu.lidOpen
            default: return tu.body
            }
        }, override: { [easingToNeutral] i in i == 5 && !easingToNeutral ? latestLid : nil })
        presence.step(toward: easingToNeutral ? 0 : 1, omega: tuning.presence, dt: dt)
        output = FaceAngles(channels: follower.values)
        return output
    }

    /// Show the latest sample immediately (snapshots, or the first frame after the view appears).
    public mutating func settle() {
        follower.settle()
        output = FaceAngles(channels: follower.values)
        presence = Spring(easingToNeutral ? 0 : 1)
    }
}

/// The gaze dot on the mini-map: follows ~15 Hz estimates in CG global points, keeps a short trail, and
/// fades out (after a short hold) when there is no estimate.
public struct GazeAnimator {
    public var omega = 18.0, hold = 0.3, trailLength = 0.45
    public private(set) var point: CGPoint?
    /// 0...1 dot opacity.
    public private(set) var visibility = Spring(0)
    /// 0 = on a display, 1 = off-screen; eased so the dot changes style smoothly.
    public private(set) var offScreen = Spring(0)
    public private(set) var trail: [(point: CGPoint, time: Double)] = []

    private var follower: RampFollower?
    private var lostSince: Double?
    private var offTarget = 0.0
    private var now: Double?

    public init() {}

    public mutating func push(_ e: GazeEstimate?, at t: Double) {
        guard let e else { if lostSince == nil { lostSince = t }; return }
        lostSince = nil
        offTarget = e.displayID == nil ? 1 : 0
        let v = [Double(e.point.x), Double(e.point.y)]
        if follower == nil { follower = RampFollower(v) } else { follower?.sample(v, at: t) }
    }

    public mutating func advance(to t: Double) {
        let dt = now.map { min(max(t - $0, 0), 0.1) } ?? 0
        now = t
        guard var f = follower else { return }
        let w = omega
        f.step(to: t, dt: dt, omega: { _, _, _ in w })
        follower = f
        let p = CGPoint(x: f.values[0], y: f.values[1])
        point = p
        let gone = lostSince.map { t - $0 >= hold } ?? false
        visibility.step(toward: gone ? 0 : 1, omega: gone ? 8 : 14, dt: dt)
        offScreen.step(toward: offTarget, omega: 12, dt: dt)
        if !gone { trail.append((p, t)) }
        if let i = trail.firstIndex(where: { t - $0.time <= trailLength }) { trail.removeFirst(i) } else { trail.removeAll() }
    }

    public mutating func settle() {
        follower?.settle()
        if let f = follower { point = CGPoint(x: f.values[0], y: f.values[1]) }
        visibility = Spring(lostSince == nil && follower != nil ? 1 : 0)
        offScreen = Spring(offTarget)
    }

    /// Lets snapshots draw a trail without running the clock.
    mutating func setTrail(_ points: [CGPoint], endingAt t: Double) {
        trail = points.enumerated().map { ($1, t - trailLength * Double(points.count - 1 - $0) / Double(max(points.count, 1))) }
    }
}
