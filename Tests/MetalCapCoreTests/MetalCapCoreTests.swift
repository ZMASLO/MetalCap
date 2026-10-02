import Foundation
import Testing
@testable import MetalCapCore

private func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

@Suite struct StatisticsTests {
    @Test func quantileMatchesR8() {
        let data: [Double] = [5, 1, 4, 2, 3]
        #expect(isClose(Statistics.quantile(data, 0.5), 3))
        // h = (5 + 1/3) * 0.25 + 1/3 = 1.6667 -> 1 + 0.6667 * (2 - 1)
        #expect(isClose(Statistics.quantile(data, 0.25), 1 + 2.0 / 3.0))
        #expect(isClose(Statistics.quantile(data, 0.01), 1))
        #expect(isClose(Statistics.quantile(data, 1), 5))
        #expect(Statistics.quantile([], 0.5).isNaN)
    }

    @Test func averageIsFrameCountOverTime() {
        // 3 frames in 40 ms, not the mean of 100, 100 and 50 FPS.
        #expect(isClose(Statistics.averageFPS(frameTimes: [10, 10, 20]), 75))
    }

    @Test func onePercentLows() {
        let frameTimes = Array(repeating: 10.0, count: 99) + [100.0]
        // R-8 quantile 0.99 of the frame times is 69.67 ms, so only the 100 ms frame is averaged.
        #expect(isClose(Statistics.percentageHighAverage(frameTimes: frameTimes, quantile: 0.99), 100))
        // 1% of 1090 ms is 10.9 ms, reached by the single 100 ms frame.
        #expect(isClose(Statistics.percentageHighIntegral(frameTimes: frameTimes, quantile: 0.99), 100))

        let metrics = FrameMetrics(frameTimes: frameTimes)!
        #expect(metrics.frameCount == 100)
        #expect(isClose(metrics.average, 100 * 1000 / 1090))
        #expect(isClose(metrics.onePercentLowAverage, 10))
        #expect(isClose(metrics.onePercentLowIntegral, 10))
        #expect(isClose(metrics.min, 10))
        #expect(isClose(metrics.max, 100))
        // h = (100 + 1/3) * 0.01 + 1/3 = 1.3367 -> 10 + 0.3367 * (100 - 10) FPS
        #expect(isClose(metrics.p1, 10 + (0.01 / 3.0 + 1.0 / 3.0) * 90))
    }

    @Test func integralWalksSeveralSlowFrames() {
        // 1% of 2000 ms is 20 ms: 12 + 11 reaches it on the second-slowest frame.
        let frameTimes = [12.0, 11.0] + Array(repeating: 1977.0 / 198.0, count: 198)
        #expect(isClose(Statistics.percentageHighIntegral(frameTimes: frameTimes, quantile: 0.99), 11))
    }

    @Test func metricsIgnoreInvalidFrameTimes() {
        #expect(FrameMetrics(frameTimes: []) == nil)
        #expect(FrameMetrics(frameTimes: [0, -1]) == nil)
        #expect(FrameMetrics(frameTimes: [0, 10, 10])?.frameCount == 2)
    }
}

@Suite struct ParserTests {
    @Test func parsesStderrLine() {
        // Captured from macOS 27 with MTL_HUD_LOG_ENABLED=1.
        let line = "2026-10-02 15:38:56.514 probe[7693:156450] metal-HUD: 183,17.14,145.19,16.67,0.02,25.00,0.03,8.33,0.02"
        let sample = HUDLogParser.parse(line)
        #expect(sample?.frameNumber == 183)
        #expect(sample?.isRedacted == false)
        #expect(sample?.frames == [
            Frame(interval: 16.67, gpuTime: 0.02),
            Frame(interval: 25.00, gpuTime: 0.03),
            Frame(interval: 8.33, gpuTime: 0.02),
        ])
    }

    @Test func detectsRedactedLine() {
        let sample = HUDLogParser.parse("metal-HUD: 60,6.80,188.61<private>")
        #expect(sample?.frameNumber == 60)
        #expect(sample?.isRedacted == true)
        #expect(sample?.frames.isEmpty == true)
    }

    @Test func rejectsOtherLines() {
        #expect(HUDLogParser.parse("[libMTLHud] Metric com.apple.hud-stat.fps already exist") == nil)
        #expect(HUDLogParser.parse("metal-HUD: garbage") == nil)
    }

    @Test func lineBufferSplitsAcrossChunks() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("one\ntw".utf8)) == ["one"])
        #expect(buffer.append(Data("o\nthree\n".utf8)) == ["two", "three"])
    }
}

