// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bruh",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BruhCore"),
        .executableTarget(name: "Bruh", dependencies: ["BruhCore"]),
        .testTarget(name: "BruhCoreTests", dependencies: ["BruhCore"]),
    ]
)
