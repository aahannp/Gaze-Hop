// Pure (AX-free) parts of the focus controller so they can be unit-tested.
import Foundation
import CoreGraphics

/// Marker for synthetic events we post, so `InputMonitor` can ignore them.
public enum GlanceSynthetic {
    /// Stored in kCGEventSourceUserData of events we generate ("GLANCE").
    public static let userData: Int64 = 0x474C_414E_4345
}

public struct WindowSnapshot: Equatable {
    public var id: UInt32
    public var pid: pid_t
    public var bounds: CGRect   // CG global coords
    public var layer: Int
    public var alpha: Double
    public init(id: UInt32, pid: pid_t, bounds: CGRect, layer: Int = 0, alpha: Double = 1) {
        self.id = id; self.pid = pid; self.bounds = bounds; self.layer = layer; self.alpha = alpha
    }
}

public enum FocusLogic {
    static let minWindowSide: CGFloat = 50

    /// Normal, visible, reasonably sized, not ours.
    static func isCandidate(_ w: WindowSnapshot, excludingPID: pid_t) -> Bool {
        w.layer == 0 && w.alpha > 0.01 && w.pid != excludingPID
            && w.bounds.width >= minWindowSide && w.bounds.height >= minWindowSide
    }

    /// `windows` is ordered front-to-back (CGWindowList order).
    public static func windowUnder(_ p: CGPoint, in windows: [WindowSnapshot], excludingPID: pid_t) -> WindowSnapshot? {
        windows.first { isCandidate($0, excludingPID: excludingPID) && $0.bounds.contains(p) }
    }

    /// Display containing the rect's center; falls back to the largest overlap.
    public static func displayOf(_ rect: CGRect, displays: [Displays.Info]) -> DisplayID? {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        if let d = displays.first(where: { $0.frame.contains(c) }) { return d.id }
        return displays.max { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }
            .flatMap { area($0.frame.intersection(rect)) > 0 ? $0.id : nil }
    }

    static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    public static func topWindow(on display: DisplayID, in windows: [WindowSnapshot],
                                 displays: [Displays.Info], excludingPID: pid_t) -> WindowSnapshot? {
        windows.first {
            isCandidate($0, excludingPID: excludingPID) && displayOf($0.bounds, displays: displays) == display
        }
    }

    /// First id in `history` (most recent first) that is currently visible on `display`.
    public static func mruWindow(on display: DisplayID, history: [UInt32], windows: [WindowSnapshot],
                                 displays: [Displays.Info], excludingPID: pid_t) -> WindowSnapshot? {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in history {
            if let w = byID[id], isCandidate(w, excludingPID: excludingPID),
               displayOf(w.bounds, displays: displays) == display { return w }
        }
        return nil
    }

    /// Move `id` to the front of an MRU list.
    public static func touch(_ id: UInt32, in history: [UInt32], limit: Int = 64) -> [UInt32] {
        Array(([id] + history.filter { $0 != id }).prefix(limit))
    }

    // MARK: split-pane apps

    static let splitPaneBundleIDs: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "com.vscodium", "dev.zed.Zed", "com.sublimetext.4", "com.apple.dt.Xcode",
        "com.google.android.studio",
    ]

    public static func isSplitPaneApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return splitPaneBundleIDs.contains(id) || id.hasPrefix("com.jetbrains.")
    }

    /// Is an AX element with this role (and parent role) a pane we can focus?
    public static func isPaneLevel(role: String?, parentRole: String?) -> Bool {
        switch role {
        case "AXTextArea", "AXScrollArea": return true
        case "AXGroup": return parentRole == "AXSplitGroup"
        default: return false
        }
    }
}