@Suite struct RecorderTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    /// A line of `count` frames of 100 ms each, ending at `t0 + end` seconds.
    private func event(end: Double, frameNumber: Int, count: Int = 10, pid: Int32 = 1, gpu: Double = 1) -> HUDEvent {
        let frames = Array(repeating: Frame(interval: 100, gpuTime: gpu), count: count)
        return HUDEvent(time: t0.addingTimeInterval(end), pid: pid, processName: "game\(pid)",
                        sample: HUDSample(frameNumber: frameNumber, frames: frames, isRedacted: false))
    }

    @Test func cutsAtStartAndStop() {
        let recorder = CaptureRecorder()
        recorder.ingest(event(end: 1, frameNumber: 10))
        recorder.start(at: t0.addingTimeInterval(1.55))
        recorder.ingest(event(end: 2, frameNumber: 20))   // frames ending at 1.6 ... 2.0 kept
        recorder.ingest(event(end: 3, frameNumber: 30))   // all kept
        recorder.stop(at: t0.addingTimeInterval(3.25))
        recorder.ingest(event(end: 4, frameNumber: 40))   // frames ending at 3.1, 3.2 kept
        let capture = recorder.finish()
        #expect(capture?.frameTimes.count == 5 + 10 + 2)
        #expect(capture?.processName == "game1")
        #expect(capture?.lostLines == 0)
        #expect(recorder.isRecording == false)
    }

    @Test func countsLostLines() {
        let recorder = CaptureRecorder()
        recorder.start(at: t0)
        recorder.ingest(event(end: 1, frameNumber: 10))
        recorder.ingest(event(end: 3, frameNumber: 30))   // the line ending at 2 s is missing
        #expect(recorder.finish()?.lostLines == 1)
    }

    @Test func prefersRequestedProcess() {
        let recorder = CaptureRecorder()
        recorder.start(at: t0, preferredPID: 2)
        recorder.ingest(event(end: 1, frameNumber: 10, count: 10, pid: 1))
        recorder.ingest(event(end: 1, frameNumber: 5, count: 5, pid: 2))
        #expect(recorder.finish()?.processName == "game2")

        recorder.start(at: t0, preferredPID: 99)
        recorder.ingest(event(end: 1, frameNumber: 20, count: 10, pid: 1))
        recorder.ingest(event(end: 1, frameNumber: 10, count: 5, pid: 2))
        #expect(recorder.finish()?.processName == "game1")
    }

    @Test func noFramesMeansNoCapture() {
        let recorder = CaptureRecorder()
        recorder.start(at: t0)
        recorder.ingest(HUDEvent(time: t0.addingTimeInterval(1), pid: 1, processName: "game",
                                 sample: HUDSample(frameNumber: 60, frames: [], isRedacted: true)))
        #expect(recorder.finish() == nil)
    }
}

@Suite struct StoreTests {
    @Test func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetalCapTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory)
        #expect(store.loadAll().isEmpty)

        let older = Capture(processName: "a", startedAt: Date(timeIntervalSince1970: 1_000),
                            frameTimes: [16.67, 16.66], gpuTimes: [5, 6], lostLines: 1)
        let newer = Capture(processName: "b", startedAt: Date(timeIntervalSince1970: 2_000),
                            frameTimes: [8.33], gpuTimes: [3])
        try store.save(older)
        try store.save(newer)
        #expect(store.loadAll() == [newer, older])

        try store.delete(newer.id)
        #expect(store.loadAll() == [older])
    }
}
