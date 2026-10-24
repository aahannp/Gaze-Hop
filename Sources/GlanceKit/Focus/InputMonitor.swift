// OWNER: Focus worker. Stub — replace with a listen-only CGEventTap implementation.
import Foundation
import CoreGraphics

public final class InputMonitor: InputActivityMonitoring {
    public private(set) var lastKeyTime: TimeInterval = 0
    public private(set) var lastMouseTime: TimeInterval = 0
    public var onUserClick: ((CGPoint) -> Void)?
    public init() {}
    public func start() {}
    public func stop() {}
}
