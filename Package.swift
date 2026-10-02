// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalCap",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MetalCapCore"),
        .executableTarget(name: "MetalCap", dependencies: ["MetalCapCore"]),
        .testTarget(
            name: "MetalCapCoreTests",
            dependencies: ["MetalCapCore"],
            // With only the Command Line Tools installed, the build intermittently fails to
            // locate the Swift Testing macro plugin; naming its folder makes it reliable.
            swiftSettings: [.unsafeFlags([
                "-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
            ])]),
    ],
    swiftLanguageModes: [.v5]
)
