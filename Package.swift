// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ITimer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ITimer", targets: ["ITimer"])
    ],
    targets: [
        .target(name: "ITimerCore"),
        .executableTarget(
            name: "ITimer",
            dependencies: ["ITimerCore"],
            path: "Sources/ITimer"
        ),
        .testTarget(
            name: "ITimerCoreTests",
            dependencies: ["ITimerCore"]
        ),
    ]
)
