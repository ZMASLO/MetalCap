import Foundation

/// How the Metal Performance HUD overlay looks: which metrics it shows, where and how large.
/// Values map to the HUD's `MTL_HUD_*` environment variables.
public struct HUDConfiguration: Codable, Equatable, Sendable {
    /// Metric names accepted by `MTL_HUD_ELEMENTS`, in the order the HUD documents them.
    public static let allElements = [
        "device", "rosetta", "layersize", "layerscale", "memory", "fps", "frameinterval", "gputime",
        "thermal", "frameintervalgraph", "presentdelay", "frameintervalhistogram", "metalcpu",
        "gputimeline", "shaders", "framenumber", "disk", "fpsgraph",
        "toplabeledcommandbuffers", "toplabeledencoders",
    ]
    /// Values accepted by `MTL_HUD_ALIGNMENT`, row by row from the top left.
    public static let alignments = [
        "topleft", "topcenter", "topright",
        "centerleft", "centered", "centerright",
        "bottomleft", "bottomcenter", "bottomright",
    ]
    public static let defaultAlignment = "topright"
    public static let defaultScale = 0.2
    public static let defaultOpacity = 1.0

    /// Metrics to show, or nil for the HUD's own default set.
    public var elements: Set<String>?
    public var alignment = HUDConfiguration.defaultAlignment
    /// Overlay width as a fraction of the drawable width.
    public var scale = HUDConfiguration.defaultScale
    public var opacity = HUDConfiguration.defaultOpacity

    public init() {}

    /// The value for each appearance variable; nil means the variable should stay unset
    /// so the HUD uses its default.
    public var environment: [String: String?] {
        // An empty list would hide the HUD, and a hidden HUD stops logging frame intervals.
        let chosen = elements.map { selection in Self.allElements.filter(selection.contains) } ?? []
        return [
            "MTL_HUD_ELEMENTS": chosen.isEmpty ? nil : chosen.joined(separator: ","),
            "MTL_HUD_ALIGNMENT": alignment == Self.defaultAlignment ? nil : alignment,
            "MTL_HUD_SCALE": abs(scale - Self.defaultScale) < 0.005 ? nil : String(format: "%.2f", scale),
            "MTL_HUD_OPACITY": abs(opacity - Self.defaultOpacity) < 0.005 ? nil : String(format: "%.2f", opacity),
        ]
    }
}

/// Turns the Metal Performance HUD and its frame logging on or off for every app
/// launched afterwards, through launchd's user environment.
public enum HUDEnvironment {
    public static let variables = ["MTL_HUD_ENABLED", "MTL_HUD_LOG_ENABLED"]

    public static var isEnabled: Bool {
        variables.allSatisfy { (try? launchctl(["getenv", $0])) == "1" }
    }

    /// Turning the HUD off also clears the appearance variables.
    public static func setEnabled(_ enabled: Bool, configuration: HUDConfiguration = HUDConfiguration()) throws {
        for variable in variables {
            try launchctl(enabled ? ["setenv", variable, "1"] : ["unsetenv", variable])
        }
        if enabled {
            try apply(configuration)
        } else {
            for variable in configuration.environment.keys { try launchctl(["unsetenv", variable]) }
        }
    }

    /// Sets the appearance variables for apps launched from now on.
    public static func apply(_ configuration: HUDConfiguration) throws {
        for (variable, value) in configuration.environment {
            try launchctl(value.map { ["setenv", variable, $0] } ?? ["unsetenv", variable])
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
