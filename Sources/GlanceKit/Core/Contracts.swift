// Shared contracts between the Tracking, Calibration, Focus and App modules.
// FROZEN: workers must not change this file. If you need a change, ask the Lead agent.
//
// Coordinate convention everywhere: CG global coordinates (points), origin at the
// top-left of the main display, y grows DOWN. This is what CGWindowList, AX,
// CGWarpMouseCursorPosition and CGDisplayBounds use. Convert NSScreen/NSWindow
// (bottom-left origin) frames with `Displays.cgRect(fromCocoa:)`.

import Foundation
import CoreGraphics
import AppKit

public typealias DisplayID = CGDirectDisplayID

// MARK: - Tracking -> everyone

/// One processed camera frame. Sign conventions are from the USER's point of view
/// (as if the image were mirrored), so "right" means the user's right.
public struct HeadPose: Equatable {
    public var timestamp: TimeInterval   // ProcessInfo.processInfo.systemUptime
    public var yaw: Double               // radians, + = head turned to the user's right
    public var pitch: Double             // radians, + = head tilted up
    public var roll: Double              // radians, + = clockwise from user's view
    public var faceCenter: CGPoint       // normalized 0...1 in frame, x + = user's right, y + = down
    public var faceSize: Double          // face bbox width / frame width (distance proxy, bigger = closer)
    public var eyeOffset: CGVector       // mean pupil offset inside eye boxes, -1...1, dx + = user's right, dy + = up
    public var confidence: Double        // 0...1

    public init(timestamp: TimeInterval, yaw: Double, pitch: Double, roll: Double,
                faceCenter: CGPoint, faceSize: Double, eyeOffset: CGVector, confidence: Double) {
        self.timestamp = timestamp; self.yaw = yaw; self.pitch = pitch; self.roll = roll
        self.faceCenter = faceCenter; self.faceSize = faceSize; self.eyeOffset = eyeOffset
        self.confidence = confidence
    }

    /// Feature vector the mapper regresses on. Order is part of the contract.
    public var features: [Double] {
        [yaw, pitch, Double(faceCenter.x), Double(faceCenter.y), faceSize,
         Double(eyeOffset.dx), Double(eyeOffset.dy), roll]
    }
}

