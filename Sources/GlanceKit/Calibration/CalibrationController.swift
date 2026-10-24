// OWNER: Calibration worker. Stub — replace with the full-screen dot UI.
import Foundation

public final class CalibrationController: Calibrating {
    public init() {}
    public func run(hub: PoseHub, mapper: GazeMapper, completion: @escaping (Bool) -> Void) { completion(false) }
    public func cancel() {}
}
