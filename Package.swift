// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iTimer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iTimer", targets: ["iTimer"])
    ],
    targets: [
        .target(name: "ITimerCore"),
        .executableTarget(
            name: "iTimer",
            dependencies: ["ITimerCore"],
            path: "Sources/ITimer"
        ),
        .testTarget(
            name: "ITimerCoreTests",
            dependencies: ["ITimerCore"]
        ),
    ]
)
