// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hop",
    platforms: [.macOS(.v26)],
    targets: [
        // Everything testable without a window: matching, the calculator, the app
        // index, clipboard history and the clients for my own services.
        .target(name: "HopCore"),
        .executableTarget(name: "Hop", dependencies: ["HopCore"]),
        .testTarget(name: "HopCoreTests", dependencies: ["HopCore"]),
    ]
)
