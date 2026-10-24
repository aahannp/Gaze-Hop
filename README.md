# Glance Switch (personal clone)

Menu bar app: the camera tracks your head/eyes, and keyboard focus follows the
screen / window / split pane you look at — no click needed.

Layout (each folder has one owner during the initial build):
- `Sources/GlanceKit/Core/Contracts.swift` — frozen shared types/protocols
- `Sources/GlanceKit/Tracking/` — camera + Vision head pose (`CameraPoseTracker`)
- `Sources/GlanceKit/Calibration/` — gaze model + dot calibration UI (`RegressionGazeMapper`, `CalibrationController`)
- `Sources/GlanceKit/Focus/` — Accessibility focus + input monitor (`AXFocusController`, `InputMonitor`)
- `Sources/GlanceKit/App/` — menu bar shell, switching engine, settings, onboarding, `build.sh`

## Build & run

```sh
./build.sh            # swift build -c release -> build/GlanceSwitch.app (signed)
./build.sh install    # also copies to ~/Applications and launches
swift test            # unit tests (SwitchEngine etc.)
```

Requires macOS 14+. **Signing matters:** ad-hoc signing changes the code hash on every
rebuild and macOS then drops the Accessibility / Input Monitoring grants. `build.sh`
looks for a stable identity named `GlanceSwitch Dev`; if missing it offers (interactive
terminal only) to create a self-signed code-signing cert in your login keychain, and
otherwise falls back to ad-hoc with a warning. Set `SIGN_IDENTITY="<cert name or hash>"`
to use any other identity (e.g. an Apple Development cert).

## Permissions

Grant these in the Welcome window (menu bar eye → Welcome Guide):
- **Camera** — head pose tracking
- **Accessibility** — raising windows / focusing panes
- **Input Monitoring** — typing / mouse activity (typing protection, mouse priority, click learning)

You may need to relaunch the app after granting Accessibility or Input Monitoring.
Then **Calibrate** (look at each dot). Pause/resume anywhere with **⇧⌘G**.

## Debug flags
`GlanceSwitch --pose-debug | --focus-debug | --calib-demo`
