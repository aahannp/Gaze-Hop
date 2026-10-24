// swift-tools-version:5.9
import PackageDescription

// Swift 5 language mode (tools 5.9) on purpose: AppKit/AVFoundation/AX callbacks
// are much less painful without Swift 6 strict concurrency.
let package = Package(
    name: "GlanceSwitch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GlanceKit", path: "Sources/GlanceKit"),
        .executableTarget(name: "GlanceSwitch", dependencies: ["GlanceKit"], path: "Sources/GlanceSwitch"),
        .testTarget(name: "GlanceSwitchTests", dependencies: ["GlanceKit"], path: "Tests/GlanceSwitchTests"),
    ]
)
