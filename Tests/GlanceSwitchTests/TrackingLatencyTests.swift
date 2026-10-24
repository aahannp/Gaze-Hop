import XCTest
@testable import GlanceKit

/// Offline step response of the real smoothing chain: 15 Hz yaw step 0 -> 0.4 rad plus ~1.5deg noise.
final class TrackingLatencyTests: XCTestCase {
    struct Result { var t50: Double; var t90: Double; var jitterDeg: Double }

    static func measure(_ config: PoseSmoother.Config, seed: UInt64 = 7) -> Result {
        var rng = seed
        func noise() -> Double {   // uniform +-1.5deg peak (about 0.87deg std)
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return (Double(rng >> 33) / Double(1 << 31) - 0.5) * 2 * (1.5 * .pi / 180)
        }
        let dt = 1.0 / 15, stepAt = 30, n = 120, target = 0.4
        var s = PoseSmoother(config: config)
        var out = [Double]()
        for i in 0..<n {
            let clean = i < stepAt ? 0.0 : target
            out.append(s.smooth([clean + noise(), 0, 0, 0.5, 0.5, 0.2, 0, 0], at: Double(i) * dt)[0])
        }
        func crossing(_ frac: Double) -> Double {
            for i in stepAt..<n where out[i] >= frac * target { return Double(i - stepAt) * dt * 1000 }
            return .infinity
        }
        let still = out[10..<stepAt].map { $0 * 180 / .pi }
        let m = still.reduce(0, +) / Double(still.count)
        let std = (still.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(still.count)).squareRoot()
        return Result(t50: crossing(0.5), t90: crossing(0.9), jitterDeg: std)
    }

    func testStepLagBeforeAndAfter() {
        let before = Self.measure(PoseSmoother.legacy)
        let after = Self.measure(PoseSmoother.standard)
        print(String(format: "LAG before: t50 %.0f ms, t90 %.0f ms, still jitter std %.2f deg", before.t50, before.t90, before.jitterDeg))
        print(String(format: "LAG after : t50 %.0f ms, t90 %.0f ms, still jitter std %.2f deg", after.t50, after.t90, after.jitterDeg))
        XCTAssertLessThanOrEqual(after.t90, 130)
        XCTAssertLessThan(after.jitterDeg, 1.5)
    }

    /// Eye dx saccade (0 -> 0.6 step at 15 Hz, noise 0.02) through the mesh config's eye channel.
    func testMeshEyeSaccadeLag() {
        var s = PoseSmoother(config: PoseSmoother.mesh)
        var rng: UInt64 = 11
        var out = [Double]()
        for i in 0..<90 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Double(rng >> 33) / Double(1 << 31) - 0.5) * 0.04
            out.append(s.smooth([0, 0, 0, 0.5, 0.5, 0.2, (i < 30 ? 0 : 0.6) + noise, 0], at: Double(i) / 15)[6])
        }
        let t90 = out[30...].firstIndex { $0 >= 0.54 }.map { Double($0 - 30) * 1000 / 15 } ?? .infinity
        let rest = out[10..<30]; let m = rest.reduce(0, +) / Double(rest.count)
        let std = (rest.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(rest.count)).squareRoot()
        print(String(format: "MESH eye saccade: t90 %.0f ms, rest std %.3f (raw noise std 0.012)", t90, std))
        XCTAssertLessThanOrEqual(t90, 70)
        XCTAssertLessThan(std, 0.02)
    }
}
