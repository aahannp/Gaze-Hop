import XCTest
@testable import GlanceKit

struct SplitMix: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Fake "true" gaze: x/y are linear in head angles, with gain growing with faceSize (distance).
enum FakeGaze {
    static let A = Displays.Info(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
    static let B = Displays.Info(id: 2, frame: CGRect(x: 2560, y: 0, width: 2560, height: 1440))
    static let both = [A, B]

    static func pose(for t: CGPoint, size: Double, noise: Double = 0, rng: inout SplitMix, confidence: Double = 0.9) -> HeadPose {
        let k = size / 0.3
        func n() -> Double { noise == 0 ? 0 : Double.random(in: -noise...noise, using: &rng) }
        let yaw = (Double(t.x) - 2560) / (4500 * k) + n()
        let pitch = -(Double(t.y) - 720) / (3000 * k) + n()
        return HeadPose(timestamp: 0, yaw: yaw, pitch: pitch, roll: 0.01,
                        faceCenter: CGPoint(x: 0.5 + yaw * 0.1, y: 0.5 - pitch * 0.1), faceSize: size,
                        eyeOffset: CGVector(dx: yaw * 0.3, dy: pitch * 0.3), confidence: confidence)
    }

    static func mapper(noise: Double = 0.002, tmp: String = UUID().uuidString) -> (RegressionGazeMapper, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glance-\(tmp).json")
        let m = RegressionGazeMapper(url: url, displays: { both })
        var rng = SplitMix(s: 7)
        for d in both {
            for size in [0.25, 0.35] {
                for gx in 0..<4 { for gy in 0..<4 {
                    let t = CGPoint(x: d.frame.minX + d.frame.width * (0.05 + 0.9 * Double(gx) / 3),
                                    y: d.frame.minY + d.frame.height * (0.05 + 0.9 * Double(gy) / 3))
                    m.addSample(pose(for: t, size: size, noise: noise, rng: &rng), target: t, weight: 1)
                } }
            }
        }
        XCTAssertTrue(m.fit())
        return (m, url)
    }
}

final class CalibrationMapperTests: XCTestCase {
    func testHeldOutAccuracy() {
        let (m, _) = FakeGaze.mapper()
        var rng = SplitMix(s: 99)
        var ok = 0, total = 2000
        for _ in 0..<total {
            let d = Bool.random(using: &rng) ? FakeGaze.A : FakeGaze.B
            let t = CGPoint(x: Double.random(in: d.frame.minX + 1...d.frame.maxX - 1, using: &rng),
                            y: Double.random(in: 1...1439, using: &rng))
            let size = Double.random(in: 0.22...0.38, using: &rng)
            let p = FakeGaze.pose(for: t, size: size, noise: 0.002, rng: &rng)
            if m.estimate(p, currentDisplay: nil, edgeBias: 0.5, displays: FakeGaze.both)?.displayID == d.id { ok += 1 }
        }
        XCTAssertGreaterThan(Double(ok) / Double(total), 0.95)
        total = 0
    }

    func testOffscreenIsNil() {
        let (m, _) = FakeGaze.mapper()
        var rng = SplitMix(s: 1)
        for t in [CGPoint(x: 2560, y: -900), CGPoint(x: -1500, y: 700), CGPoint(x: 6800, y: 700), CGPoint(x: 2560, y: 2600)] {
            let e = m.estimate(FakeGaze.pose(for: t, size: 0.3, rng: &rng), currentDisplay: nil, edgeBias: 0.5, displays: FakeGaze.both)
            XCTAssertNotNil(e); XCTAssertNil(e?.displayID, "\(t)")
        }
        // Just outside the edge (within margin) still counts.
        let near = m.estimate(FakeGaze.pose(for: CGPoint(x: -100, y: 700), size: 0.3, rng: &rng), currentDisplay: nil, edgeBias: 0.5, displays: FakeGaze.both)
        XCTAssertEqual(near?.displayID, 1)
    }

    func testLowConfidenceIsNil() {
        let (m, _) = FakeGaze.mapper()
        var rng = SplitMix(s: 1)
        let p = FakeGaze.pose(for: CGPoint(x: 1000, y: 700), size: 0.3, rng: &rng, confidence: 0.1)
        XCTAssertNil(m.estimate(p, currentDisplay: nil, edgeBias: 0.5, displays: FakeGaze.both))
    }

