import XCTest
@testable import GlanceKit

/// Mesh eye feature on a synthetic 3D head: eyeballs that rotate inside a rigid face, posed by head
/// yaw/pitch and projected into pixel space the way the mesh model reports landmarks (x, y in pixels,
/// z scaled like x). The eye channel must follow the eyes and ignore the head.
final class TrackingEyeFeatureTests: XCTestCase {
    /// Face frame in mm: x image-right, y down, z away from the camera (into the head).
    struct Head {
        var yaw = 0.0, pitch = 0.0            // head, contract signs (+ = user's right / up)
        var eyeYaw = 0.0, eyePitch = 0.0      // eye-in-head rotation, same signs
        var lid = 10.0                        // lid gap, mm (0 = closed)
        var lidsFollow = true                 // upper lid rides with vertical gaze, as real lids do

        func points() -> [SIMD3<Double>] {
            var p = [SIMD3<Double>](repeating: SIMD3(0, 0, 20), count: 478)
            func eye(side: Double, outer: Int, inner: Int, iris: Int, up: Int, low: Int) {
                let c = SIMD3(32 * side, 0, 13)                     // rotation centre
                p[outer] = SIMD3(46 * side, 1, 11); p[inner] = SIMD3(18 * side, 0, 5)
                // User's right = image-left (-x); up = -y; toward the camera = -z.
                let d = SIMD3(-sin(eyeYaw) * cos(eyePitch), -sin(eyePitch), -cos(eyeYaw) * cos(eyePitch))
                let ic = c + 10.5 * d
                let ex = SIMD3(cos(eyeYaw), 0, -sin(eyeYaw)), ey = SIMD3(0, 1.0, 0)
                p[iris] = ic
                for (k, o) in [ex * 6, ey * 6, ex * -6, ey * -6].enumerated() { p[iris + 1 + k] = ic + o }
                let lidShift = lidsFollow ? -10.5 * sin(eyePitch) * 0.6 : 0
                p[up] = SIMD3(32 * side, -lid / 2 + lidShift, 2); p[low] = SIMD3(32 * side, lid / 2, 3)
            }
            eye(side: -1, outer: 33, inner: 133, iris: 468, up: 159, low: 145)    // person's right = image-left
            eye(side: 1, outer: 263, inner: 362, iris: 473, up: 386, low: 374)
            p[10] = SIMD3(0, -75, 8); p[152] = SIMD3(0, 75, 8)
            // Head pose about a pivot behind the face. Yaw + (user's right) swings the nose to image-left.
            let pivot = SIMD3(0.0, 0, 90)
            let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
            return p.map { q in
                var v = q - pivot
                v = SIMD3(v.x, cp * v.y + sp * v.z, -sp * v.y + cp * v.z)     // pitch + = chin forward/up
                v = SIMD3(cy * v.x + sy * v.z, v.y, -sy * v.x + cy * v.z)
                v += pivot
                return SIMD3(640 + 2.2 * v.x, 360 + 2.2 * v.y, 2.2 * v.z)    // ~2.2 px/mm at laptop distance
            }
        }
    }

    static func channels(_ h: Head) -> (v: [Double], open: Double) {
        let p = h.points()
        let xs = p[0..<468].map(\.x), ys = p[0..<468].map(\.y)
        return MeshPoseEstimator.channels(pts: p, w: 1280, h: 720, bbox: (xs.min()!, xs.max()!, ys.min()!, ys.max()!))
    }
    static func eye(_ h: Head) -> (dx: Double, dy: Double) { let v = channels(h).v; return (v[6], v[7]) }

    func testHeadPoseOfTheSyntheticHead() {
        let v = Self.channels(Head(yaw: 0.3, pitch: 0.2)).v
        XCTAssertEqual(v[0], 0.3, accuracy: 0.02)
        XCTAssertEqual(v[1], 0.2, accuracy: 0.02)
    }

