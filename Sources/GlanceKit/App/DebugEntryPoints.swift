// TEMPORARY — DELETE THIS FILE AT INTEGRATION.
// Placeholder debug entry points so main.swift compiles before the Tracking / Focus /
// Calibration workers merge their real `runDebugCLI()` / `runDemo()` statics.
import Foundation

extension CameraPoseTracker {
    public static func runDebugCLI() { print("--pose-debug: not implemented yet") }
}
extension AXFocusController {
    public static func runDebugCLI() { print("--focus-debug: not implemented yet") }
}
extension CalibrationController {
    public static func runDemo() { print("--calib-demo: not implemented yet") }
}
