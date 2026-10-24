import XCTest
@testable import GlanceKit

final class SmokeTests: XCTestCase {
    func testFeatureVectorOrder() {
        let p = HeadPose(timestamp: 0, yaw: 1, pitch: 2, roll: 8, faceCenter: CGPoint(x: 3, y: 4),
                         faceSize: 5, eyeOffset: CGVector(dx: 6, dy: 7), confidence: 1)
        XCTAssertEqual(p.features, [1, 2, 3, 4, 5, 6, 7, 8])
    }
}
