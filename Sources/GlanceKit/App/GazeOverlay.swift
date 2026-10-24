// OWNER: App worker. Click-through gaze dot + HUD, one transparent window per display.
import AppKit

final class GazeOverlay {
    private var windows: [DisplayID: (NSWindow, OverlayView)] = [:]
    private(set) var isVisible = false
    private var screenObserver: NSObjectProtocol?

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            rebuild()
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.rebuild() }
        } else {
            if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
            screenObserver = nil
            windows.values.forEach { $0.0.orderOut(nil) }
            windows.removeAll()
        }
    }

    private func rebuild() {
        windows.values.forEach { $0.0.orderOut(nil) }
        windows.removeAll()
        for screen in NSScreen.screens {
            guard let id = Displays.displayID(of: screen) else { continue }
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            let v = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.displayID = id
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows[id] = (w, v)
        }
    }

    func update(_ state: SwitchEngine.State) {
        guard isVisible else { return }
        for (id, entry) in windows {
            let view = entry.1
            if let e = state.estimate {
                let cocoa = Displays.cocoaRect(fromCG: CGRect(origin: e.point, size: .zero)).origin
                view.dot = CGPoint(x: cocoa.x - entry.0.frame.minX, y: cocoa.y - entry.0.frame.minY)
                view.confidence = e.confidence
            } else {
                view.dot = nil
            }
            view.isCurrent = state.currentDisplay == id
            view.status = hudText(state, id: id)
            view.needsDisplay = true
        }
    }

    private func hudText(_ s: SwitchEngine.State, id: DisplayID) -> String? {
        guard s.currentDisplay == id || (s.currentDisplay == nil && id == CGMainDisplayID()) else { return nil }
        var parts = ["Display \(Displays.all().firstIndex { $0.id == id }.map { $0 + 1 } ?? 0)"]
        if s.paused { parts.append("paused") }
        switch s.hold {
        case .typing: parts.append("typing hold")
        case .mouse: parts.append("mouse priority")
        case nil: break
        }
        if let e = s.estimate, e.displayID == nil { parts.append("off-screen") }
        return parts.joined(separator: " · ")
    }
}

private final class OverlayView: NSView {
    var displayID: DisplayID = 0
    var dot: CGPoint?
    var confidence = 1.0
    var isCurrent = false
    var status: String?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if let dot {
            let r: CGFloat = 9
            let rect = CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)
            NSColor.systemRed.withAlphaComponent(0.25 + 0.45 * confidence).setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)); ring.lineWidth = 2; ring.stroke()
        }
        if let status {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let str = NSAttributedString(string: status, attributes: attrs)
            let size = str.size()
            let box = CGRect(x: bounds.midX - size.width / 2 - 10, y: bounds.maxY - 56,
                             width: size.width + 20, height: size.height + 10)
            NSColor.black.withAlphaComponent(0.65).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            str.draw(at: CGPoint(x: box.minX + 10, y: box.minY + 5))
        }
    }
}
