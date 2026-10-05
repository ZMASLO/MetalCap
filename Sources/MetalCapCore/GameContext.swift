import CoreGraphics
import Foundation

/// The game's window when the capture was made, in pixels.
public struct GameWindow: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// The window covered the whole display it was on.
    public var fullScreen: Bool

    public init(width: Int, height: Int, fullScreen: Bool) {
        self.width = width
        self.height = height
        self.fullScreen = fullScreen
    }

    /// The largest normal window `pid` has on screen. Window sizes are readable without the
    /// Screen Recording permission (window titles are not, and are not needed).
    public static func current(pid: Int32) -> GameWindow? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let bounds = windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }
        guard let largest = bounds.max(by: { $0.width * $0.height < $1.width * $1.height }),
              largest.width > 0, largest.height > 0 else { return nil }
        return GameWindow(points: largest, display: display(containing: largest))
    }

    /// Converts a window frame in points to pixels on `display`.
    init(points frame: CGRect, display: (bounds: CGRect, pixelWidth: Int)?) {
        let scale = display.map { Double($0.pixelWidth) / $0.bounds.width } ?? 1
        width = Int((frame.width * scale).rounded())
        height = Int((frame.height * scale).rounded())
        fullScreen = display.map { frame.equalTo($0.bounds) } ?? false
    }

    private static func display(containing frame: CGRect) -> (bounds: CGRect, pixelWidth: Int)? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        let centre = CGRect(x: frame.midX, y: frame.midY, width: 1, height: 1)
        guard CGGetDisplaysWithRect(centre, 8, &displays, &count) == .success, count > 0,
              let mode = CGDisplayCopyDisplayMode(displays[0]) else { return nil }
        return (CGDisplayBounds(displays[0]), mode.pixelWidth)
    }
}

/// Game Mode as `gamepolicyd` reports it.
public enum GameModeState: String, Codable, Sendable {
    case on, paused, off

    /// Reads "Game mode status is now on." and the like.
    public static func parse(_ message: String) -> GameModeState? {
        let prefix = "Game mode status is now "
        guard message.hasPrefix(prefix) else { return nil }
        let word = message.dropFirst(prefix.count).prefix { $0.isLetter }
        return GameModeState(rawValue: String(word))
    }
}

/// How much of a capture ran with Game Mode on.
public enum GameModeSummary: String, Codable, Sendable {
    case wholeCapture, partOfCapture, off

    public init?(states: [GameModeState?]) {
        let known = states.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        let on = known.filter { $0 == .on }.count
        self = on == known.count ? .wholeCapture : on > 0 ? .partOfCapture : .off
    }
}

/// Follows Game Mode through the messages `gamepolicyd` writes to the unified log.
public final class GameModeMonitor: @unchecked Sendable {
    private static let predicate = "subsystem == \"com.apple.gamepolicyd\" AND eventMessage BEGINSWITH \"Game mode status is now\""

    private let lock = NSLock()
    private var latest: GameModeState?
    private let stream = LogStream(predicate: GameModeMonitor.predicate)
    private var started = false

    public init() {
        stream.onLine = { [weak self] line in
            if let state = Self.state(inLogLine: line) { self?.update(state) }
        }
    }

    /// The most recent state, or nil until one has been seen.
    public var state: GameModeState? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private func update(_ state: GameModeState, onlyIfUnknown: Bool = false) {
        lock.lock()
        if !onlyIfUnknown || latest == nil { latest = state }
        lock.unlock()
    }

    public func start() throws {
        guard !started else { return }
        started = true
        try stream.start()

        // The stream only sees changes from now on; the last earlier one gives the current state.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let history = Process()
            history.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            history.arguments = ["show", "--last", "24h", "--style", "ndjson", "--predicate", Self.predicate]
            let pipe = Pipe()
            history.standardOutput = pipe
            history.standardError = FileHandle.nullDevice
            guard (try? history.run()) != nil else { return }
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            history.waitUntilExit()
            if let last = text.split(separator: "\n").compactMap({ Self.state(inLogLine: String($0)) }).last {
                self?.update(last, onlyIfUnknown: true)
            }
        }
    }

    public func stop() {
        stream.stop()
        started = false
    }

    private struct Entry: Decodable {
        var eventMessage: String
    }

    static func state(inLogLine line: String) -> GameModeState? {
        guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)) else { return nil }
        return GameModeState.parse(entry.eventMessage)
    }
}
