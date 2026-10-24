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
    var focusedQueries = 0
    func focusDisplay(_ display: DisplayID, gazePoint: CGPoint?, movePointer: Bool) -> Bool {
        displayCalls.append((display, gazePoint, movePointer)); focused = display; return true
    }
    func focusWithinDisplay(at point: CGPoint, clickFallback: Bool) -> Bool {
        paneCalls.append((point, clickFallback)); return true
    }
    func focusedDisplay() -> DisplayID? { focusedQueries += 1; return focused }
    func startTracking() {}
}

private final class FakeInput: InputActivityMonitoring {
    var lastKeyTime: TimeInterval = 0
    var lastMouseTime: TimeInterval = 0
    var onUserClick: ((CGPoint) -> Void)?
    func start() {}
    func stop() {}
}

private final class FakeTrace: TraceLogging {
    var isEnabled = true
    var rows: [String] = []
    func write(_ row: String) { rows.append(row) }
}

private final class FakeLog: LatencyLogging {
    var isEnabled = true
    var lines: [String] = []
    func log(_ line: String) { lines.append(line) }
}

final class EngineTests: XCTestCase {
    private var fakeLog: FakeLog!
    private var fakeTrace: FakeTrace!
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
        // Pin the original timings so the behaviour tests below read the same; defaults are tested separately.
        settings = Settings(); settings.windowFocusEnabled = false
        settings.switchDelayMs = 300; settings.typingPauseSec = 2.0; settings.mousePriorityMs = 1500
        fakeLog = FakeLog(); fakeTrace = FakeTrace()
        clock = 100; scheduled = []
        engine = SwitchEngine(mapper: mapper, focus: focus, input: input,
                              settings: { [unowned self] in self.settings },
                              now: { [unowned self] in self.clock },
                              displayFrame: { [unowned self] in self.frames[$0] },
                              displayAt: { [unowned self] p in self.frames.first { $0.value.contains(p) }?.key },
                              schedule: { [unowned self] _, b in self.scheduled.append(b) },
                              latencyLog: fakeLog, traceLog: fakeTrace)
        engine.fastFrames = .max   // fast path off for the dwell tests; enabled explicitly below
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
        gaze(nil, CGPoint(x: 500, y: -900), for: 0.3)
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

    // MARK: latency-fix behaviour

    func testNewDefaultsAreSnappy() {
        let d = Settings()
        XCTAssertEqual(d.switchDelayMs, 150)
        XCTAssertEqual(d.typingPauseSec, 0.5)
        XCTAssertEqual(d.mousePriorityMs, 600)
    }

    func testSavedSettingsKeepTheirOwnValues() throws {
        var custom = Settings(); custom.switchDelayMs = 700; custom.typingPauseSec = 3
        let suite = UserDefaults(suiteName: "glance.test.\(UUID().uuidString)")!
        suite.set(try JSONEncoder().encode(custom), forKey: SettingsStore.key)
        let loaded = SettingsStore(defaults: suite).settings
        XCTAssertEqual(loaded.switchDelayMs, 700)
        XCTAssertEqual(loaded.typingPauseSec, 3)
        // Nothing saved => the new defaults.
        XCTAssertEqual(SettingsStore(defaults: UserDefaults(suiteName: "glance.test.\(UUID().uuidString)")!).settings.switchDelayMs, 150)
    }

