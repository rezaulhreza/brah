// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Brah",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BrahCore"),
        .executableTarget(name: "Brah", dependencies: ["BrahCore"]),
        .testTarget(name: "BrahCoreTests", dependencies: ["BrahCore"]),
    ]
)
