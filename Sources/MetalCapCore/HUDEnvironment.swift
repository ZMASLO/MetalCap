import Foundation

/// Turns the Metal Performance HUD and its frame logging on or off for every app
/// launched afterwards, through launchd's user environment.
public enum HUDEnvironment {
    public static let variables = ["MTL_HUD_ENABLED", "MTL_HUD_LOG_ENABLED"]

    public static var isEnabled: Bool {
        variables.allSatisfy { (try? launchctl(["getenv", $0])) == "1" }
    }

    public static func setEnabled(_ enabled: Bool) throws {
        for variable in variables {
            _ = try launchctl(enabled ? ["setenv", variable, "1"] : ["unsetenv", variable])
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
