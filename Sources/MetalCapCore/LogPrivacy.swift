import Foundation

/// Controls whether the unified log shows the Metal HUD's frame data.
///
/// macOS redacts the per-frame part of `metal-HUD:` lines as `<private>`. A logging
/// preference file for the HUD's subsystem turns the redaction off for that subsystem
/// only. Writing it needs administrator rights, which the user grants in a system dialog.
public enum LogPrivacy {
    public static let preferenceURL =
        URL(fileURLWithPath: "/Library/Preferences/Logging/Subsystems/com.apple.metal.hud.plist")

    public struct Failure: LocalizedError {
        public var errorDescription: String?
    }

    public static func preferenceData() -> Data {
        let preference: [String: Any] = ["DEFAULT-OPTIONS": ["Enable-Private-Data": true]]
        // Serializing a fixed dictionary cannot fail.
        return try! PropertyListSerialization.data(fromPropertyList: preference, format: .xml, options: 0)
    }

    public static func isUnlocked(at url: URL = preferenceURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let preference = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let options = preference["DEFAULT-OPTIONS"] as? [String: Any] else { return false }
        return options["Enable-Private-Data"] as? Bool == true
    }

    /// Installs or removes the preference file, asking for an administrator password.
    /// Blocks until the dialog is answered.
    /// - Parameter prompt: explanation shown in the password dialog.
    /// - Returns: false if the user cancelled the dialog.
    public static func setUnlocked(_ unlocked: Bool, prompt: String) throws -> Bool {
        let target = preferenceURL.path
        var command = "/bin/rm -f '\(target)'"
        if unlocked {
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("metalcap-\(UUID().uuidString).plist")
            try preferenceData().write(to: staged)
            let directory = preferenceURL.deletingLastPathComponent().path
            command = "/bin/mkdir -p '\(directory)' && /bin/cp '\(staged.path)' '\(target)' && /bin/chmod 644 '\(target)'"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptLiteral(command)) with prompt \(appleScriptLiteral(prompt)) with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        if process.terminationStatus == 0 { return true }
        // -128 is AppleScript's "user cancelled".
        if message.contains("-128") { return false }
        throw Failure(errorDescription: message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
