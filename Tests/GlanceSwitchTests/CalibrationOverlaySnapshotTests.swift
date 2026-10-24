import XCTest
import AppKit
@testable import GlanceKit

/// Renders every calibration overlay state to a PNG, off-screen (no window is ever created).
/// Set GLANCE_SNAPSHOT_DIR to keep the images; without it the states are still built and rendered.
final class CalibrationOverlaySnapshotTests: XCTestCase {
    private let size = CGSize(width: 1440, height: 900)

    private func makeView() -> CalibrationOverlayView {
        let v = CalibrationOverlayView(frame: CGRect(origin: .zero, size: size),
                                       primary: ActionButton(title: "", primary: true) {},
                                       secondary: ActionButton(title: "", primary: false) {}, snapshot: true)
        v.setFace(true)
        v.layoutSubtreeIfNeeded()
        return v
    }

    private func png(_ v: CalibrationOverlayView, _ name: String) throws {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return XCTFail("no bitmap") }
        v.cacheDisplay(in: v.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 10_000)
        if let dir = ProcessInfo.processInfo.environment["GLANCE_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    private func content(_ title: String, subtitle: String = "", big: String = "", layout: CalibrationOverlayView.Layout = .compact,
                         color: NSColor = .white, pill: Bool = false, hint: String = CalibrationCopy.hint) -> CalibrationOverlayView.Content {
        var c = CalibrationOverlayView.Content()
        c.title = title; c.subtitle = subtitle; c.big = big; c.layout = layout
        c.titleColor = color; c.pill = pill; c.hint = hint
        return c
    }

    func testRenderAllStates() throws {
        var v = makeView()
        v.apply(content(CalibrationCopy.introTitle, subtitle: CalibrationCopy.introSubtitle(screens: 2),
                        layout: .message, hint: CalibrationCopy.introHint), animated: false)
        v.setHeader("Screen 1 (built-in)  ·  1440×900")
        v.setButtons(primary: "Start", secondary: nil)
        try png(v, "01-intro")

        v = makeView()
        v.apply(content(CalibrationCopy.range("LEFT edge"), big: "←  2", layout: .range), animated: false)
        v.setHeader("Display 1 of 2  ·  2/26"); v.setProgress(0.04)
        v.showDot(at: CGPoint(x: 43, y: 450), animated: false, fromHidden: true)
        try png(v, "02-range-countdown")

        v = makeView()
        v.apply(content(CalibrationCopy.dot), animated: false)
        v.setHeader("Display 1 of 2  ·  7/26"); v.setProgress(0.25)
        v.showDot(at: CGPoint(x: 1325, y: 72), animated: false, fromHidden: true)
        try png(v, "03-dot-settling")

        v.setArcProgress(0.6)
        try png(v, "04-dot-collecting")

        v = makeView()
        v.apply(content(CalibrationCopy.eyes, pill: true), animated: false)
        v.setHeader("Display 2 of 2  ·  20/26"); v.setProgress(0.72)
        v.showDot(at: CGPoint(x: 1224, y: 450), animated: false, fromHidden: true, eyesOnly: true)
        v.setArcProgress(0.7)
        try png(v, "05-eyes-head-still")

        v = makeView()
        v.apply(content(CalibrationCopy.holdStill, subtitle: CalibrationCopy.holdStillSub, color: CalibrationPalette.warn, pill: true),
                animated: false)
        v.setHeader("Display 2 of 2  ·  20/26"); v.setProgress(0.72)
        v.showDot(at: CGPoint(x: 720, y: 135), animated: false, fromHidden: true, eyesOnly: true)
        try png(v, "06-retry-hold-still")

        v = makeView()
        v.apply(content(CalibrationCopy.verify), animated: false)
        v.setHeader(CalibrationCopy.verifyHeader(1, of: 2)); v.setProgress(1)
        v.highlight(CalibrationPalette.good)
        try png(v, "07-verify-highlight")

        v.highlight(nil)
        v.setBadge(true, animated: false)
        try png(v, "08-verify-pass")

        v = makeView()
        v.apply(content(CalibrationCopy.allSetTitle, subtitle: CalibrationCopy.allSetSubtitle(screens: 2),
                        layout: .message, hint: CalibrationCopy.allSetHint), animated: false)
        v.setHeader("Screen 1 (built-in)  ·  1440×900")
        v.setBadge(true, animated: false)
        v.setButtons(primary: "Finish", secondary: nil)
        try png(v, "09-summary-success")

        v = makeView()
        v.apply(content(CalibrationCopy.screenFailed("Screen 2"), subtitle: CalibrationCopy.failedSubtitle,
                        layout: .message, hint: CalibrationCopy.failedHint), animated: false)
        v.setHeader("Screen 2  ·  1920×1080")
        v.setBadge(false, animated: false)
        v.setButtons(primary: "Finish", secondary: "Redo")
        try png(v, "10-summary-fail")

        v = makeView()
        v.apply(content(CalibrationCopy.elsewhere(screen: 1), layout: .message, color: NSColor.white.withAlphaComponent(0.7)),
                animated: false)
        v.setHeader("Display 1 of 2  ·  7/26"); v.setProgress(0.25)
        try png(v, "11-other-display")
    }
}
