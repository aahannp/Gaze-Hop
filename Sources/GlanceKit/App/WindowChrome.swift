// OWNER: UI worker. Window chrome for the main window and the setup guide.
import AppKit
import SwiftUI

enum WindowChrome {
    typealias Maker = (NSRect, NSWindow.StyleMask) -> NSWindow
    static let plain: Maker = { NSWindow(contentRect: $0, styleMask: $1, backing: .buffered, defer: false) }

    static let mainSize = NSSize(width: 800, height: 640)
    static let mainAutosaveName = "GazeHop.MainWindow"

    /// Content runs under a transparent 52 pt title bar (an empty unified toolbar), so the
    /// sidebar reaches the top edge and the pane title sits level with the traffic lights.
    /// The hosting controller only reports a minimum size, so SwiftUI never resizes the window
    /// when a pane changes, and the view is laid out before the window is first shown.
    static func main<V: View>(_ content: V, make: Maker = plain) -> NSWindow {
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.minSize]
        let w = make(NSRect(origin: .zero, size: mainSize),
                     [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        w.contentViewController = host
        w.title = "GazeHop"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.toolbar = NSToolbar(identifier: "GazeHop.main")
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .none
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        w.setContentSize(mainSize)
        w.contentView?.layoutSubtreeIfNeeded()
        return w
    }

    /// A fixed-size window with no visible title bar, for the setup guide.
    static func panel<V: View>(_ content: V, title: String, size: CGSize, make: Maker = plain) -> NSWindow {
        let host = NSHostingController(rootView: content)
        host.sizingOptions = []
        let w = make(NSRect(origin: .zero, size: size), [.titled, .closable, .fullSizeContentView])
        w.contentViewController = host
        w.title = title
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        w.setContentSize(size)
        w.contentView?.layoutSubtreeIfNeeded()
        return w
    }
}
