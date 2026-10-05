// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed, the test build intermittently fails to locate the
// Swift Testing macro plugin; naming its folder makes it reliable. Xcode (as on CI) needs nothing.
let testingPluginFolder = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPluginFolder)
    ? [.unsafeFlags(["-plugin-path", testingPluginFolder])]
    : []

let package = Package(
    name: "MetalCap",
    platforms: [.macOS(.v14)],
    targets: [
        // IOReport is a private system library, used for CPU and GPU power.
        .target(name: "MetalCapCore", linkerSettings: [.linkedLibrary("IOReport")]),
        .executableTarget(name: "MetalCap", dependencies: ["MetalCapCore"]),
        // A minimal Metal app the end-to-end tests measure.
        .executableTarget(name: "MetalCapProbe"),
        .testTarget(name: "MetalCapCoreTests", dependencies: ["MetalCapCore"], swiftSettings: testSettings),
        // Run with Scripts/e2e.sh; without its environment the tests are skipped.
        .testTarget(name: "MetalCapEndToEndTests", dependencies: ["MetalCapCore"], swiftSettings: testSettings),
    ],
    swiftLanguageModes: [.v5]
)
