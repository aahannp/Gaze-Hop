import XCTest
import AppKit
import SwiftUI
@testable import GlanceKit

/// Review PNGs of the live view, rendered off-screen (no window is ever created or shown).
/// Run with GLANCE_SNAPSHOT_DIR=<dir> to write them; skipped otherwise.
final class LiveSnapshotTests: XCTestCase {
    override func setUp() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)   // no Dock icon, no activation
    }

    static let external = Displays.Info(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
    static let laptop = Displays.Info(id: 2, frame: CGRect(x: -1470, y: 0, width: 1470, height: 956))
    static let schemes: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    // MARK: Face poses

    func testRenderFacePoses() throws {
        guard let dir = SnapshotDir.url else { throw XCTSkip("Set GLANCE_SNAPSHOT_DIR=<dir> to render") }
        let rig = FaceRig()
        let cell = CGSize(width: 220, height: 250)
        func pose(_ f: (inout FaceAngles) -> Void) -> FaceAngles { var a = FaceAngles(); f(&a); return a }
        let poses: [(String, FaceAngles, Double)] = [
            ("neutral", pose { _ in }, 1),
            ("yaw left", pose { $0.yaw = -0.5 }, 1),
            ("yaw right", pose { $0.yaw = 0.5 }, 1),
            ("pitch up", pose { $0.pitch = 0.35 }, 1),
            ("pitch down", pose { $0.pitch = -0.3 }, 1),
            ("roll", pose { $0.roll = 0.3 }, 1),
            ("eyes left", pose { $0.eyeYaw = -0.45 }, 1),
            ("eyes right", pose { $0.eyeYaw = 0.45 }, 1),
            ("eyes up", pose { $0.eyePitch = 0.35 }, 1),
            ("blink", pose { $0.openness = 0 }, 1),
            ("face lost", pose { _ in }, 0),
        ]
        let images = try poses.map { name, a, presence -> (String, NSImage) in
            guard let img = rig.snapshot(size: CGSize(width: cell.width * 2, height: cell.height * 2), angles: a, presence: presence)
            else { throw XCTSkip("no Metal device") }
            return (name, img)
        }
        for (scheme, appearance) in Self.schemes {
            let cols = 4, rows = (images.count + cols - 1) / cols, label: CGFloat = 26
            let size = CGSize(width: cell.width * CGFloat(cols), height: (cell.height + label) * CGFloat(rows))
            let rep = try bitmap(size)
            try draw(into: rep, appearance: appearance) {
                NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: size).fill()
                for (i, (name, img)) in images.enumerated() {
                    let x = CGFloat(i % cols) * cell.width, top = size.height - CGFloat(i / cols) * (cell.height + label)
                    let card = NSRect(x: x + 8, y: top - cell.height - label + 8, width: cell.width - 16, height: cell.height + label - 16)
                    NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
                    NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
                    img.draw(in: NSRect(x: x, y: top - cell.height, width: cell.width, height: cell.height))
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                                .foregroundColor: NSColor.secondaryLabelColor]
                    let w = (name as NSString).size(withAttributes: attrs).width
                    (name as NSString).draw(at: CGPoint(x: x + (cell.width - w) / 2, y: top - cell.height - label + 10), withAttributes: attrs)
                }
            }
            try png(rep, to: dir.appendingPathComponent("face-poses-\(scheme).png"))
        }
    }

    // MARK: Panel

    enum State: String, CaseIterable { case tracking, offscreen, lost, uncalibrated }

    func testRenderPanel() throws {
        guard let dir = SnapshotDir.url else { throw XCTSkip("Set GLANCE_SNAPSHOT_DIR=<dir> to render") }
        let rig = FaceRig()
        guard rig.snapshot(size: CGSize(width: 8, height: 8), angles: FaceAngles()) != nil else { throw XCTSkip("no Metal device") }
        // Main window Overview row (wide) and the Live Face window (tall).
        let shapes: [(String, CGSize, NSColor, CGSize)] = [
            ("wide", CGSize(width: 546, height: 470), .controlBackgroundColor, CGSize(width: 217, height: 255)),
            ("tall", CGSize(width: 380, height: 640), .windowBackgroundColor, CGSize(width: 356, height: 295)),
        ]
        for state in State.allCases {
            let model = try prepare(state)
            defer { model.hide(); model.hide() }
            for (shape, size, background, card) in shapes {
                let face = rig.snapshot(size: CGSize(width: card.width * 2, height: card.height * 2),
                                        angles: model.motion.face.output, presence: model.motion.face.presence.value)
                for (scheme, appearance) in Self.schemes {
                    let view = LiveFacePanel(model: model, faceStandIn: face)
                        .frame(width: size.width, height: size.height)
                        .background(Color(nsColor: background))
                    try png(try host(view, size: size, appearance: appearance),
                            to: dir.appendingPathComponent("panel-\(shape)-\(state.rawValue)-\(scheme).png"))
                }
            }
        }
    }

    /// The real Overview pane with the panel in its Live View section.
    func testRenderOverview() throws {
        guard let dir = SnapshotDir.url else { throw XCTSkip("Set GLANCE_SNAPSHOT_DIR=<dir> to render") }
        let rig = FaceRig()
        guard let face = rig.snapshot(size: CGSize(width: 434, height: 510), angles: FaceAngles()) else { throw XCTSkip("no Metal device") }
        let model = try prepare(.tracking)
        defer { model.hide(); model.hide() }
        let standIn = rig.snapshot(size: CGSize(width: 434, height: 510), angles: model.motion.face.output) ?? face
        PaneHeaderBar.inWindow = false
        defer { PaneHeaderBar.inWindow = true }
        let defaults = UserDefaults(suiteName: "glance.live.snapshots")!
        defaults.removePersistentDomain(forName: "glance.live.snapshots")
        var status = AppStatusValue()
        status.calibrated = true; status.trackerKind = "mesh"; status.displayCount = 2; status.currentDisplay = 1
        for (scheme, appearance) in Self.schemes {
            let view = SettingsView(router: SettingsRouter(pane: .overview), store: SettingsStore(defaults: defaults),
                                    status: AppStatus(status), updater: Updater(), meshAvailable: true,
                                    cameras: [CameraInfo(id: "int", name: "FaceTime HD Camera")], actions: MainWindowActions(),
                                    live: { AnyView(LiveFacePanel(model: model, faceStandIn: standIn)) }, previewUpdate: nil)
                .background(Color(nsColor: .windowBackgroundColor))
            let size = CGSize(width: WindowChrome.mainSize.width, height: 1060)
            try png(try host(view, size: size, appearance: appearance, inWindow: false), to: dir.appendingPathComponent("overview-\(scheme).png"))
        }
    }

    // MARK: Helpers

    /// A model in a fixed, frozen state: two displays (laptop left of a 1440p external, tops aligned).
    private func prepare(_ state: State) throws -> LiveFaceModel {
        let hub = PoseHub()
        let model = LiveFaceModel(hub: hub)
        let now = 1000.0
        model.clock = { now }
        let pitch = state == .offscreen ? -0.32 : 0.06
        hub.publish(HeadPose(timestamp: 0, yaw: 0.22, pitch: pitch, roll: 0.04, faceCenter: CGPoint(x: 0.52, y: 0.48),
                             faceSize: 0.3, eyeOffset: CGVector(dx: 0.35, dy: state == .offscreen ? -0.4 : 0.12),
                             confidence: 0.95))
        model.show()                                       // the panel's onAppear then finds it already shown
        model.displays = [Self.external, Self.laptop]
        model.displayLabels = [1: .init(name: "Studio Display", builtin: false), 2: .init(name: "Built-in Retina Display", builtin: true)]
        model.calibrated = state != .uncalibrated
        model.mode = .both
        model.eyeWeight = 0.7
        switch state {
        case .tracking, .lost:
            model.estimate = GazeEstimate(point: CGPoint(x: 1660, y: 520), displayID: 1, confidence: 0.86)
            model.currentDisplay = 1
        case .offscreen:
            model.estimate = GazeEstimate(point: CGPoint(x: 1250, y: 1720), displayID: nil, confidence: 0.52)
            model.currentDisplay = 1
        case .uncalibrated:
            model.estimate = nil
            model.currentDisplay = 2
        }
        let m = model.motion
        m.settle()
        if state == .lost {
            model.ingest(nil)
            model.estimate = nil
            for f in 0...180 { m.advance(to: now + Double(f) / 60) }    // hold, then ease to neutral
            RunLoop.main.run(until: Date().addingTimeInterval(LiveFaceModel.lostDelay + 0.15))
            XCTAssertFalse(model.faceVisible)
        } else {
            let head = LiveMotion.head(m.face.output), eyes = LiveMotion.eyes(m.face.output)
            let gazeEnd = m.gaze.point ?? .zero
            m.setTrails(head: curve(from: CGPoint(x: head.x - 0.35, y: head.y - 0.08), to: head),
                        eyes: curve(from: CGPoint(x: eyes.x - 0.5, y: eyes.y - 0.12), to: eyes),
                        gaze: state == .uncalibrated ? [] : curve(from: CGPoint(x: gazeEnd.x - 900, y: gazeEnd.y + 260), to: gazeEnd))
        }
        m.frozen = true
        return model
    }

    private func curve(from a: CGPoint, to b: CGPoint, n: Int = 14) -> [CGPoint] {
        (0..<n).map { i in
            let u = Double(i) / Double(n - 1), e = 1 - (1 - u) * (1 - u)       // decelerating, like a real glance
            return CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * (u * u))
        }
    }

    private func bitmap(_ size: CGSize, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        return rep
    }

    private func draw(into rep: NSBitmapImageRep, appearance: NSAppearance.Name, _ body: () -> Void) throws {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance(body)
    }

    /// Lays text out at 2x without ever being ordered on screen.
    final class OffscreenWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var backingScaleFactor: CGFloat { 2 }
        override var canBecomeKey: Bool { false }
    }

    /// Hosting view drawn into a 2x bitmap. `inWindow` puts it in an `OffscreenWindow` so text is crisp;
    /// views with scroll views (the Form) must stay window-less, which draws them at 1x.
    private func host<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, inWindow: Bool = true) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance)
        var window: NSWindow?
        if inWindow {
            let w = OffscreenWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            w.contentView = host
            window = w
        }
        defer { window?.contentView = nil; XCTAssertFalse(window?.isVisible ?? false) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try bitmap(size, scale: inWindow ? 2 : 1)
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func png(_ rep: NSBitmapImageRep, to url: URL) throws {
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
