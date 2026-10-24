// OWNER: App worker. Opt-in per-frame trace for offline replay against a mapper:
// `defaults write com.aahan.glanceswitch glance.debugTrace -bool YES`
// Writes ~/Library/Logs/GlanceSwitch/trace.csv (rotated to trace.1.csv past ~5 MB). Numbers only.
import Foundation

public protocol TraceLogging: AnyObject {
    var isEnabled: Bool { get }
    func write(_ row: String)
}

public final class TraceLog: TraceLogging {
    public static let defaultsKey = "glance.debugTrace"
    public static let header = "t,yaw,pitch,roll,fx,fy,faceSize,eyeDx,eyeDy,confidence,estX,estY,estDisplay,currentDisplay,hold,candidate"
    public static let maxBytes = 5_000_000

    private let queue = DispatchQueue(label: "glance.trace-log")
    private let url: URL
    private let defaults: UserDefaults
    private let maxBytes: Int
    private var handle: FileHandle?
    private var size = 0
    private var buffer = ""
    private var pending = 0

    public init(defaults: UserDefaults = .standard, url: URL? = nil, maxBytes: Int = TraceLog.maxBytes) {
        self.defaults = defaults
        self.maxBytes = maxBytes
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GlanceSwitch/trace.csv")
    }

    public var isEnabled: Bool { defaults.bool(forKey: Self.defaultsKey) }

    public func write(_ row: String) {
        guard isEnabled else { return }
        queue.async { [self] in
            buffer += row + "\n"; pending += 1
            if pending >= 15 { flush() }     // ~1 s at 15 Hz
        }
    }

    /// Blocks until queued rows are on disk (tests, shutdown).
    public func sync() { queue.sync { flush() } }

    private func open() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = !fm.fileExists(atPath: url.path)
        if fresh { fm.createFile(atPath: url.path, contents: Data((Self.header + "\n").utf8)) }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        size = Int(h.seekToEndOfFile())
        handle = h
        return h
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        let data = Data(buffer.utf8)
        buffer = ""; pending = 0
        guard let h = open() else { return }
        h.write(data); size += data.count
        if size >= maxBytes { rotate() }
    }

    private func rotate() {
        try? handle?.close(); handle = nil
        let fm = FileManager.default
        let old = url.deletingLastPathComponent().appendingPathComponent("trace.1.csv")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
        size = 0
    }
}
