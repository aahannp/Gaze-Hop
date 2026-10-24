// OWNER: Calibration worker. Stub — replace with the real model.
import Foundation
import CoreGraphics

public final class RegressionGazeMapper: GazeMapper {
    public init() {}
    public var isCalibrated: Bool { false }
    public func estimate(_ pose: HeadPose, currentDisplay: DisplayID?, edgeBias: Double) -> GazeEstimate? { nil }
    public func addSample(_ pose: HeadPose, target: CGPoint, weight: Double) {}
    @discardableResult public func fit() -> Bool { false }
    public func reset() {}
    public func save() throws {}
    public func load() throws {}
    public func recordClickOutcome(predicted: DisplayID?, actual: DisplayID) {}
    public var driftScore: Double { 0 }
}
