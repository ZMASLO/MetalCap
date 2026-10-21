// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Building with the Command Line Tools, the test build intermittently fails to locate the Swift
// Testing macro plugin; naming its folder makes it reliable. Only for that toolchain: with Xcode
// selected (as on CI) the folder may still exist but belongs to a different compiler.
let commandLineTools = "/Library/Developer/CommandLineTools"
let selectedDeveloperDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
let testingPluginFolder = commandLineTools + "/usr/lib/swift/host/plugins/testing"
// No selection at all means the default, the Command Line Tools.
let usesCommandLineTools = selectedDeveloperDir.map { $0.hasPrefix(commandLineTools) } ?? true
let testSettings: [SwiftSetting] = usesCommandLineTools && FileManager.default.fileExists(atPath: testingPluginFolder)
    ? [.unsafeFlags(["-plugin-path", testingPluginFolder])]
    : []

let package = Package(
    name: "MetalCap",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MetalCapCore"),
        .executableTarget(name: "MetalCap", dependencies: ["MetalCapCore"]),
        // A minimal Metal app the end-to-end tests measure.
        .executableTarget(name: "MetalCapProbe"),
        .testTarget(name: "MetalCapCoreTests", dependencies: ["MetalCapCore"], swiftSettings: testSettings),
        // Run with Scripts/e2e.sh; without its environment the tests are skipped.
        .testTarget(name: "MetalCapEndToEndTests", dependencies: ["MetalCapCore"], swiftSettings: testSettings),
    ],
    swiftLanguageModes: [.v5]
)
