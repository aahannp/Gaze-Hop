// OWNER: Tracking worker.
// One-Euro filter (Casiez et al. 2012): low-pass whose cutoff rises with signal speed,
// so a still head is rock steady while fast turns have little lag.
import Foundation

public struct OneEuroFilter {
    public var minCutoff: Double   // Hz, jitter suppression when still
    public var beta: Double        // speed coefficient, lag reduction when moving
    public var dCutoff: Double     // Hz, cutoff for the derivative estimate

    private var xPrev: Double?
    private var dxPrev = 0.0
    private var tPrev = 0.0

    public init(minCutoff: Double = 1.0, beta: Double = 0.0, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }

    public mutating func reset() { xPrev = nil; dxPrev = 0 }

    /// `t` in seconds, monotonically increasing.
    public mutating func filter(_ x: Double, at t: TimeInterval) -> Double {
        guard let prev = xPrev else {
            xPrev = x; tPrev = t; dxPrev = 0
            return x
        }
        let dt = max(t - tPrev, 1e-6)
        let dx = (x - prev) / dt
        let dxHat = dxPrev + Self.alpha(cutoff: dCutoff, dt: dt) * (dx - dxPrev)
        let cutoff = minCutoff + beta * abs(dxHat)
        let xHat = prev + Self.alpha(cutoff: cutoff, dt: dt) * (x - prev)
        xPrev = xHat; dxPrev = dxHat; tPrev = t
        return xHat
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}