    func testEdgeBiasShiftsBoundary() {
        let (m, _) = FakeGaze.mapper(noise: 0)
        var rng = SplitMix(s: 1)
        let p = FakeGaze.pose(for: CGPoint(x: 2700, y: 700), size: 0.3, rng: &rng)   // 140px into B
        func disp(_ bias: Double) -> DisplayID? {
            m.estimate(p, currentDisplay: nil, edgeBias: bias, displays: FakeGaze.both)?.displayID
        }
        XCTAssertEqual(disp(0.5), 2)
        XCTAssertEqual(disp(1.0), 1)   // boundary pushed deep into B
        let q = FakeGaze.pose(for: CGPoint(x: 2400, y: 700), size: 0.3, rng: &rng)  // 160px into A
        XCTAssertEqual(m.estimate(q, currentDisplay: nil, edgeBias: 0.5, displays: FakeGaze.both)?.displayID, 1)
        XCTAssertEqual(m.estimate(q, currentDisplay: nil, edgeBias: 0.0, displays: FakeGaze.both)?.displayID, 2)
    }

    func testHysteresisPreventsFlipFlop() {
        let (m, _) = FakeGaze.mapper(noise: 0)
        var rng = SplitMix(s: 1)
        var cur: DisplayID? = 1
        var switches = 0
        // Jitter around the boundary (x = 2560 ± 30).
        for i in 0..<40 {
            let x = 2560 + (i % 2 == 0 ? 30.0 : -30.0)
            let e = m.estimate(FakeGaze.pose(for: CGPoint(x: x, y: 700), size: 0.3, rng: &rng), currentDisplay: cur, edgeBias: 0.5, displays: FakeGaze.both)
            if let id = e?.displayID, id != cur { switches += 1; cur = id }
        }
        XCTAssertEqual(switches, 0)
        // A decisive move still switches.
        let e = m.estimate(FakeGaze.pose(for: CGPoint(x: 2900, y: 700), size: 0.3, rng: &rng), currentDisplay: cur, edgeBias: 0.5, displays: FakeGaze.both)
        XCTAssertEqual(e?.displayID, 2)
    }

    func testStackedAndLaptopBelow() {
        let ext = Displays.Info(id: 5, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let lap = Displays.Info(id: 6, frame: CGRect(x: 500, y: 1440, width: 1440, height: 900))
        let r = DisplayResolver.resolve(CGPoint(x: 800, y: 1300), displays: [ext, lap], current: nil, edgeBias: 0.5)
        XCTAssertEqual(r.id, 5)
        XCTAssertEqual(DisplayResolver.resolve(CGPoint(x: 800, y: 1600), displays: [ext, lap], current: nil, edgeBias: 0.5).id, 6)
        XCTAssertNil(DisplayResolver.resolve(CGPoint(x: 100, y: 2000), displays: [ext, lap], current: nil, edgeBias: 0.5).id)
    }

    func testSaveLoadRoundTrip() throws {
        let (m, url) = FakeGaze.mapper()
        defer { try? FileManager.default.removeItem(at: url) }
        try m.save()
        let m2 = RegressionGazeMapper(url: url, displays: { FakeGaze.both })
        XCTAssertFalse(m2.isCalibrated)
        try m2.load()
        XCTAssertTrue(m2.isCalibrated)
        XCTAssertEqual(m2.sampleCount, m.sampleCount)
        var rng = SplitMix(s: 3)
        let p = FakeGaze.pose(for: CGPoint(x: 3800, y: 400), size: 0.3, rng: &rng)
        XCTAssertEqual(m.estimate(p, currentDisplay: nil, edgeBias: 0.5, displays: FakeGaze.both)?.point,
                       m2.estimate(p, currentDisplay: nil, edgeBias: 0.5, displays: FakeGaze.both)?.point)
        // Changed arrangement => not calibrated.
        let m3 = RegressionGazeMapper(url: url, displays: { [FakeGaze.A] })
        try m3.load()
        XCTAssertFalse(m3.isCalibrated)
    }

    func testDriftScore() {
        let m = RegressionGazeMapper(url: FileManager.default.temporaryDirectory.appendingPathComponent("x.json"), displays: { FakeGaze.both })
        XCTAssertEqual(m.driftScore, 0)
        for _ in 0..<20 { m.recordClickOutcome(predicted: 1, actual: 1) }
        XCTAssertLessThan(m.driftScore, 0.05)
        for _ in 0..<8 { m.recordClickOutcome(predicted: 1, actual: 2) }
        XCTAssertGreaterThan(m.driftScore, 0.4)
        m.reset(); XCTAssertEqual(m.driftScore, 0)
    }

    func testClickBufferBounded() {
        let (m, _) = FakeGaze.mapper()
        var rng = SplitMix(s: 5)
        let base = m.sampleCount
        for i in 0..<400 {
            let t = CGPoint(x: Double(i % 5000), y: 500)
            m.addSample(FakeGaze.pose(for: t, size: 0.3, rng: &rng), target: t, weight: 0.3)
        }
        XCTAssertEqual(m.sampleCount, base + RegressionGazeMapper.maxClickSamples)
    }
}
