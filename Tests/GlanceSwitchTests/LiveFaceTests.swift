import XCTest
import AppKit
import SwiftUI
@testable import GlanceKit

final class LiveFaceTests: XCTestCase {
    private func pose(yaw: Double = 0, pitch: Double = 0, roll: Double = 0, eye: CGVector = .zero,
                      open: Double = 1, center: CGPoint = CGPoint(x: 0.5, y: 0.5), size: Double = 0.3) -> HeadPose {
        HeadPose(timestamp: 0, yaw: yaw, pitch: pitch, roll: roll, faceCenter: center, faceSize: size,
                 eyeOffset: eye, confidence: 1, eyeOpenness: open)
    }

    // MARK: Pose -> face angles

    func testNoFaceGivesNeutralFace() {
        XCTAssertEqual(FaceMapping.angles(from: nil), FaceAngles())
    }

    func testAnglesFollowPoseAndClamp() {
        let a = FaceMapping.angles(from: pose(yaw: 0.4, pitch: -0.2, roll: 0.1))
        XCTAssertEqual(a.yaw, 0.4, accuracy: 1e-9)
        XCTAssertEqual(a.pitch, -0.2, accuracy: 1e-9)
        XCTAssertEqual(a.roll, 0.1, accuracy: 1e-9)
        let b = FaceMapping.angles(from: pose(yaw: 5, pitch: -5, roll: 5))
        XCTAssertEqual(b.yaw, FaceMapping.maxYaw)
        XCTAssertEqual(b.pitch, -FaceMapping.maxPitch)
        XCTAssertEqual(b.roll, FaceMapping.maxRoll)
    }

    func testEyesAndLidsFollowPose() {
        let a = FaceMapping.angles(from: pose(eye: CGVector(dx: 0.5, dy: -1), open: 0.2))
        XCTAssertEqual(a.eyeYaw, 0.5 * FaceMapping.maxEyeYaw, accuracy: 1e-9)   // + = user's right
        XCTAssertEqual(a.eyePitch, -FaceMapping.maxEyePitch, accuracy: 1e-9)     // + = up
        XCTAssertEqual(a.openness, 0.2, accuracy: 1e-9)
    }

    func testLeanAndDistanceAreSubtle() {
        let near = FaceMapping.angles(from: pose(center: CGPoint(x: 0.7, y: 0.4), size: 0.45))
        XCTAssertGreaterThan(near.leanX, 0)        // user's right
        XCTAssertGreaterThan(near.leanY, 0)        // frame y grows down, so up in the scene
        XCTAssertGreaterThan(near.scale, 1)
        XCTAssertLessThan(near.scale, 1.25)
        let far = FaceMapping.angles(from: pose(size: 0.15))
        XCTAssertLessThan(far.scale, 1)
        XCTAssertGreaterThan(far.scale, 0.75)
    }

    func testSignalsAreNormalised() {
        let s = FaceMapping.signals(from: pose(yaw: 0.3, pitch: -2, eye: CGVector(dx: -0.5, dy: 3)))
        XCTAssertEqual(s.headX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.headY, -1)
        XCTAssertEqual(s.eyeX, -0.5, accuracy: 1e-9)
        XCTAssertEqual(s.eyeY, 1)
        XCTAssertEqual(FaceMapping.signals(from: nil), FaceMapping.Signals())
    }

    // MARK: Mini-map

