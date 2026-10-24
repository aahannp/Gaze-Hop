// Listen-only CGEventTap on a dedicated run-loop thread. Needs Input Monitoring permission.
import Foundation
import CoreGraphics

public final class InputMonitor: InputActivityMonitoring {
    private let lock = NSLock()
    private var _lastKey: TimeInterval = 0
    private var _lastMouse: TimeInterval = 0
    public var lastKeyTime: TimeInterval { lock.lock(); defer { lock.unlock() }; return _lastKey }
    public var lastMouseTime: TimeInterval { lock.lock(); defer { lock.unlock() }; return _lastMouse }
    public var onUserClick: ((CGPoint) -> Void)?

    private var thread: Thread?
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var running = false
    private let stateLock = NSLock()

    public init() {}

    public var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return running }

    public func start() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !running else { return }
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let t = Thread { [unowned self] in
            let types: [CGEventType] = [
                .keyDown, .flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .scrollWheel, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
            ]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .listenOnly, eventsOfInterest: mask,
                                               callback: inputTapCallback, userInfo: refcon) else {
                ready.signal(); return
            }
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let rl = CFRunLoopGetCurrent()
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self.tap = port; self.runLoop = rl; ok = true
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        t.name = "glance.input-monitor"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        if ok { thread = t; running = true }
        else { FileHandle.standardError.write(Data("InputMonitor: could not create event tap — grant Input Monitoring permission\n".utf8)) }
    }

    public func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard running else { return }
        if let rl = runLoop { CFRunLoopStop(rl) }
        thread = nil; tap = nil; runLoop = nil; running = false
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == GlanceSynthetic.userData { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        switch type {
        case .keyDown, .flagsChanged: _lastKey = now
        default: _lastMouse = now
        }
        lock.unlock()
        if type == .leftMouseDown || type == .rightMouseDown {
            let p = event.location
            DispatchQueue.main.async { [weak self] in self?.onUserClick?(p) }
        }
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon = refcon {
        Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
