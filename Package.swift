// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "clippeek",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ClippeekCore"),
        .executableTarget(name: "ClippeekApp", dependencies: ["ClippeekCore"]),
        .testTarget(name: "ClippeekCoreTests", dependencies: ["ClippeekCore"]),
    ]
)
