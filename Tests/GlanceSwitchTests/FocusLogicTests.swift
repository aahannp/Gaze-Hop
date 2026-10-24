import XCTest
@testable import GlanceKit

final class FocusLogicTests: XCTestCase {
    let d0 = Displays.Info(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    let d1 = Displays.Info(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
    var displays: [Displays.Info] { [d0, d1] }
    let me: pid_t = 99

    // front-to-back
    var wins: [WindowSnapshot] {
        [WindowSnapshot(id: 1, pid: me, bounds: CGRect(x: 0, y: 0, width: 2000, height: 800)),          // ours
         WindowSnapshot(id: 2, pid: 10, bounds: CGRect(x: 0, y: 0, width: 2000, height: 20), layer: 25), // menu bar
         WindowSnapshot(id: 3, pid: 11, bounds: CGRect(x: 1100, y: 100, width: 400, height: 400)),
         WindowSnapshot(id: 4, pid: 12, bounds: CGRect(x: 100, y: 100, width: 400, height: 400)),
         WindowSnapshot(id: 5, pid: 13, bounds: CGRect(x: 50, y: 50, width: 800, height: 600)),
         WindowSnapshot(id: 6, pid: 14, bounds: CGRect(x: 0, y: 0, width: 10, height: 10))]
    }

    func testWindowUnderSkipsOursAndNonNormalLayers() {
        XCTAssertEqual(FocusLogic.windowUnder(CGPoint(x: 1200, y: 200), in: wins, excludingPID: me)?.id, 3)
        XCTAssertEqual(FocusLogic.windowUnder(CGPoint(x: 200, y: 200), in: wins, excludingPID: me)?.id, 4)
        XCTAssertEqual(FocusLogic.windowUnder(CGPoint(x: 700, y: 500), in: wins, excludingPID: me)?.id, 5)
        XCTAssertNil(FocusLogic.windowUnder(CGPoint(x: 1900, y: 700), in: wins, excludingPID: me))
    }

    func testTinyWindowsIgnored() {
        XCTAssertNotEqual(FocusLogic.windowUnder(CGPoint(x: 5, y: 5), in: wins, excludingPID: me)?.id, 6)
    }

    func testDisplayOfUsesCenterThenOverlap() {
        XCTAssertEqual(FocusLogic.displayOf(CGRect(x: 900, y: 0, width: 400, height: 100), displays: displays), 2)
        XCTAssertEqual(FocusLogic.displayOf(CGRect(x: 800, y: 0, width: 300, height: 100), displays: displays), 1)
        XCTAssertNil(FocusLogic.displayOf(CGRect(x: 5000, y: 5000, width: 10, height: 10), displays: displays))
    }

    func testTopWindowOnDisplay() {
        XCTAssertEqual(FocusLogic.topWindow(on: 2, in: wins, displays: displays, excludingPID: me)?.id, 3)
        XCTAssertEqual(FocusLogic.topWindow(on: 1, in: wins, displays: displays, excludingPID: me)?.id, 4)
    }

    func testMRUPrefersHistoryAndSkipsGone() {
        // history: 5 (d0), 99 (closed), 4 (d0), 3 (d1)
        let h: [UInt32] = [99, 5, 4, 3]
        XCTAssertEqual(FocusLogic.mruWindow(on: 1, history: h, windows: wins, displays: displays, excludingPID: me)?.id, 5)
        XCTAssertEqual(FocusLogic.mruWindow(on: 2, history: h, windows: wins, displays: displays, excludingPID: me)?.id, 3)
        XCTAssertNil(FocusLogic.mruWindow(on: 2, history: [99], windows: wins, displays: displays, excludingPID: me))
    }

    func testTouch() {
        XCTAssertEqual(FocusLogic.touch(3, in: [1, 2, 3, 4]), [3, 1, 2, 4])
        XCTAssertEqual(FocusLogic.touch(9, in: [1, 2], limit: 2), [9, 1])
    }

    func testAllowlist() {
        for id in ["com.googlecode.iterm2", "com.apple.Terminal", "com.microsoft.VSCode", "com.jetbrains.intellij",
                   "com.jetbrains.pycharm", "com.google.android.studio", "dev.zed.Zed", "com.apple.dt.Xcode"] {
            XCTAssertTrue(FocusLogic.isSplitPaneApp(id), id)
        }
        for id in ["com.google.Chrome", "com.apple.Safari", "com.tinyspeck.slackmacgap", "com.jetbrainsx.foo", ""] {
            XCTAssertFalse(FocusLogic.isSplitPaneApp(id), id)
        }
        XCTAssertFalse(FocusLogic.isSplitPaneApp(nil))
    }

    func testPaneRoles() {
        XCTAssertTrue(FocusLogic.isPaneLevel(role: "AXTextArea", parentRole: nil))
        XCTAssertTrue(FocusLogic.isPaneLevel(role: "AXScrollArea", parentRole: "AXGroup"))
        XCTAssertTrue(FocusLogic.isPaneLevel(role: "AXGroup", parentRole: "AXSplitGroup"))
        XCTAssertFalse(FocusLogic.isPaneLevel(role: "AXGroup", parentRole: "AXGroup"))
        XCTAssertFalse(FocusLogic.isPaneLevel(role: "AXButton", parentRole: "AXSplitGroup"))
    }
}
