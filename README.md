# Glance Switch (personal clone)

Menu bar app: the camera tracks your head/eyes, and keyboard focus follows the
screen / window / split pane you look at — no click needed.

Layout (each folder has one owner during the initial build):
- `Sources/GlanceKit/Core/Contracts.swift` — frozen shared types/protocols
- `Sources/GlanceKit/Tracking/` — camera + Vision head pose (`CameraPoseTracker`)
- `Sources/GlanceKit/Calibration/` — gaze model + dot calibration UI (`RegressionGazeMapper`, `CalibrationController`)
- `Sources/GlanceKit/Focus/` — Accessibility focus + input monitor (`AXFocusController`, `InputMonitor`)
- `Sources/GlanceKit/App/` — menu bar shell, switching engine, settings, onboarding, `build.sh`
