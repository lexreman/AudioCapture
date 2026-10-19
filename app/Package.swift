// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioCapture",
    platforms: [.macOS("14.4")],   // process taps arrived in macOS 14.2; 14.4 is the oldest macOS this app supports
    targets: [
        .target(name: "EngineSync"),
        .target(name: "AudioCaptureKit", dependencies: ["EngineSync"]),
        .executableTarget(name: "AudioCapture", dependencies: ["AudioCaptureKit"]),
        .executableTarget(name: "IconTool", dependencies: ["AudioCaptureKit"]),
    ]
)
