import Foundation

/// One recorded benchmark run.
public struct Capture: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Name of the executable the frames came from.
    public var processName: String
    /// Name chosen by the user to show instead of the process name.
    public var name: String?
    public var startedAt: Date
    /// Present-to-present intervals in milliseconds.
    public var frameTimes: [Double]
    /// GPU time per frame in milliseconds, parallel to `frameTimes`.
    public var gpuTimes: [Double]
    /// Wall-clock time between start and stop, in seconds. Compared with the summed
    /// frame times it shows whether frames went missing. Nil in captures saved before it was recorded.
    public var wallDuration: Double?
    /// Frames the HUD's running counter says were presented but that were not in the log.
    public var missingFrames: Int?
    /// The user's note, e.g. the graphics settings used for this run.
    public var comment: String?
    /// GPU load, temperatures, CPU and memory use sampled about once per second during the capture.
    public var system: [SystemSample]?
    /// Whether the Mac ran on battery when the capture started.
    public var onBattery: Bool?
    public var lowPowerMode: Bool?
    /// The machine the capture was recorded on.
    public var hardware: HardwareInfo?
    /// The game's window during the capture.
    public var window: GameWindow?

    /// How much of the capture ran with Game Mode on; nil when it was not recorded.
    public var gameMode: GameModeSummary? {
        GameModeSummary(states: (system ?? []).map(\.gameMode))
    }

    public init(id: UUID = UUID(), processName: String, startedAt: Date,
                frameTimes: [Double], gpuTimes: [Double],
                wallDuration: Double? = nil, missingFrames: Int? = nil, comment: String? = nil) {
        self.id = id
        self.processName = processName
        self.startedAt = startedAt
        self.frameTimes = frameTimes
        self.gpuTimes = gpuTimes
        self.wallDuration = wallDuration
        self.missingFrames = missingFrames
        self.comment = comment
    }

    public var displayName: String { name ?? processName }

    /// Share of the capture window covered by the recorded frames (1 = complete).
    public var coverage: Double? {
        guard let wallDuration, wallDuration > 0 else { return nil }
        return frameTimes.reduce(0, +) / 1000 / wallDuration
    }

    public var metrics: FrameMetrics? { FrameMetrics(frameTimes: frameTimes) }
}

/// What the capture list is ordered by.
public enum CaptureSortKey: String, CaseIterable, Sendable {
    case date, name
}

extension Array where Element == Capture {
    /// - Parameter ascending: oldest first for `.date`, A to Z for `.name`.
    ///   Captures with the same name are always listed newest first.
    public func sorted(by key: CaptureSortKey, ascending: Bool) -> [Capture] {
        sorted { first, second in
            if key == .name {
                let order = first.displayName.localizedCaseInsensitiveCompare(second.displayName)
                if order != .orderedSame { return (order == .orderedAscending) == ascending }
                return first.startedAt > second.startedAt
            }
            return (first.startedAt < second.startedAt) == ascending
        }
    }
}

/// Turns the stream of HUD lines into a capture bounded by a start and a stop time.
///
/// The HUD keeps logging for as long as the game runs, so "recording" only decides
/// which frames are kept. Each line arrives about once per second and holds the frames
/// presented since the previous one; their timestamps are rebuilt backwards from the
/// line's own time so the capture is cut at frame precision.
public final class CaptureRecorder {
    private struct ProcessFrames {
        var name: String
        var frameTimes: [Double] = []
        var gpuTimes: [Double] = []
        var missingFrames = 0
    }

    public private(set) var isRecording = false
    /// The process the last finished capture came from.
    public private(set) var lastCapturePID: Int32?
    private var startTime = Date.distantPast
    private var stopTime = Date.distantFuture
    private var preferredPID: Int32?
    private var processes: [Int32: ProcessFrames] = [:]
    private var lastFrameNumber: [Int32: Int] = [:]
    private var readings: [SystemReading] = []

    public init() {}

    /// - Parameter preferredPID: the process to keep if several are logging (e.g. the frontmost app).
    public func start(at time: Date, preferredPID: Int32? = nil) {
        isRecording = true
        startTime = time
        stopTime = .distantFuture
        self.preferredPID = preferredPID
        processes = [:]
        readings = []
    }

    /// Processes whose resource use is worth sampling: any of them may turn out to be the game.
    public var candidatePIDs: [Int32] {
        Array(Set(processes.keys).union(preferredPID.map { [$0] } ?? []))
    }

    public func ingest(_ reading: SystemReading) {
        guard isRecording, reading.date >= startTime, reading.date <= stopTime else { return }
        readings.append(reading)
    }

    /// Marks the end of the capture. Lines covering the last moments may still be
    /// in flight, so keep calling `ingest` briefly before `finish()`.
    public func stop(at time: Date) {
        stopTime = time
    }

    public func ingest(_ event: HUDEvent) {
        let sample = event.sample
        let previous = lastFrameNumber[event.pid]
        lastFrameNumber[event.pid] = sample.frameNumber
        guard isRecording, !sample.frames.isEmpty else { return }

        var entry = processes[event.pid] ?? ProcessFrames(name: event.processName)
        if let previous, event.time >= startTime {
            entry.missingFrames += max(0, sample.frameNumber - previous - sample.frames.count)
        }

        // The last frame in the line was presented at about `event.time`.
        var endTime = event.time
        var kept: [Frame] = []
        for frame in sample.frames.reversed() {
            if endTime >= startTime, endTime <= stopTime { kept.append(frame) }
            endTime = endTime.addingTimeInterval(-frame.interval / 1000)
        }
        for frame in kept.reversed() {
            entry.frameTimes.append(frame.interval)
            entry.gpuTimes.append(frame.gpuTime)
        }
        processes[event.pid] = entry
    }

    /// Ends the recording and returns the capture, or nil if no frames were seen.
    public func finish() -> Capture? {
        guard isRecording else { return nil }
        isRecording = false
        defer { processes = [:] }

        let withFrames = processes.filter { !$0.value.frameTimes.isEmpty }
        let pid = preferredPID.flatMap { withFrames[$0] == nil ? nil : $0 }
            ?? withFrames.max { $0.value.frameTimes.count < $1.value.frameTimes.count }?.key
        guard let pid, let chosen = withFrames[pid] else { return nil }
        lastCapturePID = pid
        var capture = Capture(processName: chosen.name, startedAt: startTime,
                              frameTimes: chosen.frameTimes, gpuTimes: chosen.gpuTimes,
                              wallDuration: stopTime == .distantFuture ? nil : stopTime.timeIntervalSince(startTime),
                              missingFrames: chosen.missingFrames)
        if !readings.isEmpty {
            capture.system = readings.map { reading in
                var sample = reading.sample
                sample.time = reading.date.timeIntervalSince(startTime)
                sample.processCPU = reading.processes[pid]?.cpu
                sample.processMemory = reading.processes[pid]?.memory
                return sample
            }
        }
        readings = []
        return capture
    }
}
