import XCTest
@testable import GlanceKit

private final class FakeMapper: GazeMapper {
    var isCalibrated = true
    var next: GazeEstimate?
    var samples: [(HeadPose, CGPoint, Double)] = []
    var outcomes: [(DisplayID?, DisplayID)] = []
    var fitCount = 0
    var driftScore = 0.0
    func estimate(_ pose: HeadPose, currentDisplay: DisplayID?, edgeBias: Double) -> GazeEstimate? { next }
    func addSample(_ pose: HeadPose, target: CGPoint, weight: Double) { samples.append((pose, target, weight)) }
    func fit() -> Bool { fitCount += 1; return true }
    func reset() {}
    func save() throws {}
    func load() throws {}
    func recordClickOutcome(predicted: DisplayID?, actual: DisplayID) { outcomes.append((predicted, actual)) }
}

private final class FakeFocus: FocusController {
    var displayCalls: [(DisplayID, CGPoint?, Bool)] = []
    var paneCalls: [(CGPoint, Bool)] = []
    var focused: DisplayID? = 1
    func focusDisplay(_ display: DisplayID, gazePoint: CGPoint?, movePointer: Bool) -> Bool {
        displayCalls.append((display, gazePoint, movePointer)); focused = display; return true
    }
    func focusWithinDisplay(at point: CGPoint, clickFallback: Bool) -> Bool {
        paneCalls.append((point, clickFallback)); return true
    }
    func focusedDisplay() -> DisplayID? { focused }
    func startTracking() {}
}

private final class FakeInput: InputActivityMonitoring {
    var lastKeyTime: TimeInterval = 0
    var lastMouseTime: TimeInterval = 0
    var onUserClick: ((CGPoint) -> Void)?
    func start() {}
    func stop() {}
}

final class EngineTests: XCTestCase {
    private var mapper: FakeMapper!
    private var focus: FakeFocus!
    private var input: FakeInput!
    private var settings: Settings!
    private var clock: TimeInterval!
    private var scheduled: [() -> Void] = []
    private var engine: SwitchEngine!

    // Two 1000x800 displays side by side.
    private let frames: [DisplayID: CGRect] = [1: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                               2: CGRect(x: 1000, y: 0, width: 1000, height: 800)]

    override func setUp() {
        mapper = FakeMapper(); focus = FakeFocus(); input = FakeInput()
        settings = Settings(); settings.windowFocusEnabled = false
        clock = 100; scheduled = []
        engine = SwitchEngine(mapper: mapper, focus: focus, input: input,
                              settings: { [unowned self] in self.settings },
                              now: { [unowned self] in self.clock },
                              displayFrame: { [unowned self] in self.frames[$0] },
                              displayAt: { [unowned self] p in self.frames.first { $0.value.contains(p) }?.key },
                              schedule: { [unowned self] _, b in self.scheduled.append(b) })
    }

    private func pose() -> HeadPose {
        HeadPose(timestamp: clock, yaw: 0, pitch: 0, roll: 0, faceCenter: .zero, faceSize: 0.3,
                 eyeOffset: .zero, confidence: 1)
    }

    /// Feed poses every 66 ms for `seconds`, gaze fixed at `point`.
    private func gaze(_ display: DisplayID?, _ point: CGPoint, for seconds: Double) {
        mapper.next = GazeEstimate(point: point, displayID: display, confidence: 1)
        let end = clock + seconds
        while clock < end { engine.handle(pose: pose()); clock += 0.066 }
        engine.handle(pose: pose())
    }

