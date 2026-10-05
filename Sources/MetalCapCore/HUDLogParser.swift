import Foundation

public struct Frame: Equatable, Sendable {
    /// Present-to-present interval in milliseconds.
    public var interval: Double
    /// GPU time in milliseconds.
    public var gpuTime: Double

    public init(interval: Double, gpuTime: Double) {
        self.interval = interval
        self.gpuTime = gpuTime
    }
}

/// One `metal-HUD:` log line, emitted by the Metal Performance HUD roughly once per second.
public struct HUDSample: Equatable, Sendable {
    /// Running frame counter after the frames in this line.
    public var frameNumber: Int
    public var frames: [Frame]
    /// The unified log replaces the per-frame data with `<private>` unless private data is enabled.
    public var isRedacted: Bool
}

public enum HUDLogParser {
    static let marker = "metal-HUD:"

    /// Parses `metal-HUD: <frame number>,<float>,<float>,<interval>,<gpu time>,...`.
    /// The line may carry a prefix (e.g. the NSLog header when read from stderr).
    public static func parse(_ line: String) -> HUDSample? {
        guard let range = line.range(of: marker) else { return nil }
        var payload = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)

        let isRedacted = payload.contains("<private>")
        if isRedacted { payload = payload.replacingOccurrences(of: "<private>", with: "") }

        let fields = payload.split(separator: ",", omittingEmptySubsequences: true)
        guard fields.count >= 3, let frameNumber = Int(fields[0]) else { return nil }

        // Fields 1 and 2 are per-line HUD values we don't use; frames follow as pairs.
        var frames: [Frame] = []
        frames.reserveCapacity((fields.count - 3) / 2)
        var index = 3
        while index + 1 < fields.count {
            guard let interval = Double(fields[index]), let gpuTime = Double(fields[index + 1]) else { break }
            frames.append(Frame(interval: interval, gpuTime: gpuTime))
            index += 2
        }
        return HUDSample(frameNumber: frameNumber, frames: frames, isRedacted: isRedacted)
    }

    private static let stderrTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// When the line was written, from the header the HUD puts on lines it prints to stderr
    /// ("2026-10-05 12:37:25.226 Game[123:456] metal-HUD: ..."). Lines can be read late and
    /// several at once, so the time of reading would misplace frames at the edges of a capture.
    public static func timestamp(ofStderrLine line: String) -> Date? {
        guard line.count >= 23 else { return nil }
        return stderrTimestamp.date(from: String(line.prefix(23)))
    }
}

/// A parsed HUD line together with where and when it came from.
public struct HUDEvent: Sendable {
    public var time: Date
    public var pid: Int32
    public var processName: String
    public var sample: HUDSample

    public init(time: Date, pid: Int32, processName: String, sample: HUDSample) {
        self.time = time
        self.pid = pid
        self.processName = processName
        self.sample = sample
    }
}

/// Splits a byte stream into lines.
struct LineBuffer {
    private var data = Data()

    mutating func append(_ chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            data.removeSubrange(data.startIndex...newline)
        }
        return lines
    }
}
