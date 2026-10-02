import Foundation

/// One recorded benchmark run.
public struct Capture: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var processName: String
    public var startedAt: Date
    /// Present-to-present intervals in milliseconds.
    public var frameTimes: [Double]
    /// GPU time per frame in milliseconds, parallel to `frameTimes`.
    public var gpuTimes: [Double]
    /// HUD log lines that went missing during the capture.
    public var lostLines: Int

    public init(id: UUID = UUID(), processName: String, startedAt: Date,
                frameTimes: [Double], gpuTimes: [Double], lostLines: Int = 0) {
        self.id = id
        self.processName = processName
        self.startedAt = startedAt
        self.frameTimes = frameTimes
        self.gpuTimes = gpuTimes
        self.lostLines = lostLines
    }

    public var metrics: FrameMetrics? { FrameMetrics(frameTimes: frameTimes) }
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
        var lostLines = 0
    }

    public private(set) var isRecording = false
    private var startTime = Date.distantPast
    private var stopTime = Date.distantFuture
    private var preferredPID: Int32?
    private var processes: [Int32: ProcessFrames] = [:]
    private var lastFrameNumber: [Int32: Int] = [:]

    public init() {}

    /// - Parameter preferredPID: the process to keep if several are logging (e.g. the frontmost app).
    public func start(at time: Date, preferredPID: Int32? = nil) {
        isRecording = true
        startTime = time
        stopTime = .distantFuture
        self.preferredPID = preferredPID
        processes = [:]
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
        if let previous, sample.frameNumber - previous != sample.frames.count,
           event.time >= startTime {
            entry.lostLines += 1
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
        let chosen = preferredPID.flatMap { withFrames[$0] }
            ?? withFrames.values.max { $0.frameTimes.count < $1.frameTimes.count }
        guard let chosen else { return nil }
        return Capture(processName: chosen.name, startedAt: startTime,
                       frameTimes: chosen.frameTimes, gpuTimes: chosen.gpuTimes,
                       lostLines: chosen.lostLines)
    }
}
