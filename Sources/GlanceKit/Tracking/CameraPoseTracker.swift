// OWNER: Tracking worker. Stub — replace with AVFoundation + Vision implementation.
import Foundation

public final class CameraPoseTracker: PoseSource {
    public var onPose: ((HeadPose?) -> Void)?
    public private(set) var isRunning = false
    public init() {}
    public func start(cameraID: String?) throws { isRunning = true }
    public func stop() { isRunning = false }
    public static func availableCameras() -> [CameraInfo] { [] }
}
