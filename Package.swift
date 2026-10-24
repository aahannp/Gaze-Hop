// swift-tools-version:5.9
import PackageDescription

// Swift 5 language mode (tools 5.9) on purpose: AppKit/AVFoundation/AX callbacks
// are much less painful without Swift 6 strict concurrency.
let package = Package(
    name: "GlanceSwitch",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned exactly (supply chain). Used by the MediaPipe mesh tracker.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.19.2"),
    ],
    targets: [
        .target(name: "GlanceKit",
                dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
                path: "Sources/GlanceKit",
                resources: [.copy("Tracking/Models")]),
        .executableTarget(name: "GlanceSwitch", dependencies: ["GlanceKit"], path: "Sources/GlanceSwitch"),
        .testTarget(name: "GlanceSwitchTests", dependencies: ["GlanceKit"], path: "Tests/GlanceSwitchTests"),
    ]
)
