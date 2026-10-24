// OWNER: App worker. Pure mapping from tracker output to the live face rig and the mini-map.
import Foundation
import CoreGraphics

/// What the live face shows, in the USER's conventions (as in `HeadPose`): + yaw = turned to the user's
/// right, + pitch = up, + roll = clockwise. Eye angles are the eyeballs' rotation inside the head.
public struct FaceAngles: Equatable {
    public var yaw = 0.0, pitch = 0.0, roll = 0.0
    public var eyeYaw = 0.0, eyePitch = 0.0
    public var openness = 1.0
    /// Subtle lean (scene units, + right / + up) and a distance scale (1 = typical distance).
    public var leanX = 0.0, leanY = 0.0, scale = 1.0
    public init() {}
}

public enum FaceMapping {
    public static let maxYaw = 1.0, maxPitch = 0.8, maxRoll = 0.7
    public static let maxEyeYaw = 0.55, maxEyePitch = 0.45
    /// Head angles (radians) that read as a full-scale signal: about where you'd turn to look at a side display.
    public static let signalYaw = 0.6, signalPitch = 0.4
    /// faceSize that reads as "normal distance" (bbox width / frame width).
    public static let referenceFaceSize = 0.3

    private static func clamp(_ v: Double, _ limit: Double) -> Double { min(max(v, -limit), limit) }

    /// The mirror image of the user. `nil` pose (no face) yields the neutral face.
    public static func angles(from pose: HeadPose?) -> FaceAngles {
        var a = FaceAngles()
        guard let p = pose else { return a }
        a.yaw = clamp(p.yaw, maxYaw)
        a.pitch = clamp(p.pitch, maxPitch)
        a.roll = clamp(p.roll, maxRoll)
        a.openness = min(max(p.eyeOpenness, 0), 1)
        // Offsets are unreliable while the lids are down; the face keeps looking where it did (the
        // caller holds the previous eyes), so just report zero here and let the rig hold.
        a.eyeYaw = clamp(Double(p.eyeOffset.dx), 1) * maxEyeYaw
        a.eyePitch = clamp(Double(p.eyeOffset.dy), 1) * maxEyePitch
        a.leanX = clamp(Double(p.faceCenter.x) - 0.5, 0.5) * 0.9      // + = user's right
        a.leanY = clamp(0.5 - Double(p.faceCenter.y), 0.5) * 0.6      // frame y grows down
        let ratio = p.faceSize > 0 ? p.faceSize / referenceFaceSize : 1
        a.scale = pow(min(max(ratio, 0.6), 1.6), 0.35)               // damped: a hint of distance, not a zoom
        return a
    }

    /// Normalised signals (-1...1) for the "head vs eyes" bars: horizontal and vertical.
    public struct Signals: Equatable {
        public var headX = 0.0, headY = 0.0, eyeX = 0.0, eyeY = 0.0
    }
    public static func signals(from pose: HeadPose?) -> Signals {
        guard let p = pose else { return Signals() }
        return Signals(headX: clamp(p.yaw / signalYaw, 1), headY: clamp(p.pitch / signalPitch, 1),
                       eyeX: clamp(Double(p.eyeOffset.dx), 1), eyeY: clamp(Double(p.eyeOffset.dy), 1))
    }
}

/// Mini-map of the displays drawn to scale inside `size`.
public struct MiniMapLayout: Equatable {
    public let scale: CGFloat
    public let origin: CGPoint        // view-space position of the union's top-left corner
    public let union: CGRect
    public let displays: [Displays.Info]

    public init(displays: [Displays.Info], size: CGSize, padding: CGFloat = 12) {
        self.displays = displays
        let u = displays.map { $0.frame }.reduce(CGRect.null) { $0.union($1) }
        union = u.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : u
        let aw = max(size.width - 2 * padding, 1), ah = max(size.height - 2 * padding, 1)
        scale = min(aw / union.width, ah / union.height)
        origin = CGPoint(x: (size.width - union.width * scale) / 2, y: (size.height - union.height * scale) / 2)
    }

    public func rect(of info: Displays.Info) -> CGRect {
        CGRect(x: origin.x + (info.frame.minX - union.minX) * scale, y: origin.y + (info.frame.minY - union.minY) * scale,
               width: info.frame.width * scale, height: info.frame.height * scale)
    }

    /// CG global point -> view space; optionally clamped to `bounds` so an off-screen gaze stays visible.
    public func point(_ p: CGPoint, clampedTo bounds: CGRect? = nil) -> CGPoint {
        var v = CGPoint(x: origin.x + (p.x - union.minX) * scale, y: origin.y + (p.y - union.minY) * scale)
        if let b = bounds { v.x = min(max(v.x, b.minX), b.maxX); v.y = min(max(v.y, b.minY), b.maxY) }
        return v
    }
}
