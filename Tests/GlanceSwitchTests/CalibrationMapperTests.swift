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
        // A decisive move still switches (leaving needs a high posterior).
        let e = m.estimate(FakeGaze.pose(for: CGPoint(x: 3700, y: 700), size: 0.3, rng: &rng), currentDisplay: cur, edgeBias: 0.5, displays: FakeGaze.both)
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

final class CalibrationProfileTests: XCTestCase {
    /// Trains a mapper on `displays` (a fake gaze centred on the desktop) and returns it.
    func train(_ m: RegressionGazeMapper, displays: [Displays.Info]) {
        var rng = SplitMix(s: 11)
        let b = displays.map { $0.frame }.reduce(CGRect.null) { $0.union($1) }
        for d in displays { for gx in 0..<4 { for gy in 0..<4 { for size in [0.25, 0.35] {
            let t = CGPoint(x: d.frame.minX + d.frame.width * (0.05 + 0.3 * Double(gx)),
                            y: d.frame.minY + d.frame.height * (0.05 + 0.3 * Double(gy)))
            let k = size / 0.3
            let yaw = Double(t.x - b.midX) / (4500 * k), pitch = -Double(t.y - b.midY) / (3000 * k)
            m.addSample(HeadPose(timestamp: 0, yaw: yaw, pitch: pitch, roll: 0, faceCenter: CGPoint(x: 0.5, y: 0.5),
                                 faceSize: size, eyeOffset: .zero, confidence: 1), target: t, weight: 1)
            _ = rng.next()
        } } } }
        XCTAssertTrue(m.fit())
    }

    func testProfilesSwitchWithArrangement() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glance-prof-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let home = FakeGaze.both
        let office = [Displays.Info(id: 9, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        var current = home
        let m = RegressionGazeMapper(url: url, displays: { current })
        train(m, displays: home)
        XCTAssertTrue(m.isCalibrated)

        current = office
        XCTAssertFalse(m.isCalibrated, "no profile for the office arrangement yet")
        train(m, displays: office)
        XCTAssertTrue(m.isCalibrated)
        XCTAssertEqual(m.profileCount, 2)
        try m.save()

        // Fresh mapper: load picks the profile for whatever is plugged in now.
        let m2 = RegressionGazeMapper(url: url, displays: { current })
        try m2.load(); XCTAssertTrue(m2.isCalibrated)
        current = home
        XCTAssertTrue(m2.isCalibrated, "home profile restored automatically")
        current = [Displays.Info(id: 77, frame: CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertFalse(m2.isCalibrated)

        // reset() clears only the current arrangement's profile.
        current = office
        m2.reset(); XCTAssertFalse(m2.isCalibrated)
        current = home
        XCTAssertTrue(m2.isCalibrated)
        try m2.save()
        let m3 = RegressionGazeMapper(url: url, displays: { office })
        try m3.load(); XCTAssertFalse(m3.isCalibrated)
    }

    func testV1FileMigrates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glance-v1-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let m = RegressionGazeMapper(url: url, displays: { FakeGaze.both })
        train(m, displays: FakeGaze.both)
        try m.save()
        // Rewrite the saved profile in the old single-calibration layout.
        let blob = try JSONDecoder().decode(RegressionGazeMapper.Persisted.self, from: Data(contentsOf: url))
        let prof = blob.profiles.values.first!
        var old = RegressionGazeMapper.Persisted(profiles: [:])
        old.version = 1; old.arrangement = prof.arrangement; old.samples = prof.samples; old.model = prof.model
        try JSONEncoder().encode(old).write(to: url)
        let m2 = RegressionGazeMapper(url: url, displays: { FakeGaze.both })
        try m2.load(); XCTAssertTrue(m2.isCalibrated)
    }
}

final class CalibrationPlanTests: XCTestCase {
    func testStepsAdaptToDisplays() {
        let one = CalibrationController.makePlans(displays: [FakeGaze.A])
        let s1 = CalibrationController.makeSteps(for: one[0])
        XCTAssertEqual(s1.count, 5 + 9)      // 5 range prompts + 3x3 grid, no shared edges
        XCTAssertTrue(s1.allSatisfy { FakeGaze.A.frame.contains($0.target) })

        let two = CalibrationController.makePlans(displays: FakeGaze.both)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two[0].points.count, 9 + 3)   // extra points on the shared edge
        // Edge points of display A sit near its right (shared) edge.
        XCTAssertTrue(two[0].points.suffix(3).allSatisfy { $0.x > 2400 && $0.x < 2560 })

        // Laptop below an external monitor (vertical neighbour).
        let ext = Displays.Info(id: 5, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let lap = Displays.Info(id: 6, frame: CGRect(x: 500, y: 1440, width: 1440, height: 900))
        let plans = CalibrationController.makePlans(displays: [ext, lap])
        XCTAssertEqual(plans.map { $0.points.count }, [12, 12])
        for p in plans { for s in CalibrationController.makeSteps(for: p) { XCTAssertTrue(p.display.frame.contains(s.target)) } }
    }
}


/// Looking down at the keyboard must never read as the other (lower / side) display.
final class CalibrationKeyboardTests: XCTestCase {
    func testLookingDownNeverSwitchesDisplay() {
        let (m, _) = FakeGaze.mapper()
        var rng = SplitMix(s: 5)
        for d in FakeGaze.both {
            for gx in 0..<5 {
                let x = d.frame.minX + d.frame.width * (0.1 + 0.8 * Double(gx) / 4)
                for dy in [2000.0, 2500.0, 3500.0] {      // far below the lowest calibrated row
                    let p = FakeGaze.pose(for: CGPoint(x: x, y: dy), size: 0.3, rng: &rng)
                    // yaw is as on display d and the user is working there: never jump to the other one
                    let e = m.estimate(p, currentDisplay: d.id, edgeBias: 0.5, displays: FakeGaze.both)
                    XCTAssertTrue(e?.displayID == nil || e?.displayID == d.id, "x=\(x) y=\(dy) d=\(d.id)")
                    XCTAssertNil(e?.displayID, "below the pitch floor is off-screen")
                }
            }
        }
    }

    func testPitchDoesNotChangeLeftRight() {
        let (m, _) = FakeGaze.mapper()
        var rng = SplitMix(s: 6)
        for x in [1000.0, 1800.0, 3400.0, 4200.0] {
            let want: DisplayID = x < 2560 ? 1 : 2
            for y in [300.0, 700.0, 1100.0] {   // within the calibrated pitch range
                let e = m.estimate(FakeGaze.pose(for: CGPoint(x: x, y: y), size: 0.3, rng: &rng), currentDisplay: nil, edgeBias: 0.5, displays: FakeGaze.both)
                XCTAssertEqual(e?.displayID, want, "x=\(x) y=\(y)")
            }
        }
    }

    func testClassifierRoundTripsThroughPersistence() throws {
        let (m, url) = FakeGaze.mapper()
        try m.save()
        let m2 = RegressionGazeMapper(url: url, displays: { FakeGaze.both })
        try m2.load()
        var rng = SplitMix(s: 8)
        let p = FakeGaze.pose(for: CGPoint(x: 1000, y: 3000), size: 0.3, rng: &rng)
        XCTAssertNil(m2.estimate(p, currentDisplay: 2, edgeBias: 0.5, displays: FakeGaze.both)?.displayID)
        let q = FakeGaze.pose(for: CGPoint(x: 1000, y: 700), size: 0.3, rng: &rng)
        XCTAssertEqual(m2.estimate(q, currentDisplay: 1, edgeBias: 0.5, displays: FakeGaze.both)?.displayID, 1)
    }
}
