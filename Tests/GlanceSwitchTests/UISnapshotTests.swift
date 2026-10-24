import XCTest
import AppKit
import SwiftUI
@testable import GlanceKit

/// Builds the main window and setup guide off-screen. Nothing is ever ordered on screen.
/// Set GAZEHOP_SNAPSHOTS=<dir> to write PNGs (light and dark) for review. On macOS 26 an
/// off-screen window draws its scroll views blank, so PNGs come from window-less hosting
/// views with the window's traffic lights drawn on top.
final class UISnapshotTests: XCTestCase {
    /// Draws as if it were the key window, at 2x, without ever being shown.
    final class OffscreenWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var backingScaleFactor: CGFloat { 2 }
        override var canBecomeKey: Bool { false }
    }
    static let offscreen: WindowChrome.Maker = {
        OffscreenWindow(contentRect: $0, styleMask: $1, backing: .buffered, defer: false)
    }

    struct LiveStandIn: View {
        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: "face.smiling").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("Live face (LiveFacePanel)").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static let cameras = [CameraInfo(id: "ext", name: "Studio Display Camera"),
                          CameraInfo(id: "int", name: "FaceTime HD Camera")]

    static var tracking: AppStatusValue {
        var v = AppStatusValue()
        v.calibrated = true
        v.trackerKind = "mesh"
        v.displayCount = 2
        v.currentDisplay = CGMainDisplayID()
        return v
    }

    override func setUp() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)   // no Dock icon, no activation
    }

    // MARK: Always-on checks

    func testMainWindowBuildsAndLaysOutEveryPane() {
        for pane in SettingsPane.allCases {
            let (w, _) = mainWindow(pane: pane, status: Self.tracking)
            XCTAssertFalse(w.isVisible)
            XCTAssertGreaterThanOrEqual(w.contentView!.fittingSize.width, 0)
            XCTAssertEqual(w.title, "GazeHop")
            w.contentViewController = nil
        }
    }

    /// The pane title sits over the Form, so the Form's content must start below it.
    func testPaneContentStartsBelowTitle() throws {
        for pane in SettingsPane.allCases {
            let (w, _) = mainWindow(pane: pane, status: Self.tracking)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            w.contentView!.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(firstScrollView(in: w.contentView!), "\(pane)")
            let frame = scroll.convert(scroll.bounds, to: nil)
            let contentTop = w.contentView!.bounds.height - frame.maxY + scroll.contentInsets.top
            XCTAssertGreaterThanOrEqual(contentTop, SettingsView.headerHeight - 0.5, "\(pane)")
            w.contentViewController = nil
        }
    }

    func testStatusSummaryPriorities() {
        var v = Self.tracking
        XCTAssertEqual(StatusSummary(v, displayName: { _ in "LG" }).title, "Tracking")
        XCTAssertEqual(StatusSummary.menuLine(v, displayName: { _ in "LG" }), "Tracking · LG")
        v.paused = true
        XCTAssertEqual(StatusSummary.menuLine(v), "Paused")
        v.calibrated = false
        XCTAssertEqual(StatusSummary(v).title, "Not calibrated")
        v.cameraAllowed = false
        XCTAssertEqual(StatusSummary(v).title, "Camera access needed")
        v.calibrating = true
        XCTAssertEqual(StatusSummary(v).title, "Calibrating")
    }

    func testAppStatusPublishesOnlyOnChange() {
        let status = AppStatus(Self.tracking)
        var count = 0
        let sub = status.$value.dropFirst().sink { _ in count += 1 }
        for _ in 0..<30 { status.update { $0.currentDisplay = CGMainDisplayID() } }
        XCTAssertEqual(count, 0)
        status.update { $0.paused = true }
        XCTAssertEqual(count, 1)
        sub.cancel()
    }

    func testUpdateVersionDisplayDropsLeadingV() {
        XCTAssertEqual(UpdateStatusView.display("v1.2.0"), "1.2.0")
        XCTAssertEqual(UpdateStatusView.display("1.2.0"), "1.2.0")
    }

    // MARK: PNGs for review

    func testRenderSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["GAZEHOP_SNAPSHOTS"] else {
            throw XCTSkip("Set GAZEHOP_SNAPSHOTS=<dir> to render")
        }
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var notCalibrated = Self.tracking
        notCalibrated.calibrated = false
        notCalibrated.inputMonitoringAllowed = false
        notCalibrated.currentDisplay = nil
        var paused = Self.tracking
        paused.paused = true
        var cameraError = Self.tracking
        cameraError.cameraError = "The camera is in use by another app."
        var eyeWarning = Self.tracking
        eyeWarning.needsEyeCalibration = true
        var calibrating = Self.tracking
        calibrating.calibrating = true

        let updates: [(String, UpdateState)] = [
            ("idle", .idle), ("checking", .checking), ("uptodate", .upToDate),
            ("available", .available(version: "v1.3.0", notes: "**Faster switching** between split panes.\n- Fixed the gaze dot flickering on external displays.\n- MediaPipe calibration now takes 20 seconds.")),
            ("downloading", .downloading(progress: 0.42)), ("installing", .installing),
            ("failed", .failed("The download didn't finish. Check your connection and try again.")),
        ]

        PaneHeaderBar.inWindow = false
        defer { PaneHeaderBar.inWindow = true }
        let mainChrome = WindowChrome.main(Color.clear, make: Self.offscreen)
        let welcomeChrome = WindowChrome.panel(Color.clear, title: "", size: WelcomeView.size, make: Self.offscreen)

        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for pane in SettingsPane.allCases {
                try snapMain(pane: pane, status: Self.tracking, appearance: appearance, chrome: mainChrome,
                             to: dir.appendingPathComponent("main-\(pane.rawValue)-\(scheme).png"))
            }
            for (name, s) in [("notcalibrated", notCalibrated), ("paused", paused), ("cameraerror", cameraError)] {
                try snapMain(pane: .overview, status: s, appearance: appearance, chrome: mainChrome,
                             to: dir.appendingPathComponent("main-overview-\(name)-\(scheme).png"))
            }
            for (name, s) in [("eyewarning", eyeWarning), ("calibrating", calibrating), ("notcalibrated", notCalibrated)] {
                try snapMain(pane: .calibration, status: s, appearance: appearance, chrome: mainChrome,
                             to: dir.appendingPathComponent("main-calibration-\(name)-\(scheme).png"))
            }
            for (name, state) in updates {
                try snapMain(pane: .about, status: Self.tracking, update: state, appearance: appearance, chrome: mainChrome,
                             to: dir.appendingPathComponent("update-\(name)-\(scheme).png"))
            }
            let welcomes: [(String, PermissionState, Bool)] = [
                ("none", PermissionState(camera: false, accessibility: false, inputMonitoring: false), false),
                ("camera", PermissionState(camera: true, accessibility: false, inputMonitoring: false), false),
                ("ready", PermissionState(camera: true, accessibility: true, inputMonitoring: false), false),
                ("guide", PermissionState(camera: true, accessibility: true, inputMonitoring: true), true),
            ]
            for (name, perms, calibrated) in welcomes {
                let view = WelcomeView(calibrated: calibrated, read: { perms }, live: false, onContinue: {})
                try render(view, size: WelcomeView.size, appearance: appearance, chrome: welcomeChrome,
                           to: dir.appendingPathComponent("welcome-\(name)-\(scheme).png"))
            }
        }
    }

    // MARK: Helpers

    private func settingsView(pane: SettingsPane, status: AppStatusValue, update: UpdateState? = nil) -> SettingsView {
        let defaults = UserDefaults(suiteName: "gazehop.snapshots")!
        defaults.removePersistentDomain(forName: "gazehop.snapshots")
        return SettingsView(router: SettingsRouter(pane: pane), store: SettingsStore(defaults: defaults),
                            status: AppStatus(status), updater: Updater(), meshAvailable: true,
                            cameras: Self.cameras, actions: MainWindowActions(),
                            live: { AnyView(LiveStandIn()) }, previewUpdate: update)
    }

    private func mainWindow(pane: SettingsPane, status: AppStatusValue) -> (NSWindow, SettingsView) {
        let view = settingsView(pane: pane, status: status)
        return (WindowChrome.main(view, make: Self.offscreen), view)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews { if let s = firstScrollView(in: sub) { return s } }
        return nil
    }

    private func snapMain(pane: SettingsPane, status: AppStatusValue, update: UpdateState? = nil,
                          appearance: NSAppearance.Name, chrome: NSWindow, to url: URL) throws {
        try render(settingsView(pane: pane, status: status, update: update), size: WindowChrome.mainSize,
                   appearance: appearance, chrome: chrome, to: url)
    }

    private func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name,
                                 chrome: NSWindow, to url: URL) throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))   // the window's own background
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        // Close, minimise and zoom, cut from the window's own title bar where it puts them.
        chrome.appearance = host.appearance
        chrome.contentView?.layoutSubtreeIfNeeded()
        let frame = try XCTUnwrap(chrome.contentView?.superview)
        let titleBar = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: titleBar)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = chrome.standardWindowButton(kind) else { continue }
            let rect = button.convert(button.bounds, to: nil)
            let d = min(rect.width, rect.height)
            let dot = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: dot).addClip()
            titleBar.draw(in: dot, from: dot, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(chrome.isVisible)
    }
}