    func testMiniMapDrawsDisplaysToScale() {
        let ds = [Displays.Info(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                  Displays.Info(id: 2, frame: CGRect(x: 1000, y: 0, width: 2000, height: 800))]
        let m = MiniMapLayout(displays: ds, size: CGSize(width: 324, height: 224), padding: 12)
        XCTAssertEqual(m.scale, 0.1, accuracy: 1e-9)                      // 300 px wide for 3000 pt
        let r1 = m.rect(of: ds[0]), r2 = m.rect(of: ds[1])
        XCTAssertEqual(r1.width * 2, r2.width, accuracy: 1e-9)
        XCTAssertEqual(r1.maxX, r2.minX, accuracy: 1e-9)
        XCTAssertEqual(r1.minX, 12, accuracy: 1e-9)
        let p = m.point(CGPoint(x: 1500, y: 400))
        XCTAssertTrue(r2.contains(p))
        let off = m.point(CGPoint(x: 9000, y: -5000), clampedTo: CGRect(x: 0, y: 0, width: 324, height: 224))
        XCTAssertEqual(off.x, 324); XCTAssertEqual(off.y, 0)
    }

    func testMiniMapDrawsTheRealArrangementExactly() {
        // MacBook to the left of the external, tops aligned (CG coordinates, y down).
        let ext = Displays.Info(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let lap = Displays.Info(id: 2, frame: CGRect(x: -1470, y: 0, width: 1470, height: 956))
        let m = MiniMapLayout(displays: [ext, lap], size: CGSize(width: 380, height: 200), padding: 12)
        let re = m.rect(of: ext), rl = m.rect(of: lap)
        XCTAssertEqual(rl.minY, re.minY, accuracy: 1e-9)                      // tops aligned
        XCTAssertEqual(rl.maxX, re.minX, accuracy: 1e-9)                      // laptop touches the external's left edge
        XCTAssertEqual(rl.width / re.width, 1470.0 / 2560.0, accuracy: 1e-9)  // same scale on both
        XCTAssertEqual(rl.height / re.height, 956.0 / 1440.0, accuracy: 1e-9)
        XCTAssertEqual(m.point(CGPoint(x: 0, y: 0)).x, re.minX, accuracy: 1e-9)
    }

    // MARK: Settings

    func testRealOldSettingsJSONStillDecodesWithItsValues() throws {
        // What a pre-gazeMode build saved for the user (no gazeMode / eyeWeight keys).
        let json = """
        {"switchDelayMs":250,"headTurnThreshold":0.5,"windowFocusEnabled":true,"paneDelayMs":300,
         "typingProtection":true,"typingPauseSec":0.8,"mousePriorityMs":600,"movePointer":true,
         "showGazeDot":false,"learnFromClicks":true,"paneClickFallback":true,"paused":false}
        """
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.switchDelayMs, 250)
        XCTAssertEqual(s.typingPauseSec, 0.8)
        XCTAssertEqual(s.gazeMode, .both)
        XCTAssertEqual(s.eyeWeight, 0.7)
    }

    func testStoreLoadsOldJSONAndKeepsValues() throws {
        let d = UserDefaults(suiteName: "glance.test.\(UUID().uuidString)")!
        d.set(Data(#"{"switchDelayMs":250,"typingPauseSec":0.8}"#.utf8), forKey: SettingsStore.key)
        let store = SettingsStore(defaults: d)
        XCTAssertEqual(store.settings.switchDelayMs, 250)
        XCTAssertEqual(store.settings.typingPauseSec, 0.8)
        store.settings.gazeMode = .eyes
        XCTAssertEqual(SettingsStore(defaults: d).settings.gazeMode, .eyes)
    }

    // MARK: Mode sync

    private final class StubMapper: GazeMapper {
        var isCalibrated = true; var driftScore = 0.0
        var gazeMode: GazeMode = .both; var eyeWeight = 0.7
        func estimate(_ pose: HeadPose, currentDisplay: DisplayID?, edgeBias: Double) -> GazeEstimate? { nil }
        func addSample(_ pose: HeadPose, target: CGPoint, weight: Double) {}
        func fit() -> Bool { true }
        func reset() {}; func save() throws {}; func load() throws {}
        func recordClickOutcome(predicted: DisplayID?, actual: DisplayID) {}
    }

    func testSettingsSyncModeAndWeightToMapper() {
        let m = StubMapper()
        var s = Settings(); s.gazeMode = .eyes; s.eyeWeight = 0.35
        s.apply(to: m)
        XCTAssertEqual(m.gazeMode, .eyes)
        XCTAssertEqual(m.eyeWeight, 0.35)
        s.gazeMode = .head
        s.apply(to: m)
        XCTAssertEqual(m.gazeMode, .head)
    }

    // MARK: View model

    func testModelListensOnlyWhileVisible() {
        let hub = PoseHub(); let model = LiveFaceModel(hub: hub)
        hub.publish(pose(yaw: 0.2))
        XCTAssertNil(model.pose)                        // hidden: not subscribed
        var changes = 0
        model.onVisibilityChange = { changes += 1 }
        model.show(); model.show()                      // Settings tab + Live Face window
        hub.publish(pose(yaw: 0.5))
        XCTAssertEqual(model.target.get().yaw, 0.5, accuracy: 1e-9)
        model.hide()
        hub.publish(pose(yaw: -0.5))
        XCTAssertEqual(model.target.get().yaw, -0.5, accuracy: 1e-9)   // one view still showing
        model.hide()
        hub.publish(pose(yaw: 0.9))
        XCTAssertEqual(model.target.get().yaw, -0.5, accuracy: 1e-9)   // nobody watching: frozen
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(changes, 2)
    }

    func testModelHoldsEyesDuringBlink() {
        let model = LiveFaceModel(hub: PoseHub())
        let open = model.faceAngles(for: pose(eye: CGVector(dx: 0.6, dy: 0.2)))
        let blink = model.faceAngles(for: pose(eye: CGVector(dx: -1, dy: -1), open: 0.05))
        XCTAssertEqual(blink.eyeYaw, open.eyeYaw)
        XCTAssertEqual(blink.eyePitch, open.eyePitch)
        XCTAssertEqual(blink.openness, 0.05, accuracy: 1e-9)
    }

    func testModelIgnoresEngineStateWhileHidden() {
        let model = LiveFaceModel(hub: PoseHub())
        let est = GazeEstimate(point: CGPoint(x: 10, y: 10), displayID: 1, confidence: 0.8)
        let st = SwitchEngine.State(estimate: est, currentDisplay: 1, hold: nil, paused: false)
        model.update(state: st)
        XCTAssertNil(model.estimate)
        model.show(); model.update(state: st)
        XCTAssertEqual(model.estimate, est)
    }

    /// Camera-rate updates must not rebuild the SwiftUI tree: only real changes are published.
    func testModelPublishesOnlyWhenSomethingVisibleChanges() {
        let model = LiveFaceModel(hub: PoseHub())
        model.show()
        var publishes = 0
        let sub = model.objectWillChange.sink { publishes += 1 }
        defer { sub.cancel(); model.hide() }
        for i in 0..<45 {                                       // 3 s of tracking on one display
            model.ingest(pose(yaw: 0.01 * Double(i), eye: CGVector(dx: 0.3, dy: 0)))
            let est = GazeEstimate(point: CGPoint(x: 100 + i, y: 300), displayID: 1, confidence: 0.8)
            model.update(state: SwitchEngine.State(estimate: est, currentDisplay: 1, hold: nil, paused: false))
        }
        XCTAssertLessThanOrEqual(publishes, 3)                  // face appeared, gaze on display 1, focus on 1
        publishes = 0
        let other = GazeEstimate(point: CGPoint(x: -500, y: 300), displayID: 2, confidence: 0.8)
        model.update(state: SwitchEngine.State(estimate: other, currentDisplay: 1, hold: nil, paused: false))
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(model.gazeTarget, .display(2))
    }

    /// One dropped frame must not flash "No face"; a real loss shows after a short delay.
    func testBriefFaceLossDoesNotFlicker() {
        let model = LiveFaceModel(hub: PoseHub())
        model.show()
        defer { model.hide() }
        model.ingest(pose())
        XCTAssertTrue(model.faceVisible)
        model.ingest(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        model.ingest(pose())
        RunLoop.main.run(until: Date().addingTimeInterval(LiveFaceModel.lostDelay + 0.2))
        XCTAssertTrue(model.faceVisible)
        model.ingest(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(LiveFaceModel.lostDelay + 0.2))
        XCTAssertFalse(model.faceVisible)
        XCTAssertFalse(model.isIdle)                            // still easing to neutral
    }
}