    func testShortOffScreenGapKeepsDwell() {
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.2)
        gaze(nil, CGPoint(x: 1000, y: -50), for: 0.07)    // < offScreenGrace
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.2)
        XCTAssertEqual(focus.displayCalls.count, 1)
    }

    func testLongOffScreenGapResetsDwell() {
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.2)
        gaze(nil, CGPoint(x: 1000, y: -50), for: 0.3)     // > offScreenGrace
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.2)
        XCTAssertTrue(focus.displayCalls.isEmpty)
    }

    func testFocusedDisplayQueryIsThrottledWhileMouseActive() {
        input.lastMouseTime = clock + 100                  // mouse "active" for the whole run
        gaze(1, CGPoint(x: 500, y: 400), for: 1.0)         // ~15 poses
        XCTAssertLessThanOrEqual(focus.focusedQueries, 6)  // init query + ~4 Hz
    }

    func testStaleFocusCacheDoesNotRevertSwitch() {
        input.lastMouseTime = 0
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.31)
        XCTAssertEqual(engine.currentDisplay, 2)
        focus.focused = 1                                   // controller hasn't caught up
        input.lastMouseTime = clock                         // mouse now active
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.1)
        XCTAssertEqual(engine.currentDisplay, 2)
    }

    func testLatencyLogRecordsBreakdownWithHold() {
        input.lastKeyTime = clock                            // typing hold 2 s
        gaze(2, CGPoint(x: 1500, y: 400), for: 2.6)
        XCTAssertEqual(fakeLog.lines.count, 1)
        let l = fakeLog.lines[0]
        XCTAssertTrue(l.contains("display=2"), l)
        XCTAssertTrue(l.contains("hold=typing"), l)
        XCTAssertTrue(l.contains("dwell=") && l.contains("focus=") && l.contains("total="), l)
    }

    func testLatencyLogWithoutHold() {
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.5)
        XCTAssertTrue(fakeLog.lines.first?.contains("hold=none") == true)
    }

    func testLatencyLogDisabledWritesNothing() {
        fakeLog.isEnabled = false
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.5)
        XCTAssertTrue(fakeLog.lines.isEmpty)
    }

    // MARK: fast path / anti-flicker / miss logging

    private func noFace(for seconds: Double) {
        let end = clock + seconds
        while clock < end { engine.handle(pose: nil); clock += 0.066 }
        engine.handle(pose: nil)
    }

    private func lines(_ prefix: String) -> [String] { fakeLog.lines.filter { $0.hasPrefix(prefix) } }

    func testFastPathSwitchesAfterTwoDecisiveFrames() {
        engine.fastFrames = 2
        mapper.next = GazeEstimate(point: CGPoint(x: 1500, y: 400), displayID: 2, confidence: 0.9)
        engine.handle(pose: pose()); clock += 0.066
        XCTAssertTrue(focus.displayCalls.isEmpty)             // one frame is not enough
        engine.handle(pose: pose())
        XCTAssertEqual(focus.displayCalls.count, 1)
        XCTAssertTrue(lines("switch").first?.contains("fast=1") == true, "\(fakeLog.lines)")
    }

    func testNearEdgeKeepsFullDwell() {
        engine.fastFrames = 2
        gaze(2, CGPoint(x: 1050, y: 400), for: 0.2)           // 50 px past the edge < 12% of 1000
        XCTAssertTrue(focus.displayCalls.isEmpty)
        gaze(2, CGPoint(x: 1050, y: 400), for: 0.2)
        XCTAssertEqual(focus.displayCalls.count, 1)
        XCTAssertTrue(lines("switch").first?.contains("fast=0") == true)
    }

    func testLowConfidenceSkipsFastPath() {
        engine.fastFrames = 2
        mapper.next = GazeEstimate(point: CGPoint(x: 1500, y: 400), displayID: 2, confidence: 0.3)
        for _ in 0..<3 { engine.handle(pose: pose()); clock += 0.066 }
        XCTAssertTrue(focus.displayCalls.isEmpty)
    }

    func testAntiFlickerNeedsFullDwellToGoBack() {
        engine.fastFrames = 2
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.1)
        XCTAssertEqual(focus.displayCalls.count, 1)
        gaze(1, CGPoint(x: 500, y: 400), for: 0.15)           // decisive, but within 0.5 s of the switch
        XCTAssertEqual(focus.displayCalls.count, 1)
        gaze(1, CGPoint(x: 500, y: 400), for: 0.3)            // full dwell elapses
        XCTAssertEqual(focus.displayCalls.count, 2)
        XCTAssertTrue(lines("switch").last?.contains("fast=0") == true)
    }

    func testFastPathAllowedAgainAfterFlickerWindow() {
        engine.fastFrames = 2
        gaze(2, CGPoint(x: 1500, y: 400), for: 0.1)
        clock += 0.6
        gaze(1, CGPoint(x: 500, y: 400), for: 0.1)
        XCTAssertEqual(focus.displayCalls.count, 2)
        XCTAssertTrue(lines("switch").last?.contains("fast=1") == true)
    }

    func testMissLoggedWhenGazeReturns() {
        gaze(2, CGPoint(x: 1050, y: 400), for: 0.2)
        gaze(1, CGPoint(x: 500, y: 400), for: 0.1)
        let miss = lines("miss")
        XCTAssertEqual(miss.count, 1, "\(fakeLog.lines)")
        XCTAssertTrue(miss[0].contains("display=2") && miss[0].contains("reason=returned"), miss[0])
    }

    func testNoMissLoggedForShortPending() {
        gaze(2, CGPoint(x: 1050, y: 400), for: 0.05)
        gaze(1, CGPoint(x: 500, y: 400), for: 0.1)
        XCTAssertTrue(lines("miss").isEmpty)
    }

    func testMissReasons() {
        gaze(2, CGPoint(x: 1050, y: 400), for: 0.2)
        gaze(nil, CGPoint(x: 1000, y: -50), for: 0.4)
        XCTAssertTrue(lines("miss").last?.contains("reason=offscreen") == true, "\(fakeLog.lines)")
        gaze(2, CGPoint(x: 1050, y: 400), for: 0.2)
        noFace(for: 0.1)
        XCTAssertTrue(lines("miss").last?.contains("reason=faceLost") == true, "\(fakeLog.lines)")
        input.lastKeyTime = clock
        gaze(2, CGPoint(x: 1050, y: 400), for: 0.5)           // dwell done but typing-held
        gaze(1, CGPoint(x: 500, y: 400), for: 0.1)
        XCTAssertTrue(lines("miss").last?.contains("reason=hold") == true, "\(fakeLog.lines)")
        XCTAssertTrue(lines("miss").last?.contains("hold=typing") == true)
    }

    func testFaceLostSpanLogged() {
        gaze(1, CGPoint(x: 500, y: 400), for: 0.1)
        noFace(for: 0.5)
        gaze(1, CGPoint(x: 500, y: 400), for: 0.1)
        XCTAssertEqual(lines("faceLost").count, 1, "\(fakeLog.lines)")
    }

    func testShortFaceLostNotLogged() {
        gaze(1, CGPoint(x: 500, y: 400), for: 0.1)
        noFace(for: 0.15)
        gaze(1, CGPoint(x: 500, y: 400), for: 0.1)
        XCTAssertTrue(lines("faceLost").isEmpty)
    }

    func testPeriodicSummary() {
        engine.summaryInterval = 1
        gaze(1, CGPoint(x: 500, y: 400), for: 0.5)
        noFace(for: 0.3)
        gaze(nil, CGPoint(x: 500, y: -900), for: 0.4)
        gaze(1, CGPoint(x: 500, y: 400), for: 0.5)
        let sum = lines("summary")
        XCTAssertEqual(sum.count, 1, "\(fakeLog.lines)")
        XCTAssertTrue(sum[0].contains("noFace=") && sum[0].contains("offScreen=") && sum[0].contains("meanConf=1.00"), sum[0])
    }

    func testTypingPauseDefault() { XCTAssertEqual(Settings().typingPauseSec, 0.5) }

    // MARK: trace

    func testTraceRowPerFrameWithExpectedColumns() {
        input.lastKeyTime = clock
        gaze(2, CGPoint(x: 1050, y: 400), for: 0.2)
        XCTAssertGreaterThan(fakeTrace.rows.count, 2)
        let cols = fakeTrace.rows.last!.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(cols.count, TraceLog.header.split(separator: ",").count)
        XCTAssertEqual(cols[10], "1050.0"); XCTAssertEqual(cols[12], "2")
        XCTAssertEqual(cols[13], "1")           // currentDisplay (from focus)
        XCTAssertEqual(cols[14], "typing"); XCTAssertEqual(cols[15], "2")
        XCTAssertTrue(fakeTrace.rows.allSatisfy { $0.allSatisfy { "0123456789.,-typingmouse".contains($0) } })
    }

    func testTraceNoFaceRowHasEmptyPoseColumns() {
        noFace(for: 0.1)
        let cols = fakeTrace.rows[0].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(cols.count, 16)
        XCTAssertTrue(cols[1...12].allSatisfy { $0.isEmpty })
    }

    func testTraceDisabledWritesNothing() {
        fakeTrace.isEnabled = false
        gaze(1, CGPoint(x: 500, y: 400), for: 0.3)
        XCTAssertTrue(fakeTrace.rows.isEmpty)
    }

    func testTraceFileRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-trace-\(UUID().uuidString)")
        let suite = UserDefaults(suiteName: "glance.test.\(UUID().uuidString)")!
        suite.set(true, forKey: TraceLog.defaultsKey)
        let url = dir.appendingPathComponent("trace.csv")
        let log = TraceLog(defaults: suite, url: url, maxBytes: 2_000)
        for i in 0..<200 { log.write("\(i),1,2,3,4,5,6,7,8,9,10,11,12,13,,") }
        log.sync()
        let rotated = dir.appendingPathComponent("trace.1.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        XCTAssertTrue(try String(contentsOf: rotated).hasPrefix(TraceLog.header))
        XCTAssertLessThan(try Data(contentsOf: url).count, 4_000)
    }
}