public struct CameraInfo: Equatable {
    public var id: String     // AVCaptureDevice.uniqueID
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Camera + face tracking. Implemented by `CameraPoseTracker` (Tracking module).
public protocol PoseSource: AnyObject {
    /// Called on the MAIN queue, at most ~15 Hz. `nil` = no face / low confidence this frame.
    var onPose: ((HeadPose?) -> Void)? { get set }
    var isRunning: Bool { get }
    /// `cameraID == nil` => prefer an external camera, else the built-in one.
    func start(cameraID: String?) throws
    func stop()
    static func availableCameras() -> [CameraInfo]
}

/// Fan-out so several consumers (engine, calibration UI, debug dot) can observe poses.
public final class PoseHub {
    public private(set) var latest: HeadPose?
    private var observers: [UUID: (HeadPose?) -> Void] = [:]
    public init() {}
    @discardableResult
    public func observe(_ block: @escaping (HeadPose?) -> Void) -> UUID {
        let id = UUID(); observers[id] = block; return id
    }
    public func remove(_ id: UUID) { observers[id] = nil }
    public func publish(_ pose: HeadPose?) {
        latest = pose
        for o in observers.values { o(pose) }
    }
}

// MARK: - Calibration / mapping

public struct GazeEstimate: Equatable {
    public var point: CGPoint          // CG global coords; may lie outside every display
    public var displayID: DisplayID?   // nil = looking off-screen (desk, ceiling, window)
    public var confidence: Double      // 0...1
    public init(point: CGPoint, displayID: DisplayID?, confidence: Double) {
        self.point = point; self.displayID = displayID; self.confidence = confidence
    }
}

/// Pose -> where on the desktop the user is looking. Implemented by `RegressionGazeMapper`.
public protocol GazeMapper: AnyObject {
    var isCalibrated: Bool { get }
    /// `edgeBias` is the head-turn threshold setting (0...1, 0.5 = boundary in the middle
    /// of the bezel gap). `currentDisplay` enables hysteresis: leaving it needs a slightly
    /// larger turn than entering it.
    func estimate(_ pose: HeadPose, currentDisplay: DisplayID?, edgeBias: Double) -> GazeEstimate?
    /// Add a labelled sample (from calibration dots, or weaker weight from user clicks).
    func addSample(_ pose: HeadPose, target: CGPoint, weight: Double)
    /// Refit the model from all samples. Returns false if there is not enough data.
    @discardableResult func fit() -> Bool
    func reset()
    func save() throws
    func load() throws
    /// Called when the user clicks: `predicted` is what we thought, `actual` where they clicked.
    func recordClickOutcome(predicted: DisplayID?, actual: DisplayID)
    /// 0...1, high when recent predictions keep missing => suggest recalibration.
    var driftScore: Double { get }
}

/// Full-screen dot calibration UI. Implemented by `CalibrationController`.
public protocol Calibrating: AnyObject {
    /// Runs the dot sequence over every display (extra points along shared edges),
    /// feeding samples into `mapper`, then calls `mapper.fit()` + `save()`.
    /// `completion(true)` on success, `false` if cancelled (Esc) or failed.
    func run(hub: PoseHub, mapper: GazeMapper, completion: @escaping (Bool) -> Void)
    func cancel()
}

// MARK: - Focus / input

/// Moves keyboard focus. Implemented by `AXFocusController` (Focus module).
public protocol FocusController: AnyObject {
    /// Bring forward the last window the user used on `display` (without a synthetic click),
    /// optionally warping the pointer there. Returns true if something was focused.
    @discardableResult
    func focusDisplay(_ display: DisplayID, gazePoint: CGPoint?, movePointer: Bool) -> Bool
    /// Focus the window / split pane under `point` on the current display.
    /// `clickFallback` allows a synthetic click in the middle of the target pane for
    /// known split-pane apps that refuse AX focus. Never clicks outside the target pane.
    @discardableResult
    func focusWithinDisplay(at point: CGPoint, clickFallback: Bool) -> Bool
    /// Display that currently owns keyboard focus (focused window's display).
    func focusedDisplay() -> DisplayID?
    /// Start tracking per-display window history (call once at launch).
    func startTracking()
}

/// Global keyboard / mouse activity. Implemented by `InputMonitor` (Focus module).
public protocol InputActivityMonitoring: AnyObject {
    var lastKeyTime: TimeInterval { get }    // systemUptime of last keyDown, 0 if never
    var lastMouseTime: TimeInterval { get }  // last mouse move/scroll/click/drag
    /// Real (non-synthetic) user clicks, CG global point, main queue.
    var onUserClick: ((CGPoint) -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - Settings

public struct Settings: Codable, Equatable {
    public var switchDelayMs: Double = 300        // dwell before switching displays
    public var headTurnThreshold: Double = 0.5    // edgeBias passed to the mapper
    public var windowFocusEnabled: Bool = true    // windows / panes on the same display
    public var paneDelayMs: Double = 300
    public var typingProtection: Bool = true
    public var typingPauseSec: Double = 2.0
    public var mousePriorityMs: Double = 1500
    public var movePointer: Bool = true
    public var showGazeDot: Bool = false
    public var cameraID: String? = nil
    public var learnFromClicks: Bool = true
    public var paneClickFallback: Bool = true
    public var paused: Bool = false
    public init() {}
}

// MARK: - Displays helper

public enum Displays {
    public struct Info: Equatable { public var id: DisplayID; public var frame: CGRect } // CG global
    public static func all() -> [Info] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { Info(id: $0, frame: CGDisplayBounds($0)) }
    }
    public static func display(containing p: CGPoint) -> DisplayID? {
        all().first { $0.frame.contains(p) }?.id
    }
    /// Cocoa (bottom-left origin, relative to primary screen) -> CG global (top-left origin).
    public static func cgRect(fromCocoa r: CGRect) -> CGRect {
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height)
    }
    public static func cocoaRect(fromCG r: CGRect) -> CGRect {
        let mainH = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height)
    }
    public static func displayID(of screen: NSScreen) -> DisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
