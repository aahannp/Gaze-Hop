import XCTest
@testable import GlanceKit

/// Synthetic head + eyes world: gaze offset from the desktop centre = 3000*yaw + 6000*eyeDx (same for y).
private enum EyeWorld {
    static let A = FakeGaze.A, B = FakeGaze.B, both = FakeGaze.both
    static let cx = 2560.0, cy = 720.0

    static func pose(yaw: Double, pitch: Double, ex: Double, ey: Double, size: Double = 0.3,
                     open: Double = 1, confidence: Double = 0.9) -> HeadPose {
        HeadPose(timestamp: 0, yaw: yaw, pitch: pitch, roll: 0.01,
                 faceCenter: CGPoint(x: 0.5 + yaw * 0.1, y: 0.5 - pitch * 0.1), faceSize: size,
                 eyeOffset: CGVector(dx: ex, dy: ey), confidence: confidence, eyeOpenness: open)
    }
    /// Head and eyes both turn towards `t`, each doing half of the work.
    static func headMoving(_ t: CGPoint, noise: Double, rng: UnsafeMutablePointer<SplitMix>? = nil) -> HeadPose {
        func n() -> Double { guard noise != 0, let rng else { return 0 }; return Double.random(in: -noise...noise, using: &rng.pointee) }
        let dx = Double(t.x) - cx, dy = Double(t.y) - cy
        return pose(yaw: 0.5 * dx / 3000 + n(), pitch: -0.5 * dy / 2000 + n(), ex: 0.5 * dx / 6000 + n(), ey: -0.5 * dy / 4000 + n())
    }
    /// Head fixed at a neutral spot, eyes do all the work.
    static func eyesOnly(_ t: CGPoint, noise: Double, rng: UnsafeMutablePointer<SplitMix>? = nil) -> HeadPose {
        func n() -> Double { guard noise != 0, let rng else { return 0 }; return Double.random(in: -noise...noise, using: &rng.pointee) }
        let dx = Double(t.x) - cx, dy = Double(t.y) - cy
        return pose(yaw: n(), pitch: n(), ex: dx / 6000 + n(), ey: -dy / 4000 + n())
    }

    static func targets(_ d: Displays.Info) -> [CGPoint] {
        var out: [CGPoint] = []
        for gx in 0..<4 { for gy in 0..<3 {
            out.append(CGPoint(x: d.frame.minX + d.frame.width * (0.08 + 0.84 * Double(gx) / 3),
                               y: d.frame.minY + d.frame.height * (0.1 + 0.8 * Double(gy) / 2)))
        } }
        return out
    }

    static func mapper(withEyes: Bool, url: URL? = nil) -> RegressionGazeMapper {
        let m = RegressionGazeMapper(url: url ?? FileManager.default.temporaryDirectory.appendingPathComponent("eyes-\(UUID()).json"),
                                     displays: { both })
        var rng = SplitMix(s: 11)
        for d in both {
            for t in targets(d) { m.addSample(headMoving(t, noise: 0.002, rng: &rng), target: t, weight: 1) }
            if withEyes { for t in targets(d) { m.addSample(eyesOnly(t, noise: 0.002, rng: &rng), target: t, weight: 1, eyesOnly: true) } }
        }
        XCTAssertTrue(m.fit())
        return m
    }
    static func est(_ m: RegressionGazeMapper, _ p: HeadPose, cur: DisplayID?, _ mode: GazeMode, weight: Double = 0.7) -> DisplayID? {
        m.gazeMode = mode; m.eyeWeight = weight
        return m.estimate(p, currentDisplay: cur, edgeBias: 0.5, displays: both)?.displayID
    }
}

final class CalibrationGazeModeTests: XCTestCase {
    func testOldProfileFallsBackToHead() {
        let m = EyeWorld.mapper(withEyes: false)
        XCTAssertTrue(m.isCalibrated)
        XCTAssertTrue(m.needsEyeCalibration)
        var rng = SplitMix(s: 3)
        for t in EyeWorld.targets(EyeWorld.A) + EyeWorld.targets(EyeWorld.B) {
            let p = EyeWorld.headMoving(t, noise: 0.002, rng: &rng)
            let head = EyeWorld.est(m, p, cur: nil, .head)
            XCTAssertEqual(EyeWorld.est(m, p, cur: nil, .eyes), head)
            XCTAssertEqual(EyeWorld.est(m, p, cur: nil, .both), head)
        }
    }

    func testEyesOnlySamplesEnableEyeModes() {
        let m = EyeWorld.mapper(withEyes: true)
        XCTAssertFalse(m.needsEyeCalibration)
        var rng = SplitMix(s: 4)
        var ok = 0, n = 0
        for d in EyeWorld.both {
            for t in EyeWorld.targets(d) {
                // Held-out-ish eyes-only glances: head still, eyes on the display.
                let p = EyeWorld.eyesOnly(CGPoint(x: t.x + 37, y: t.y - 21), noise: 0.003, rng: &rng)
                guard abs(Double(t.x) - 2560) > 512 else { continue }   // near-edge glances may be missed
                n += 1
                if EyeWorld.est(m, p, cur: d.id == 1 ? 2 : 1, .eyes) == d.id { ok += 1 }
            }
        }
        XCTAssertGreaterThan(Double(ok) / Double(n), 0.95)
    }

