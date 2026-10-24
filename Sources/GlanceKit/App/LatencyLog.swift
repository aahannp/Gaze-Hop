// OWNER: App worker. Opt-in switch-latency log: `defaults write com.aahan.glanceswitch glance.debugLatency -bool YES`
// Writes ~/Library/Logs/GlanceSwitch/latency.log. Only timings and display ids — no window titles or content.
import Foundation

public protocol LatencyLogging: AnyObject {
    var isEnabled: Bool { get }
    func log(_ line: String)
}

public final class LatencyLog: LatencyLogging {
    public static let defaultsKey = "glance.debugLatency"
    private let queue = DispatchQueue(label: "glance.latency-log")
    private let url: URL
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard, url: URL? = nil) {
        self.defaults = defaults
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GlanceSwitch/latency.log")
    }

    public var isEnabled: Bool { defaults.bool(forKey: Self.defaultsKey) }

    public func log(_ line: String) {
        guard isEnabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        queue.async { [url] in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile(); h.write(data); try? h.close()
        }
    }
}
