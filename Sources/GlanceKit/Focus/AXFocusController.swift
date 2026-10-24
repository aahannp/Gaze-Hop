// Accessibility-based focus controller. Main-thread only. Needs Accessibility permission.
import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - AX helpers

private func axAttr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
private func axElement(_ e: AXUIElement, _ name: String) -> AXUIElement? {
    guard let v = axAttr(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
private func axString(_ e: AXUIElement, _ name: String) -> String? { axAttr(e, name) as? String }
private func axBool(_ e: AXUIElement, _ name: String) -> Bool { (axAttr(e, name) as? Bool) ?? false }
private func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axAttr(e, kAXPositionAttribute), let s = axAttr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}
private func axWindowID(_ e: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(e, &id) == .success && id != 0 ? id : nil
}
private func axPID(_ e: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    return AXUIElementGetPid(e, &pid) == .success ? pid : nil
}

private func isAncestorOrSelf(_ ancestor: AXUIElement, of e: AXUIElement) -> Bool {
    var cur: AXUIElement? = e
    for _ in 0..<40 {
        guard let c = cur else { return false }
        if CFEqual(c, ancestor) { return true }
        cur = axElement(c, kAXParentAttribute)
    }
    return false
}

// MARK: - Controller

public final class AXFocusController: FocusController {
    struct Entry { var pid: pid_t; var element: AXUIElement; var windowID: UInt32 }

    private var history: [Entry] = []          // most recent first
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observedApp: AXUIElement?
    private var tracking = false
    private let myPID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    // MARK: tracking

    public func startTracking() {
        guard !tracking else { return }
        tracking = true
        // Seed from every running app, frontmost last so it ends up most recent.
        let front = NSWorkspace.shared.frontmostApplication
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != front {
            recordFocusedWindow(pid: app.processIdentifier)
        }
        if let f = front { recordFocusedWindow(pid: f.processIdentifier); attachObserver(pid: f.processIdentifier) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appActivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        recordFocusedWindow(pid: app.processIdentifier)
        attachObserver(pid: app.processIdentifier)
    }

    private func attachObserver(pid: pid_t) {
        if pid == observedPID { return }
        detachObserver()
        guard pid != myPID else { return }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, refcon in
            guard let refcon = refcon else { return }
            let me = Unmanaged<AXFocusController>.fromOpaque(refcon).takeUnretainedValue()
            if let pid = axPID(element) { me.recordFocusedWindow(pid: pid) }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let o = obs else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(o, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(o, app, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        observer = o; observedPID = pid; observedApp = app
    }

    private func detachObserver() {
        if let o = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        }
        observer = nil; observedPID = 0; observedApp = nil
    }

    private func recordFocusedWindow(pid: pid_t) {
        guard pid != myPID else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let win = axElement(app, kAXFocusedWindowAttribute) ?? axElement(app, kAXMainWindowAttribute),
              let id = axWindowID(win), !axBool(win, kAXMinimizedAttribute) else { return }
        if let sub = axString(win, kAXSubroleAttribute), sub != "AXStandardWindow", sub != "AXDialog" { return }
        history.removeAll { $0.windowID == id }
        history.insert(Entry(pid: pid, element: win, windowID: id), at: 0)
        if history.count > 64 { history.removeLast(history.count - 64) }
    }

    /// Drop windows that were closed (AX element gone) or minimized.
    private func prune() {
        history.removeAll { e in
            var role: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(e.element, kAXRoleAttribute as CFString, &role)
            if err == .invalidUIElement || err == .cannotComplete && NSRunningApplication(processIdentifier: e.pid) == nil { return true }
            return axBool(e.element, kAXMinimizedAttribute)
        }
    }

    // MARK: window list

    private func windowList() -> [WindowSnapshot] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return info.compactMap { d in
            guard let num = d[kCGWindowNumber as String] as? UInt32,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bd) else { return nil }
            return WindowSnapshot(id: num, pid: pid, bounds: rect,
                                  layer: d[kCGWindowLayer as String] as? Int ?? 0,
                                  alpha: d[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    private func axWindow(for w: WindowSnapshot) -> AXUIElement? {
        if let e = history.first(where: { $0.windowID == w.id }) { return e.element }
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let wins = axAttr(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return wins.first { axWindowID($0) == w.id }
    }

    // MARK: FocusController

    @discardableResult
    public func focusDisplay(_ display: DisplayID, gazePoint: CGPoint?, movePointer: Bool) -> Bool {
        prune()
        let wins = windowList()
        let displays = Displays.all()
        guard let info = displays.first(where: { $0.id == display }) else { return false }

        var target: WindowSnapshot?
        if let g = gazePoint, info.frame.contains(g) {
            target = FocusLogic.windowUnder(g, in: wins, excludingPID: myPID)
        }
        if target == nil {
            target = FocusLogic.mruWindow(on: display, history: history.map { $0.windowID }, windows: wins,
                                          displays: displays, excludingPID: myPID)
        }
        if target == nil {
            target = FocusLogic.topWindow(on: display, in: wins, displays: displays, excludingPID: myPID)
        }

        if movePointer {
            let p: CGPoint
            if let g = gazePoint, info.frame.contains(g) { p = g }
            else if let t = target { p = CGPoint(x: t.bounds.midX, y: t.bounds.midY) }
            else { p = CGPoint(x: info.frame.midX, y: info.frame.midY) }
            warpPointer(to: clamp(p, to: info.frame))
        }
        guard let t = target else { return false }
        return activate(t)
    }

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
    }

    private func warpPointer(to p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Activate the app and raise the specific window — no synthetic click.
    @discardableResult
    private func activate(_ w: WindowSnapshot) -> Bool {
        guard let win = axWindow(for: w) else { return false }
        let appEl = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, win)
        let r = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        recordFocusedWindow(pid: w.pid)
        return r == .success
    }

    @discardableResult
    public func focusWithinDisplay(at point: CGPoint, clickFallback: Bool) -> Bool {
        let wins = windowList()
        guard let under = FocusLogic.windowUnder(point, in: wins, excludingPID: myPID) else { return false }

        let front = NSWorkspace.shared.frontmostApplication
        let focusedWinID = front.flatMap { app -> UInt32? in
            let a = AXUIElementCreateApplication(app.processIdentifier)
            return axElement(a, kAXFocusedWindowAttribute).flatMap(axWindowID)
        }
        if front?.processIdentifier != under.pid || focusedWinID != under.id {
            return activate(under)
        }
        guard FocusLogic.isSplitPaneApp(front?.bundleIdentifier) else { return true }
        return focusPane(pid: under.pid, at: point, clickFallback: clickFallback)
    }

    private func focusPane(pid: pid_t, at point: CGPoint, clickFallback: Bool) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appEl, Float(point.x), Float(point.y), &hit) == .success,
              let start = hit, let pane = paneElement(from: start) else { return true }

        func paneFocused() -> Bool {
            guard let f = axElement(appEl, kAXFocusedUIElementAttribute) else { return false }
            return isAncestorOrSelf(pane, of: f)
        }
        if paneFocused() { return true }
        AXUIElementSetAttributeValue(pane, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if paneFocused() { return true }
        guard clickFallback, let frame = axFrame(pane), frame.width > 1, frame.height > 1 else { return false }
        syntheticClick(at: CGPoint(x: frame.midX, y: frame.midY))
        return true
    }

    private func paneElement(from e: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = e
        for _ in 0..<12 {
            guard let c = cur else { return nil }
            let parent = axElement(c, kAXParentAttribute)
            if FocusLogic.isPaneLevel(role: axString(c, kAXRoleAttribute),
                                      parentRole: parent.flatMap { axString($0, kAXRoleAttribute) }) { return c }
            if axString(c, kAXRoleAttribute) == "AXWindow" { return nil }
            cur = parent
        }
        return nil
    }

    /// One left click at `p`, then put the pointer back where it was.
    private func syntheticClick(at p: CGPoint) {
        let saved = CGEvent(source: nil)?.location ?? p
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            else { continue }
            ev.setIntegerValueField(.eventSourceUserData, value: GlanceSynthetic.userData)
            ev.post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public func focusedDisplay() -> DisplayID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let a = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(a, 0.5)
        guard let win = axElement(a, kAXFocusedWindowAttribute), let f = axFrame(win) else { return nil }
        return FocusLogic.displayOf(f, displays: Displays.all())
    }

    // MARK: debugging

    public func debugMRU() -> String {
        prune()
        let wins = Dictionary(windowList().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let displays = Displays.all()
        var out = ""
        for (i, d) in displays.enumerated() {
            out += "display \(i) (id \(d.id), \(Int(d.frame.width))x\(Int(d.frame.height)) @ \(Int(d.frame.minX)),\(Int(d.frame.minY))):\n"
            let mine = history.filter { e in
                wins[e.windowID].flatMap { FocusLogic.displayOf($0.bounds, displays: displays) } == d.id
            }
            if mine.isEmpty { out += "  (none)\n" }
            for e in mine {
                let name = NSRunningApplication(processIdentifier: e.pid)?.localizedName ?? "pid \(e.pid)"
                out += "  \(name) — \(axString(e.element, kAXTitleAttribute) ?? "") [win \(e.windowID)]\n"
            }
        }
        return out
    }

    public static func runDebugCLI() {
        func log(_ s: String) {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
            print("[\(f.string(from: Date()))] \(s)"); fflush(stdout)
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            print("""
            Accessibility permission missing. Grant it to this terminal app in
            System Settings > Privacy & Security > Accessibility (and Input Monitoring), then rerun.
            """)
        }
        let ctl = AXFocusController()
        ctl.startTracking()
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "focus", args.count > 1, let idx = Int(args[1]) {
            let displays = Displays.all()
            guard displays.indices.contains(idx) else { print("no display \(idx) (have \(displays.count))"); exit(1) }
            log("focusing display \(idx)")
            let ok = ctl.focusDisplay(displays[idx].id, gazePoint: nil, movePointer: true)
            log("pointer now \(CGEvent(source: nil)?.location ?? .zero)")
            log("focusDisplay -> \(ok); focusedDisplay now \(String(describing: ctl.focusedDisplay()))")
            if let app = NSWorkspace.shared.frontmostApplication { log("frontmost: \(app.localizedName ?? "?")") }
            // Give the activation a moment, then exit so the next keystrokes go to the target.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                log("frontmost after 0.5s: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), display \(String(describing: ctl.focusedDisplay()))")
                exit(ok ? 0 : 2)
            }
            RunLoop.main.run()
        }
        let mon = InputMonitor()
        mon.onUserClick = { p in log("click at \(Int(p.x)),\(Int(p.y))") }
        mon.start()
        if !mon.isRunning { print("Input Monitoring permission missing: System Settings > Privacy & Security > Input Monitoring") }
        var lastKey = mon.lastKeyTime
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            if mon.lastKeyTime != lastKey { lastKey = mon.lastKeyTime; log("key") }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            log("MRU:\n" + ctl.debugMRU() + "focusedDisplay: \(String(describing: ctl.focusedDisplay()))")
        }
        RunLoop.main.run()
    }
}
