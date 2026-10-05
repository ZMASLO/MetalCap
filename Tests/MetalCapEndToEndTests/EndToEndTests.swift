import CoreGraphics
import Foundation
import Testing
@testable import MetalCapCore

/// Paths handed over by Scripts/e2e.sh. Without them every test here is skipped.
private enum Environment {
    static let probe = ProcessInfo.processInfo.environment["METALCAP_PROBE"]
    static let cli = ProcessInfo.processInfo.environment["METALCAP_CLI"]
    static var isEnabled: Bool { probe != nil }
}

/// The probe draws at this rate.
private let targetFPS = 60.0
/// Length of each measured window.
private let captureSeconds = 5.0

/// Feeds HUD lines and system readings into a recorder on one queue, as the app does on its main actor.
private final class Pipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MetalCapEndToEndTests.pipeline")
    private let recorder = CaptureRecorder()
    private let sampler = SystemSampler()
    private var linesFromTarget = 0
    private var redactedLines = 0
    var targetPID: Int32?

    var sawRedactedLines: Bool { queue.sync { redactedLines > 0 } }

    func ingest(_ event: HUDEvent) {
        queue.async {
            if event.pid == self.targetPID {
                self.linesFromTarget += 1
                if event.sample.isRedacted { self.redactedLines += 1 }
            }
            self.recorder.ingest(event)
        }
    }

    /// Waits until the target has logged a couple of lines (so start-up hitches are over),
    /// records `seconds` of frames with system sampling, and returns the capture.
    func capture(seconds: Double) async throws -> Capture? {
        let deadline = Date().addingTimeInterval(15)
        while queue.sync(execute: { linesFromTarget }) < 2 {
            guard Date() < deadline else { return nil }
            try await Task.sleep(for: .milliseconds(100))
        }
        queue.sync { recorder.start(at: Date(), preferredPID: targetPID) }
        let sampling = Task {
            while !Task.isCancelled {
                queue.sync { recorder.ingest(sampler.read(pids: recorder.candidatePIDs)) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        try await Task.sleep(for: .seconds(seconds))
        queue.sync { recorder.stop(at: Date()) }
        // The HUD logs about once per second; wait for the line covering the last frames.
        try await Task.sleep(for: .seconds(1.6))
        sampling.cancel()
        return queue.sync { recorder.finish() }
    }
}

private func requireAwakeDisplay() throws {
    // Metal windows present no frames while the display sleeps or the screen is locked.
    try #require(CGDisplayIsAsleep(CGMainDisplayID()) == 0, "The display is asleep; wake it and unlock the Mac.")
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    try #require(session?["CGSSessionScreenIsLocked"] as? Bool != true, "The screen is locked; unlock the Mac.")
}

/// Checks a capture of the probe from frame metrics through storage and export.
private func verify(_ capture: Capture) throws {
    let metrics = try #require(capture.metrics)
    #expect(abs(metrics.average - targetFPS) < 2, "AVG \(metrics.average)")
    #expect(abs(metrics.median - targetFPS) < 1, "median \(metrics.median)")
    #expect(abs(Double(metrics.frameCount) - captureSeconds * targetFPS) <= 15, "frames \(metrics.frameCount)")
    // The recorded frames cover the capture window and the log lost nothing.
    #expect((0.95...1.05).contains(capture.coverage ?? 0), "coverage \(capture.coverage ?? 0)")
    #expect((capture.missingFrames ?? 0) <= metrics.frameCount / 50, "missing frames \(capture.missingFrames ?? 0)")

    let system = try #require(capture.system)
    #expect(system.count >= Int(captureSeconds) - 1, "system samples \(system.count)")
    #expect(system.contains { ($0.processMemory ?? 0) > 1 }, "the probe's memory was not sampled")
    #expect(system.contains { $0.gpuUtilization != nil })

    // Storage keeps the capture as is.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MetalCapE2E-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptureStore(directory: directory)
    try store.save(capture)
    let loaded = try #require(store.loadAll().first)
    // Files keep the start time to the millisecond; everything else must come back exactly.
    #expect(abs(loaded.startedAt.timeIntervalSince(capture.startedAt)) < 0.001)
    var sameStart = loaded
    sameStart.startedAt = capture.startedAt
    #expect(sameStart == capture)

    // Exports carry the same numbers.
    let json = try #require(try JSONSerialization.jsonObject(with: CaptureExporter.json(capture)) as? [String: Any])
    #expect((json["metrics"] as? [String: Any])?["average"] as? Double == metrics.average)
    #expect(((json["frames"] as? [String: Any])?["frameTimesMs"] as? [Double])?.count == metrics.frameCount)
    let frameRows = CaptureExporter.framesCSV(capture, dialect: .standard).split(separator: "\n")
    #expect(frameRows.count == metrics.frameCount + 1)
    let systemRows = CaptureExporter.systemCSV(capture, dialect: .standard).split(separator: "\n")
    #expect(systemRows.count == system.count + 1)
}

@Suite(.serialized, .enabled(if: Environment.isEnabled, "Run Scripts/e2e.sh"))
struct MetalCapEndToEndTests {
    /// The path of "Launch game…": MetalCap starts the game and reads its stderr.
    @Test(.timeLimit(.minutes(1)))
    func launchedGameIsMeasuredFromItsOutput() async throws {
        try requireAwakeDisplay()
        let source = LaunchedProcessSource(url: URL(fileURLWithPath: try #require(Environment.probe)),
                                           arguments: ["15", String(Int(targetFPS))])
        let pipeline = Pipeline()
        source.onEvent = pipeline.ingest
        try source.start()
        defer { source.terminate() }
        pipeline.targetPID = source.pid

        let capture = try #require(try await pipeline.capture(seconds: captureSeconds), "no frames from the probe")
        #expect(capture.processName == "MetalCapProbe")
        try verify(capture)
    }

    /// The path of games started from Steam or CrossOver: they log to the unified log,
    /// which shows frame times only with the logging profile installed.
    @Test(.timeLimit(.minutes(1)), .enabled(if: LogPrivacy.isUnlocked(), "Install the logging profile first"))
    func gameStartedElsewhereIsMeasuredFromTheSystemLog() async throws {
        try requireAwakeDisplay()
        let pipeline = Pipeline()
        let log = LogStreamSource()
        log.onEvent = pipeline.ingest
        try log.start()
        defer { log.stop() }
        try await Task.sleep(for: .seconds(1))  // let `log stream` attach before the probe starts

        let game = Process()
        game.executableURL = URL(fileURLWithPath: try #require(Environment.probe))
        game.arguments = ["15", String(Int(targetFPS))]
        game.environment = ProcessInfo.processInfo.environment.merging(
            Dictionary(uniqueKeysWithValues: HUDEnvironment.variables.map { ($0, "1") })) { $1 }
        game.standardError = FileHandle.nullDevice
        try game.run()
        defer { game.terminate() }
        pipeline.targetPID = game.processIdentifier

        let capture = try #require(try await pipeline.capture(seconds: captureSeconds), "no frames in the system log")
        #expect(!pipeline.sawRedactedLines, "the log still redacts frame times")
        try verify(capture)
    }

    /// The headless mode end to end: `MetalCap --run`.
    @Test(.timeLimit(.minutes(1)), .enabled(if: Environment.cli != nil))
    func headlessRunPrintsTheMetrics() throws {
        try requireAwakeDisplay()
        let run = Process()
        run.executableURL = URL(fileURLWithPath: try #require(Environment.cli))
        run.arguments = ["--run", try #require(Environment.probe), "--seconds", "4"]
        let output = Pipe()
        run.standardOutput = output
        run.standardError = FileHandle.nullDevice
        try run.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()

        #expect(run.terminationStatus == 0, "\(text)")
        // e.g. "AVG 59.9 | P1 59.8 | ..."
        let average = text.split(separator: "\n").first { $0.hasPrefix("AVG ") }
            .flatMap { Double($0.dropFirst(4).prefix { $0 != " " }) }
        // The headless run includes the start-up frames, so allow a little more slack.
        #expect(abs((average ?? 0) - targetFPS) < 4, "\(text)")
        #expect(text.contains("System ("), "no system summary in: \(text)")
    }
}
