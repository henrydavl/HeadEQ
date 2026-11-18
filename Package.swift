// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HeadEQ",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "EQCore", path: "Sources/EQCore"),
        .executableTarget(name: "HeadEQ", dependencies: ["EQCore"], path: "Sources/HeadEQ"),
        .testTarget(name: "EQCoreTests", dependencies: ["EQCore"], path: "Tests/EQCoreTests"),
        .testTarget(name: "HeadEQTests", dependencies: ["HeadEQ"], path: "Tests/HeadEQTests"),
    ]
)