    func testDwellSwitchesAfterDelay() {
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.2)
        XCTAssertTrue(focus.displayCalls.isEmpty)
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.3)
        XCTAssertEqual(focus.displayCalls.count, 1)
        XCTAssertEqual(focus.displayCalls[0].0, 2)
        XCTAssertEqual(focus.displayCalls[0].1, CGPoint(x: 1500, y: 400))
        XCTAssertEqual(engine.currentDisplay, 2)
    }

    func testFlickBackToOriginalResetsDwell() {
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.2)
        gaze(1, CGPoint(x: 500, y: 400), for: 0.1)
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.2)
        XCTAssertTrue(focus.displayCalls.isEmpty)
    }

    func testSameDisplayNeverSwitches() {
        gaze(1, CGPoint(x: 500, y: 400), for: 2)
        XCTAssertTrue(focus.displayCalls.isEmpty)
    }

    func testOffScreenGazeIgnored() {
        gaze(nil, CGPoint(x: 500, y: -900), for: 2)
        XCTAssertTrue(focus.displayCalls.isEmpty)
        XCTAssertTrue(focus.paneCalls.isEmpty)
    }

    func testOffScreenInterruptsDwell() {
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.2)
        gaze(nil, CGPoint(x: 500, y: -900), for: 0.1)
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.2)
        XCTAssertTrue(focus.displayCalls.isEmpty)
    }

    func testTypingProtectionBlocksThenResumes() {
        input.lastKeyTime = clock
        gaze(2, CGPoint(x: 1500, y: 400), for: 1.0)
        XCTAssertTrue(focus.displayCalls.isEmpty)
        XCTAssertEqual(engine.state.hold, .typing)
        gaze(2, CGPoint(x: 1500, y: 400), for: 1.5)   // total > typingPauseSec since the key
        XCTAssertEqual(focus.displayCalls.count, 1)
    }

    func testTypingProtectionDisabled() {
        settings.typingProtection = false
        input.lastKeyTime = clock
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.5)
        XCTAssertEqual(focus.displayCalls.count, 1)
    }

    func testMousePriorityBlocks() {
        input.lastMouseTime = clock
        gaze(2, CGPoint(x: 1500, y: 400), for: 1.0)
        XCTAssertTrue(focus.displayCalls.isEmpty)
        XCTAssertTrue(focus.paneCalls.isEmpty)
        XCTAssertEqual(engine.state.hold, .mouse)
        gaze(2, CGPoint(x: 1500, y: 400), for: 1.0)   // 1.5 s mouse priority expires
        XCTAssertEqual(focus.displayCalls.count, 1)
    }

    func testPausedDoesNothing() {
        settings.paused = true
        gaze(2, CGPoint(x: 1500, y: 400), for: 2)
        XCTAssertTrue(focus.displayCalls.isEmpty)
        XCTAssertTrue(engine.state.paused)
    }

    func testMovePointerSettingPassedThrough() {
        settings.movePointer = false
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.5)
        XCTAssertEqual(focus.displayCalls.first?.2, false)
    }

    func testPaneFocusAfterDwell() {
        settings.windowFocusEnabled = true
        gaze(1, CGPoint(x: 200, y: 400), for: 0.1)       // establishes anchor
        gaze(1, CGPoint(x: 800, y: 400), for: 0.2)
        XCTAssertTrue(focus.paneCalls.isEmpty)
        gaze(1, CGPoint(x: 800, y: 400), for: 0.3)
        XCTAssertEqual(focus.paneCalls.count, 1)
        XCTAssertEqual(focus.paneCalls[0].0, CGPoint(x: 800, y: 400))
        XCTAssertTrue(focus.paneCalls[0].1)
        gaze(1, CGPoint(x: 800, y: 400), for: 1)          // no repeat
        XCTAssertEqual(focus.paneCalls.count, 1)
    }

    func testSmallMovementDoesNotFocusPane() {
        settings.windowFocusEnabled = true
        gaze(1, CGPoint(x: 200, y: 400), for: 0.1)
        gaze(1, CGPoint(x: 300, y: 420), for: 2)
        XCTAssertTrue(focus.paneCalls.isEmpty)
    }

    func testPaneRespectsTypingAndMouse() {
        settings.windowFocusEnabled = true
        gaze(1, CGPoint(x: 200, y: 400), for: 0.1)
        input.lastKeyTime = clock
        gaze(1, CGPoint(x: 800, y: 400), for: 1)
        XCTAssertTrue(focus.paneCalls.isEmpty)
        input.lastMouseTime = clock
        gaze(1, CGPoint(x: 800, y: 400), for: 1)
        XCTAssertTrue(focus.paneCalls.isEmpty)
    }

    func testPaneDisabledSetting() {
        gaze(1, CGPoint(x: 200, y: 400), for: 0.1)
        gaze(1, CGPoint(x: 800, y: 400), for: 2)
        XCTAssertTrue(focus.paneCalls.isEmpty)
    }

    func testClickLearningDuringSteadyGaze() {
        gaze(1, CGPoint(x: 200, y: 400), for: 1)
        input.onUserClick?(CGPoint(x: 210, y: 405))
        XCTAssertEqual(mapper.samples.count, 1)
        XCTAssertEqual(mapper.samples[0].2, 0.3)
        XCTAssertEqual(mapper.outcomes.first?.0, 1)
        XCTAssertEqual(mapper.outcomes.first?.1, 1)
        XCTAssertEqual(scheduled.count, 1)
        input.onUserClick?(CGPoint(x: 220, y: 405))      // debounced: still one pending refit
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(mapper.fitCount, 1)
    }

    func testClickIgnoredWhenGazeNotSteadyOrDisabled() {
        gaze(1, CGPoint(x: 200, y: 400), for: 0.1)
        input.onUserClick?(CGPoint(x: 210, y: 405))
        XCTAssertTrue(mapper.samples.isEmpty)
        gaze(1, CGPoint(x: 200, y: 400), for: 1)
        settings.learnFromClicks = false
        input.onUserClick?(CGPoint(x: 210, y: 405))
        XCTAssertTrue(mapper.samples.isEmpty)
    }

    func testClickIgnoredWhenPaused() {
        gaze(1, CGPoint(x: 200, y: 400), for: 1)
        settings.paused = true
        input.onUserClick?(CGPoint(x: 210, y: 405))
        XCTAssertTrue(mapper.samples.isEmpty)
    }

    func testDriftSuggestionFiresOnce() {
        var fired = 0
        engine.onDriftSuggested = { fired += 1 }
        mapper.driftScore = 0.7
        gaze(1, CGPoint(x: 200, y: 400), for: 1)
        input.onUserClick?(CGPoint(x: 210, y: 405))
        input.onUserClick?(CGPoint(x: 210, y: 405))
        XCTAssertEqual(fired, 1)
    }

    func testNilPoseClearsDwell() {
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.25)
        engine.handle(pose: nil)
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.2)
        XCTAssertTrue(focus.displayCalls.isEmpty)
    }
}
