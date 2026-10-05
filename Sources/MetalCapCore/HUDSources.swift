import Foundation

/// Reads HUD lines of every running app from the unified log via `log stream`.
///
/// On current macOS the per-frame part of the message is redacted (`<private>`)
/// unless private data is enabled for the `com.apple.metal.hud` subsystem; such
/// lines are still delivered, with `sample.isRedacted` set and no frames.
public final class LogStreamSource {
    public var onEvent: ((HUDEvent) -> Void)?
    let stream = LogStream(predicate: "subsystem == \"com.apple.metal.hud\" AND eventMessage BEGINSWITH \"metal-HUD:\"")

    private struct Entry: Decodable {
        var eventMessage: String
        var processID: Int32
        var processImagePath: String
        var timestamp: String
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    public init() {
        let decoder = JSONDecoder()
        stream.onLine = { [weak self] line in
            guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)),
                  let sample = HUDLogParser.parse(entry.eventMessage) else { return }
            let time = Self.timestampFormatter.date(from: entry.timestamp) ?? Date()
            let name = URL(fileURLWithPath: entry.processImagePath).lastPathComponent
            self?.onEvent?(HUDEvent(time: time, pid: entry.processID, processName: name, sample: sample))
        }
    }

    public func start() throws {
        try stream.start()
    }

    public func stop() {
        stream.stop()
    }
}

/// Launches a game with the HUD enabled and reads its HUD lines from stderr,
/// where the frame data is never redacted.
public final class LaunchedProcessSource {
    public var onEvent: ((HUDEvent) -> Void)?
    public var onExit: (() -> Void)?
    public let processName: String
    private let process = Process()

    /// - Parameters:
    ///   - url: an executable or an `.app` bundle.
    ///   - configuration: overlay appearance for this game.
    public init(url: URL, arguments: [String] = [], configuration: HUDConfiguration = HUDConfiguration()) {
        let executable = Bundle(url: url)?.executableURL ?? url
        processName = executable.lastPathComponent
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for variable in HUDEnvironment.variables { environment[variable] = "1" }
        for (variable, value) in configuration.environment { environment[variable] = value }
        process.environment = environment
    }

    public var pid: Int32 { process.processIdentifier }

    public func start() throws {
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        var buffer = LineBuffer()
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let now = Date()
            guard let self else { return }
            for line in buffer.append(handle.availableData) {
                guard let sample = HUDLogParser.parse(line) else { continue }
                self.onEvent?(HUDEvent(time: now, pid: self.pid, processName: self.processName, sample: sample))
            }
        }
        process.terminationHandler = { [weak self] _ in
            errors.fileHandleForReading.readabilityHandler = nil
            self?.onExit?()
        }
        try process.run()
    }

    public func terminate() {
        process.terminate()
    }
}