    func testModesDisagreeWhenHeadAndEyesDo() {
        let m = EyeWorld.mapper(withEyes: true)
        // Head turned to display A's centre, eyes looking at display B's centre.
        let head = EyeWorld.headMoving(CGPoint(x: 1280, y: 720), noise: 0)
        let eyes = EyeWorld.eyesOnly(CGPoint(x: 3840, y: 720), noise: 0)
        let p = EyeWorld.pose(yaw: head.yaw, pitch: head.pitch, ex: eyes.eyeOffset.dx, ey: eyes.eyeOffset.dy)
        XCTAssertEqual(EyeWorld.est(m, p, cur: nil, .head), 1)
        XCTAssertEqual(EyeWorld.est(m, p, cur: nil, .eyes), 2)
        XCTAssertEqual(EyeWorld.est(m, p, cur: nil, .both, weight: 0.95), 2)
        XCTAssertEqual(EyeWorld.est(m, p, cur: nil, .both, weight: 0.05), 1)
    }

    func testBlinkNeverSwitches() {
        let m = EyeWorld.mapper(withEyes: true)
        let onA = EyeWorld.eyesOnly(CGPoint(x: 1280, y: 720), noise: 0)
        XCTAssertEqual(EyeWorld.est(m, onA, cur: 1, .eyes), 1)       // last good eye value: display A
        // Blink: junk eye values that would read as display B must not move focus.
        let junk = EyeWorld.pose(yaw: onA.yaw, pitch: onA.pitch, ex: 0.4, ey: 0, open: 0.05)
        XCTAssertNotEqual(EyeWorld.est(m, junk, cur: 1, .eyes), 2)
        XCTAssertNotEqual(EyeWorld.est(m, junk, cur: 1, .both), 2)
        // Blink with no earlier eye value at all.
        let fresh = EyeWorld.mapper(withEyes: true)
        XCTAssertNotEqual(EyeWorld.est(fresh, junk, cur: 1, .eyes), 2)
    }

    func testLookingDownStillOffscreenInEveryMode() {
        let m = EyeWorld.mapper(withEyes: true)
        for mode in GazeMode.allCases {
            for x in [1280.0, 3840.0] {
                let d = x < 2560 ? 1 : 2
                let t = CGPoint(x: x, y: 720)
                var p = EyeWorld.headMoving(t, noise: 0)
                p.pitch -= 0.8; p.faceCenter.y += 0.08
                XCTAssertNil(EyeWorld.est(m, p, cur: DisplayID(d), mode), "\(mode) x=\(x)")
            }
        }
    }

    func testPersistenceKeepsEyeProfile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eyes-persist-\(UUID()).json")
        let m = EyeWorld.mapper(withEyes: true, url: url)
        try m.save()
        let m2 = RegressionGazeMapper(url: url, displays: { EyeWorld.both })
        try m2.load()
        XCTAssertTrue(m2.isCalibrated); XCTAssertFalse(m2.needsEyeCalibration)
        let p = EyeWorld.eyesOnly(CGPoint(x: 3840, y: 720), noise: 0)
        XCTAssertEqual(EyeWorld.est(m2, p, cur: 1, .eyes), 2)
    }

    func testProfileSavedBeforeGazeModesStillWorks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eyes-old-\(UUID()).json")
        let m = EyeWorld.mapper(withEyes: false, url: url)
        try m.save()
        // Strip everything the new version added, like a file written by the old app.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var profiles = try XCTUnwrap(root["profiles"] as? [String: Any])
        for (k, v) in profiles {
            var prof = try XCTUnwrap(v as? [String: Any])
            prof.removeValue(forKey: "eyeModel"); prof.removeValue(forKey: "eyeClassifier"); prof.removeValue(forKey: "classifier")
            var model = try XCTUnwrap(prof["model"] as? [String: Any]); model.removeValue(forKey: "columns"); prof["model"] = model
            prof["samples"] = (prof["samples"] as? [[String: Any]])?.map { var s = $0; s.removeValue(forKey: "eyes"); return s }
            profiles[k] = prof
        }
        root["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        let m2 = RegressionGazeMapper(url: url, displays: { EyeWorld.both })
        try m2.load()
        XCTAssertTrue(m2.isCalibrated)
        XCTAssertTrue(m2.needsEyeCalibration)
        let p = EyeWorld.headMoving(CGPoint(x: 3840, y: 720), noise: 0)
        for mode in GazeMode.allCases { XCTAssertEqual(EyeWorld.est(m2, p, cur: 1, mode), 2, "\(mode)") }
    }

    func testEyeStepsStayOnDisplayAndComeLast() {
        let plans = CalibrationController.makePlans(displays: EyeWorld.both)
        let steps = CalibrationController.allSteps(for: plans)
        let firstEye = try! XCTUnwrap(steps.firstIndex { $0.kind == .eyeDot })
        XCTAssertTrue(steps[firstEye...].allSatisfy { $0.kind == .eyeDot })
        XCTAssertTrue(steps[..<firstEye].allSatisfy { $0.kind != .eyeDot })
        for d in EyeWorld.both {
            let mine = steps.filter { $0.kind == .eyeDot && $0.display.id == d.id }
            XCTAssertGreaterThanOrEqual(mine.count, RegressionGazeMapper.minEyeSamplesPerDisplay)
            XCTAssertTrue(mine.allSatisfy { d.frame.contains($0.target) })
        }
    }
}
