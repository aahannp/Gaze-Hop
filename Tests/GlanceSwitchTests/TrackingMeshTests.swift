import XCTest
@testable import GlanceKit

final class TrackingMeshTests: XCTestCase {
    /// Frontal synthetic face in pixel space: eyes level, chin below forehead, iris centered.
    private func face(irisDX: Double = 0, lid: Double = 6) -> [SIMD3<Double>] {
        var p = [SIMD3<Double>](repeating: SIMD3(100, 100, 0), count: 478)
        p[33] = SIMD3(70, 90, 0);  p[133] = SIMD3(90, 90, 0)     // person's right eye (image-left)
        p[362] = SIMD3(110, 90, 0); p[263] = SIMD3(130, 90, 0)
        p[159] = SIMD3(80, 90 - lid / 2, 0); p[145] = SIMD3(80, 90 + lid / 2, 0)
        p[386] = SIMD3(120, 90 - lid / 2, 0); p[374] = SIMD3(120, 90 + lid / 2, 0)
        p[468] = SIMD3(80 + irisDX, 90, 0); p[473] = SIMD3(120 + irisDX, 90, 0)
        p[10] = SIMD3(100, 40, 0); p[152] = SIMD3(100, 160, 0)
        return p
    }
    private func ch(_ p: [SIMD3<Double>]) -> (v: [Double], open: Double) {
        MeshPoseEstimator.channels(pts: p, w: 200, h: 200, bbox: (60, 140, 40, 160))
    }

    func testFrontalFaceIsNeutral() {
        let c = ch(face())
        XCTAssertEqual(c.v[0], 0, accuracy: 0.01)
        XCTAssertEqual(c.v[1], 0, accuracy: 0.01)
        XCTAssertEqual(c.v[2], 0, accuracy: 0.01)
        XCTAssertEqual(c.v[6], 0, accuracy: 0.01)
        XCTAssertEqual(c.open, 1, accuracy: 0.01)
    }

    func testIrisImageRightMeansUsersLeft() {
        XCTAssertLessThan(ch(face(irisDX: 5)).v[6], -0.3)   // image-right = user's left = dx < 0
        XCTAssertGreaterThan(ch(face(irisDX: -5)).v[6], 0.3)
    }

    func testBlinkReportsLowOpennessAndNaNEye() {
        let c = ch(face(lid: 0.5))
        XCTAssertLessThan(c.open, 0.35)
        XCTAssertTrue(c.v[6].isNaN)
    }

    func testRollSign() {
        var p = face()
        // clockwise for the user = right ear to right shoulder: user's right eye (image-left, 33) goes lower
        p[33] = SIMD3(70, 95, 0); p[263] = SIMD3(130, 85, 0)
        XCTAssertGreaterThan(ch(p).v[2], 0.05)
    }
}
