// OWNER: Tracking worker.
// Public PoseSource backed by the MediaPipe mesh estimator, plus the `glance.tracker` switch.
import Foundation

public final class MeshPoseTracker: PoseSource {
    private let inner: CameraPoseTracker

    /// nil if the model files can't be found.
    public init?() {
        guard let est = MeshPoseEstimator() else { return nil }
        inner = CameraPoseTracker(estimator: est)
    }

    public var onPose: ((HeadPose?) -> Void)? {
        get { inner.onPose } set { inner.onPose = newValue }
    }
    public var isRunning: Bool { inner.isRunning }
    public func start(cameraID: String?) throws { try inner.start(cameraID: cameraID) }
    public func stop() { inner.stop() }
    public static func availableCameras() -> [CameraInfo] { CameraPoseTracker.availableCameras() }
}

public enum PoseTrackerFactory {
    public static let defaultsKey = "glance.tracker"   // "vision" (default) | "mesh"

    /// Honors UserDefaults `glance.tracker`; falls back to Vision if mesh is unavailable.
    public static func make() -> PoseSource {
        if UserDefaults.standard.string(forKey: defaultsKey) == "mesh", let mesh = MeshPoseTracker() { return mesh }
        return CameraPoseTracker()
    }
}
