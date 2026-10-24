// OWNER: Focus worker. Stub — replace with the Accessibility implementation.
import Foundation
import CoreGraphics

public final class AXFocusController: FocusController {
    public init() {}
    @discardableResult
    public func focusDisplay(_ display: DisplayID, gazePoint: CGPoint?, movePointer: Bool) -> Bool { false }
    @discardableResult
    public func focusWithinDisplay(at point: CGPoint, clickFallback: Bool) -> Bool { false }
    public func focusedDisplay() -> DisplayID? { nil }
    public func startTracking() {}
}
