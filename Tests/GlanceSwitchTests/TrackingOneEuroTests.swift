import XCTest
@testable import GlanceKit

final class TrackingOneEuroTests: XCTestCase {
    func testFirstSamplePassesThrough() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.filter(3.5, at: 0), 3.5)
    }

    func testReducesJitterWhenStill() {
        var f = OneEuroFilter(minCutoff: 1.0, beta: 0.0)
        var out = [Double]()
        for i in 0..<150 { out.append(f.filter((i % 2 == 0 ? 1.0 : -1.0) * 0.5, at: Double(i) / 15)) }
        let tail = out.suffix(50)
        XCTAssertLessThan(tail.max()! - tail.min()!, 0.3)   // raw p-p is 1.0
    }

    func testFollowsStepAndConverges() {
        var f = OneEuroFilter(minCutoff: 1.0, beta: 5.0)
        _ = f.filter(0, at: 0)
        var v = 0.0
        for i in 1...60 { v = f.filter(10, at: Double(i) / 15) }
        XCTAssertEqual(v, 10, accuracy: 0.1)
    }

    func testBetaReducesLagOnFastMotion() {
        var slow = OneEuroFilter(minCutoff: 1.0, beta: 0.0)
        var fast = OneEuroFilter(minCutoff: 1.0, beta: 10.0)
        var s = 0.0, q = 0.0
        for i in 0..<30 { let x = Double(i) * 0.5; s = slow.filter(x, at: Double(i) / 15); q = fast.filter(x, at: Double(i) / 15) }
        XCTAssertGreaterThan(q, s)
    }

    func testResetForgetsHistory() {
        var f = OneEuroFilter()
        _ = f.filter(0, at: 0); _ = f.filter(0, at: 0.1)
        f.reset()
        XCTAssertEqual(f.filter(7, at: 1), 7)
    }

    func testTrackerStartStopWithoutCameraAccessIsSafe() {
        let t = CameraPoseTracker()
        t.stop(); t.stop()
        XCTAssertFalse(t.isRunning)
    }
}
