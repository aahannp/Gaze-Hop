import XCTest
@testable import GlanceKit

final class CalibrationTrackerKindTests: XCTestCase {
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("kind-\(UUID()).json") }

    /// Train a mapper with the shared synthetic world (the mesh kind gets 4x eye dx, like the real tracker).
    private func train(_ m: RegressionGazeMapper, eyeScale: Double) {
        var rng = SplitMix(s: 2)
        for d in FakeGaze.both {
            for gx in 0..<4 { for gy in 0..<3 {
                let t = CGPoint(x: d.frame.minX + d.frame.width * (0.08 + 0.84 * Double(gx) / 3),
                                y: d.frame.minY + d.frame.height * (0.1 + 0.8 * Double(gy) / 2))
                var p = FakeGaze.pose(for: t, size: 0.3, noise: 0.002, rng: &rng)
                p.eyeOffset.dx *= eyeScale
                m.addSample(p, target: t, weight: 1)
            } }
        }
        XCTAssertTrue(m.fit())
    }

    func testOldFileIsVisionAndMeshStartsEmpty() throws {
        let url = tmp()
        let old = RegressionGazeMapper(url: url, displays: { FakeGaze.both })
        train(old, eyeScale: 1)
        try old.save()

        let m = RegressionGazeMapper(url: url, displays: { FakeGaze.both })
        try m.load()
        XCTAssertEqual(m.trackerKind, "vision")
        XCTAssertTrue(m.isCalibrated)
        let n = m.sampleCount
        XCTAssertGreaterThan(n, 0)

        m.trackerKind = "mesh"
        XCTAssertFalse(m.isCalibrated)
        XCTAssertEqual(m.sampleCount, 0)
        var rng = SplitMix(s: 1)
        XCTAssertNil(m.estimate(FakeGaze.pose(for: CGPoint(x: 1000, y: 700), size: 0.3, rng: &rng), currentDisplay: nil,
                                edgeBias: 0.5, displays: FakeGaze.both))

        m.trackerKind = "vision"
        XCTAssertTrue(m.isCalibrated)
        XCTAssertEqual(m.sampleCount, n)
    }

    func testSwitchingBackAndForthKeepsBoth() throws {
        let url = tmp()
        let m = RegressionGazeMapper(url: url, displays: { FakeGaze.both })
        train(m, eyeScale: 1)
        let vision = m.sampleCount
        m.trackerKind = "mesh"
        train(m, eyeScale: 4)
        let mesh = m.sampleCount
        XCTAssertEqual(mesh, vision)
        m.reset()                              // clears only the mesh profile
        XCTAssertFalse(m.isCalibrated)
        train(m, eyeScale: 4)
        for _ in 0..<3 { m.trackerKind = "vision"; XCTAssertTrue(m.isCalibrated); m.trackerKind = "mesh"; XCTAssertTrue(m.isCalibrated) }
        try m.save()

        let m2 = RegressionGazeMapper(url: url, displays: { FakeGaze.both })
        try m2.load()
        XCTAssertTrue(m2.isCalibrated); XCTAssertEqual(m2.sampleCount, vision)         // vision (default kind)
        m2.trackerKind = "mesh"
        XCTAssertTrue(m2.isCalibrated); XCTAssertEqual(m2.sampleCount, mesh)
        XCTAssertEqual(m2.profileCount, 2)
    }

    func testClicksAndDriftOnlyTouchActiveKind() {
        let m = RegressionGazeMapper(url: tmp(), displays: { FakeGaze.both })
        train(m, eyeScale: 1)
        let vision = m.sampleCount
        m.trackerKind = "mesh"
        train(m, eyeScale: 4)
        var rng = SplitMix(s: 1)
        for i in 0..<12 {
            m.addSample(FakeGaze.pose(for: CGPoint(x: 800 + Double(i), y: 700), size: 0.3, rng: &rng), target: CGPoint(x: 800, y: 700), weight: 0.3)
            m.recordClickOutcome(predicted: 2, actual: 1)
        }
        XCTAssertGreaterThan(m.driftScore, 0)
        m.trackerKind = "vision"
        XCTAssertEqual(m.sampleCount, vision)   // vision profile untouched by mesh clicks
        XCTAssertEqual(m.driftScore, 0)
    }
}
