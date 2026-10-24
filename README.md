# GazeHop

A macOS menu bar app that moves keyboard focus to wherever you look. The webcam tracks your
head and eyes. Glance at another monitor and its last-used window gets focus; glance at
another window or split pane on the same screen and that one gets focus. You don't need to
click or use a shortcut.

Everything runs on your Mac. Camera frames are processed in memory and never saved or sent anywhere.

## Features

- **Head, eyes, or both.** In Settings, choose what decides where you're looking: head
  turns only, eye movement only (head pose only compensates), or a blend with an adjustable
  eye weight.
- **Two trackers.** Apple Vision face landmarks (the default), or Google's MediaPipe Face
  Landmarker run with ONNX Runtime (478 landmarks with iris points, which track the eyes
  better). Each tracker keeps its own calibration.
- **Guided calibration.** A full-screen dot sequence across all displays. Calibrations are
  saved per display arrangement, so plugging in or moving a monitor brings back the right
  one, or asks you to recalibrate.
- **Live view.** A 3D cartoon head that copies your head pose, eye direction and blinks in
  real time, plus a to-scale map of your displays with the current gaze point. Use it to
  see how well you're calibrated.
- **Stays out of your way.** Typing protection (no switching mid-sentence), mouse priority,
  a flicker guard, blink rejection, and looking down at the keyboard reads as "off-screen"
  rather than as the laptop screen.
- **Learns from clicks.** Each real click quietly refines the model, and a drift score
  suggests recalibrating when predictions keep missing.

## Requirements

macOS 14 or later and a webcam (built-in or external). Built with Swift 5.9 or later (Xcode 15+).

## Install and updates

Download `GazeHop-<version>.dmg` from the latest GitHub release and drag GazeHop to Applications.
GazeHop checks GitHub for a newer release on launch and every 6 hours (Settings → Updates to turn
that off). Installing an update downloads the dmg from GitHub, checks that it is signed by the same
signer with the same bundle id as the running app, replaces `/Applications/GazeHop.app` and relaunches.

## Build and run

```sh
./build.sh            # swift build -c release -> build/GazeHop-<version>.dmg (signed)
./build.sh install    # also installs /Applications/GazeHop.app and launches it
swift test            # unit tests
./release.sh [patch|minor|major|X.Y.Z]   # bump VERSION, build, tag, `gh release create`
```

The `.app` only exists in a temporary staging folder and in `/Applications`; `build/` holds just the dmg.
The version lives in `VERSION`. (The Swift targets, bundle id `com.aahan.glanceswitch` and the
`Application Support/GlanceSwitch` folder keep their old names so camera/Accessibility grants and
calibration carry over from Glance Switch.)

The app bundle and Swift targets still use the working name `GlanceSwitch`.

**Signing matters.** Ad-hoc signing changes the code hash on every rebuild, and macOS then
drops the Accessibility and Input Monitoring grants. `build.sh` looks for a stable identity
named `GlanceSwitch Dev`. If it's missing, the script offers to create a self-signed
code-signing certificate (interactive terminal only). Set `SIGN_IDENTITY="<name or SHA-1>"`
to use any other identity, such as an Apple Development certificate. The bundle is assembled
and signed in `$TMPDIR`, because iCloud-synced folders add extended attributes that codesign rejects.

## Permissions

The Welcome window (menu bar eye → Welcome Guide) walks you through:

- **Camera**: face tracking
- **Accessibility**: raising windows and focusing panes
- **Input Monitoring**: typing and mouse activity (typing protection, mouse priority, click learning)

You may need to relaunch after granting Accessibility or Input Monitoring. Then calibrate.
Pause or resume anywhere with **⇧⌘G**.

## Layout

- `Sources/GlanceKit/Core/Contracts.swift`: the shared types and protocols
- `Sources/GlanceKit/Tracking/`: the camera, the Vision tracker (`CameraPoseTracker`), the MediaPipe tracker (`MeshPoseTracker`) and smoothing
- `Sources/GlanceKit/Tracking/Models/`: the MediaPipe models as ONNX (see the README there for provenance and checksums)
- `Sources/GlanceKit/Calibration/`: gaze regression, the display classifier and the dot calibration UI
- `Sources/GlanceKit/Focus/`: Accessibility focus control and the input monitor
- `Sources/GlanceKit/App/`: the menu bar shell, switching engine, settings, live view and onboarding

## Debugging

```sh
GlanceSwitch --pose-debug | --focus-debug | --calib-demo | --mesh-bench
defaults write com.aahan.glanceswitch glance.debugLatency -bool YES   # ~/Library/Logs/GlanceSwitch/latency.log
defaults write com.aahan.glanceswitch glance.debugTrace -bool YES     # per-frame trace.csv
defaults write com.aahan.glanceswitch glance.tracker mesh             # use the MediaPipe tracker
```

## License

The code is MIT (see `LICENSE`). The bundled MediaPipe Face Landmarker models are © Google,
Apache-2.0 (see `NOTICE`). This is an independent personal project, not affiliated with any
commercial gaze-switching product.