    /// Eyes rotate with the head still: the channel tracks eye angle (±1 at `eyeFullScale`), both signs.
    func testFollowsEyeYawWithHeadStill() {
        let deg = Double.pi / 180
        var out: [(Double, Double)] = []
        for a in stride(from: -25.0, through: 25.0, by: 5) { out.append((a, Self.eye(Head(eyeYaw: a * deg)).dx)) }
        print("EYE yaw gain: " + out.map { String(format: "%+.0f°→%+.2f", $0.0, $0.1) }.joined(separator: " "))
        for (a, dx) in out { XCTAssertEqual(dx, a * deg / MeshPoseEstimator.eyeFullScale, accuracy: 0.06) }
        let span = out.last!.1 - out.first!.1
        XCTAssertGreaterThan(span, 1.4)             // ±25° of eye fills most of -1...1
    }

    func testFollowsEyePitchWithHeadStill() {
        let deg = Double.pi / 180
        let up = Self.eye(Head(eyePitch: 15 * deg)).dy, down = Self.eye(Head(eyePitch: -15 * deg)).dy
        let rest = Self.eye(Head()).dy
        print(String(format: "EYE pitch: down %+.2f rest %+.2f up %+.2f", down, rest, up))
        XCTAssertEqual(up - rest, 15 * deg / MeshPoseEstimator.eyeFullScale, accuracy: 0.08)
        XCTAssertEqual(rest - down, 15 * deg / MeshPoseEstimator.eyeFullScale, accuracy: 0.08)
    }

    /// Head turns with the eyes fixed in the head: the eye channel must not move.
    func testHeadTurnDoesNotLeakIntoEyes() {
        let deg = Double.pi / 180
        let rest = Self.eye(Head())
        var worstX = 0.0, worstY = 0.0
        for y in stride(from: -30.0, through: 30.0, by: 10) {
            for p in stride(from: -15.0, through: 15.0, by: 15) {
                let e = Self.eye(Head(yaw: y * deg, pitch: p * deg))
                worstX = max(worstX, abs(e.dx - rest.dx)); worstY = max(worstY, abs(e.dy - rest.dy))
            }
        }
        let gain = Self.eye(Head(eyeYaw: 20 * deg)).dx - rest.dx
        print(String(format: "HEAD LEAK (head ±30° yaw, ±15° pitch, eyes fixed): dx %.3f dy %.3f; 20° eye turn = %.3f",
                     worstX, worstY, gain))
        XCTAssertLessThan(worstX, 0.03)
        XCTAssertLessThan(worstY, 0.03)
    }

    /// Looking at a side display with head and eyes both turned: the channel reports only the eyes.
    func testCombinedHeadAndEyes() {
        let deg = Double.pi / 180
        let e = Self.eye(Head(yaw: 20 * deg, eyeYaw: 10 * deg)).dx - Self.eye(Head()).dx
        XCTAssertEqual(e, 10 * deg / MeshPoseEstimator.eyeFullScale, accuracy: 0.05)
    }

    func testBlinkGivesNaN() {
        let c = Self.channels(Head(lid: 0.5))
        XCTAssertLessThan(c.open, MeshPoseEstimator.blinkThreshold)
        XCTAssertTrue(c.v[6].isNaN)
    }

    /// One eye half shut (a wink, or a lid occluding at an angle): the open eye carries the reading.
    func testOpennessWeightsTheEyes() {
        let deg = Double.pi / 180
        let h = Head(eyeYaw: 15 * deg)
        let both = Self.eye(h).dx
        var p = h.points()
        p[159] = p[145] - SIMD3(0, 1, 0)                      // person's right eye nearly closed
        p[468] += SIMD3(30, 0, 0); for i in 469...472 { p[i] += SIMD3(30, 0, 0) }  // ...and its iris is garbage
        let xs = p[0..<468].map(\.x), ys = p[0..<468].map(\.y)
        let one = MeshPoseEstimator.channels(pts: p, w: 1280, h: 720, bbox: (xs.min()!, xs.max()!, ys.min()!, ys.max()!)).v[6]
        XCTAssertEqual(one, both, accuracy: 0.05)
    }
}
