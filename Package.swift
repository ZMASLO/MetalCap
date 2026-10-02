// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalCap",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MetalCapCore"),
        .executableTarget(name: "MetalCap", dependencies: ["MetalCapCore"]),
        .testTarget(name: "MetalCapCoreTests", dependencies: ["MetalCapCore"]),
    ],
    swiftLanguageModes: [.v5]
)
