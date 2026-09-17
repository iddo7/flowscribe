// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlowScribe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FlowScribe",
            path: "Sources/FlowScribe"
        ),
        .testTarget(
            name: "FlowScribeTests",
            dependencies: ["FlowScribe"],
            path: "Tests/FlowScribeTests"
        )
    ]
)
