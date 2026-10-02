import Foundation

/// Controls whether the unified log shows the Metal HUD's frame data.
///
/// macOS redacts the per-frame part of `metal-HUD:` lines as `<private>`. A logging
/// configuration for the HUD's subsystem turns the redaction off for that subsystem only.
/// macOS 27 refuses direct writes to `/Library/Preferences/Logging` even as root, so the
/// configuration is delivered as a profile that the user installs in System Settings.
public enum LogPrivacy {
    public static let subsystem = "com.apple.metal.hud"
    public static let profileIdentifier = "com.metalcap.framelog"

    /// Where a logging preference for the subsystem lives when it is installed as a plain file.
    public static let preferenceURL =
        URL(fileURLWithPath: "/Library/Preferences/Logging/Subsystems/\(subsystem).plist")
    /// Where an installed configuration profile's logging payload is stored.
    public static let managedPreferenceURL =
        URL(fileURLWithPath: "/Library/Managed Preferences/com.apple.system.logging.plist")

    private static let options: [String: Any] = ["DEFAULT-OPTIONS": ["Enable-Private-Data": true]]

    /// A `.mobileconfig` that enables private data for the Metal HUD subsystem.
    /// - Parameters:
    ///   - displayName: profile name shown in System Settings.
    ///   - description: explanation shown in System Settings.
    public static func profileData(displayName: String, description: String) -> Data {
        let logging: [String: Any] = [
            "PayloadType": "com.apple.system.logging",
            "PayloadIdentifier": "\(profileIdentifier).logging",
            "PayloadUUID": "6B0C4F3E-6C1B-4A52-9D0B-5E1C7A2F4D11",
            "PayloadVersion": 1,
            "PayloadDisplayName": displayName,
            "Subsystems": [subsystem: options],
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadIdentifier": profileIdentifier,
            "PayloadUUID": "2F6D2A7C-0B55-4E4B-8C7E-93A1D4B6E820",
            "PayloadVersion": 1,
            "PayloadScope": "System",
            "PayloadDisplayName": displayName,
            "PayloadDescription": description,
            "PayloadContent": [logging],
        ]
        // Serializing a fixed dictionary cannot fail.
        return try! PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// Whether a logging configuration that reveals the HUD's frame data is installed.
    public static func isUnlocked(preferenceURL: URL = preferenceURL,
                                  managedPreferenceURL: URL = managedPreferenceURL) -> Bool {
        if enablesPrivateData(propertyList(at: preferenceURL)) { return true }
        let subsystems = propertyList(at: managedPreferenceURL)?["Subsystems"] as? [String: Any]
        return enablesPrivateData(subsystems?[subsystem] as? [String: Any])
    }

    private static func propertyList(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func enablesPrivateData(_ preference: [String: Any]?) -> Bool {
        let options = preference?["DEFAULT-OPTIONS"] as? [String: Any]
        return options?["Enable-Private-Data"] as? Bool == true
    }
}
