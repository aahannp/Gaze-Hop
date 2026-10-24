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

    // MARK: Smoothing

    func testSmootherConvergesWithoutOvershoot() {
        var cur = FaceAngles()
        var target = FaceAngles(); target.yaw = 0.8; target.openness = 0
        var last = 0.0
        for _ in 0..<120 {                       // 2 s at 60 fps
            cur = FaceSmoother.step(cur, toward: target, dt: 1.0 / 60)
            XCTAssertGreaterThanOrEqual(cur.yaw, last); XCTAssertLessThanOrEqual(cur.yaw, 0.8)
            last = cur.yaw
        }
        XCTAssertEqual(cur.yaw, 0.8, accuracy: 1e-3)
        XCTAssertEqual(cur.openness, 0, accuracy: 1e-3)
    }

    func testBlinkIsFasterThanHeadMotion() {
        var target = FaceAngles(); target.yaw = 1; target.openness = 0
        let a = FaceSmoother.step(FaceAngles(), toward: target, dt: 1.0 / 60)
        XCTAssertGreaterThan(1 - a.openness, a.yaw)
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

    // MARK: Offscreen snapshots

    private var outDir: URL {
        let dir = ProcessInfo.processInfo.environment["GLANCE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("glance-live-face")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func png(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { throw XCTSkip("no png") }
        try data.write(to: url)
    }

    func testRenderFaceSnapshots() throws {
        let rig = FaceRig()
        let size = CGSize(width: 420, height: 480)
        let cases: [(String, HeadPose?)] = [
            ("neutral", pose()),
            ("yaw-right", pose(yaw: 0.55)),
            ("pitch-up-roll", pose(pitch: 0.4, roll: 0.3)),
            ("eyes-right-up", pose(eye: CGVector(dx: 0.9, dy: 0.6))),
            ("blink", pose(open: 0)),
            ("lean-close", pose(yaw: -0.3, center: CGPoint(x: 0.35, y: 0.55), size: 0.42)),
        ]
        var images: [NSImage] = []
        for (name, p) in cases {
            guard let img = rig.snapshot(size: size, angles: FaceMapping.angles(from: p)) else { throw XCTSkip("no Metal device") }
            XCTAssertGreaterThan(img.size.width, 0)
            try png(img, to: outDir.appendingPathComponent("face-\(name).png"))
            images.append(img)
        }
        // Contact sheet: 3 x 2.
        let sheet = NSImage(size: CGSize(width: size.width * 3, height: size.height * 2))
        sheet.lockFocus()
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill(); NSRect(origin: .zero, size: sheet.size).fill()
        for (i, img) in images.enumerated() {
            let col = i % 3, row = 1 - i / 3
            img.draw(in: NSRect(x: CGFloat(col) * size.width, y: CGFloat(row) * size.height, width: size.width, height: size.height))
        }
        sheet.unlockFocus()
        try png(sheet, to: outDir.appendingPathComponent("face-sheet.png"))
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

    // MARK: Mini-map snapshot (SwiftUI Canvas, offscreen)

    @MainActor func testRenderMiniMapSnapshot() throws {
        let model = LiveFaceModel(hub: PoseHub())
        model.displays = [Displays.Info(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440)),
                          Displays.Info(id: 2, frame: CGRect(x: -1512, y: 600, width: 1512, height: 982))]
        model.estimate = GazeEstimate(point: CGPoint(x: 1400, y: 500), displayID: 1, confidence: 0.84)
        model.currentDisplay = 1
        model.signals = FaceMapping.Signals(headX: 0.45, headY: -0.2, eyeX: 0.7, eyeY: 0.1)
        model.mode = .both
        let view = VStack(spacing: 10) {
            MiniMapView(model: model).frame(height: 150)
            VStack(spacing: 4) {
                SignalBar(title: "Head ↔", value: model.signals.headX, tint: .blue)
                SignalBar(title: "Eyes ↔", value: model.signals.eyeX, tint: .green)
                SignalBar(title: "Head ↕", value: model.signals.headY, tint: .blue.opacity(0.6))
                SignalBar(title: "Eyes ↕", value: model.signals.eyeY, tint: .green.opacity(0.6))
            }
        }.padding(14).frame(width: 380).background(Color.white)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage else { throw XCTSkip("no image") }
        try png(img, to: outDir.appendingPathComponent("minimap.png"))
    }
}
