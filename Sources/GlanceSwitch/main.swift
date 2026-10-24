import Foundation
import GlanceKit

// Debug entry points are implemented by the Tracking / Focus / Calibration modules.
switch CommandLine.arguments.dropFirst().first {
case "--pose-debug": CameraPoseTracker.runDebugCLI()
case "--focus-debug": AXFocusController.runDebugCLI()
case "--calib-demo": CalibrationController.runDemo()
default: GlanceApp.run()
}
