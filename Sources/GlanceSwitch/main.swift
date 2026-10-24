import Foundation
import GlanceKit

// Debug entry points are implemented by the Tracking / Focus / Calibration modules.
switch CommandLine.arguments.dropFirst().first {
case "--pose-debug": CameraPoseTracker.runDebugCLI()
case "--pose-check": CameraPoseTracker.runGuidedCheck(logPath: logPathArgument())
case "--focus-debug": AXFocusController.runDebugCLI()
case "--calib-demo": CalibrationController.runDemo()
default: GlanceApp.run()
}

/// Value after `--log`, if given.
func logPathArgument() -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--log"), i + 1 < args.count else { return nil }
    return args[i + 1]
}
