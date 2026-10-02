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
        #expect(capture?.missingFrames == 0)
        #expect(isClose(capture?.wallDuration ?? 0, 1.7))
        #expect(isClose(capture?.coverage ?? 0, 1, tolerance: 1e-6))
        #expect(recorder.isRecording == false)
    }

    @Test func countsMissingFrames() {
        let recorder = CaptureRecorder()
        recorder.start(at: t0)
        recorder.ingest(event(end: 1, frameNumber: 10))
        recorder.ingest(event(end: 3, frameNumber: 30))   // the line ending at 2 s is missing
        recorder.stop(at: t0.addingTimeInterval(3))
        let capture = recorder.finish()
        #expect(capture?.missingFrames == 10)
        #expect(isClose(capture?.coverage ?? 0, 2.0 / 3.0, tolerance: 1e-6))
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
                            frameTimes: [16.67, 16.66], gpuTimes: [5, 6], wallDuration: 0.04, missingFrames: 1)
        let newer = Capture(processName: "b", startedAt: Date(timeIntervalSince1970: 2_000),
                            frameTimes: [8.33], gpuTimes: [3], comment: "RT Ultra, MetalFX Quality")
        try store.save(older)
        try store.save(newer)
        #expect(store.loadAll() == [newer, older])

        // A capture saved before comments existed still loads.
        let legacy = #"{"id":"\#(UUID().uuidString)","processName":"old","startedAt":"1970-01-01T00:00:10Z","frameTimes":[10],"gpuTimes":[1],"lostLines":3}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("legacy.json"))
        #expect(store.loadAll().last?.processName == "old")
        #expect(store.loadAll().last?.comment == nil)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("legacy.json"))

        try store.delete(newer.id)
        #expect(store.loadAll() == [older])
    }
}

@Suite struct LanguageTests {
    @Test func followsSystemLanguage() {
        #expect(Language.resolve(preference: "auto", preferredLanguages: ["pl-PL", "en-US"]) == .polish)
        #expect(Language.resolve(preference: nil, preferredLanguages: ["pl"]) == .polish)
        #expect(Language.resolve(preference: "auto", preferredLanguages: ["en-US", "pl-PL"]) == .english)
        #expect(Language.resolve(preference: "auto", preferredLanguages: ["de-DE"]) == .english)
        #expect(Language.resolve(preference: "auto", preferredLanguages: []) == .english)
    }

    @Test func preferenceOverridesSystem() {
        #expect(Language.resolve(preference: "en", preferredLanguages: ["pl-PL"]) == .english)
        #expect(Language.resolve(preference: "pl", preferredLanguages: ["en-US"]) == .polish)
    }
}

@Suite struct LogPrivacyTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MetalCapTests-\(UUID().uuidString).plist")
    }

    private func write(_ propertyList: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0).write(to: url)
    }

    @Test func profileEnablesPrivateDataForTheHUDSubsystemOnly() throws {
        let data = LogPrivacy.profileData(displayName: "Name", description: "Why")
        let profile = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(profile["PayloadType"] as? String == "Configuration")
        #expect(profile["PayloadIdentifier"] as? String == LogPrivacy.profileIdentifier)
        #expect(profile["PayloadDisplayName"] as? String == "Name")

        let payloads = try #require(profile["PayloadContent"] as? [[String: Any]])
        #expect(payloads.count == 1)
        #expect(payloads[0]["PayloadType"] as? String == "com.apple.system.logging")
        #expect(payloads[0]["System"] == nil)
        let subsystems = try #require(payloads[0]["Subsystems"] as? [String: [String: [String: Bool]]])
        #expect(subsystems == ["com.apple.metal.hud": ["DEFAULT-OPTIONS": ["Enable-Private-Data": true]]])
    }

    @Test func recognizesPreferenceFile() throws {
        let preference = temporaryURL(), managed = temporaryURL()
        defer { try? FileManager.default.removeItem(at: preference) }
        #expect(LogPrivacy.isUnlocked(preferenceURL: preference, managedPreferenceURL: managed) == false)

        try write(["DEFAULT-OPTIONS": ["Enable-Private-Data": true]], to: preference)
        #expect(LogPrivacy.isUnlocked(preferenceURL: preference, managedPreferenceURL: managed))

        try write(["DEFAULT-OPTIONS": ["Enable-Private-Data": false]], to: preference)
        #expect(LogPrivacy.isUnlocked(preferenceURL: preference, managedPreferenceURL: managed) == false)
    }

    @Test func recognizesInstalledProfile() throws {
        let preference = temporaryURL(), managed = temporaryURL()
        defer { try? FileManager.default.removeItem(at: managed) }

        try write(["Subsystems": ["com.example.other": ["DEFAULT-OPTIONS": ["Enable-Private-Data": true]]]], to: managed)
        #expect(LogPrivacy.isUnlocked(preferenceURL: preference, managedPreferenceURL: managed) == false)

        try write(["Subsystems": ["com.apple.metal.hud": ["DEFAULT-OPTIONS": ["Enable-Private-Data": true]]]], to: managed)
        #expect(LogPrivacy.isUnlocked(preferenceURL: preference, managedPreferenceURL: managed))
    }
}

@Suite struct HUDConfigurationTests {
    @Test func defaultsLeaveEveryVariableUnset() {
        let environment = HUDConfiguration().environment
        #expect(environment.count == 4)
        #expect(environment.values.allSatisfy { $0 == nil })
    }

    @Test func customValuesBecomeVariables() {
        var configuration = HUDConfiguration()
        configuration.elements = ["gputime", "fps", "not-a-metric"]
        configuration.alignment = "bottomleft"
        configuration.scale = 0.35
        configuration.opacity = 0.5
        let environment = configuration.environment
        // Documented order, unknown names dropped.
        #expect(environment["MTL_HUD_ELEMENTS"] == "fps,gputime")
        #expect(environment["MTL_HUD_ALIGNMENT"] == "bottomleft")
        #expect(environment["MTL_HUD_SCALE"] == "0.35")
        #expect(environment["MTL_HUD_OPACITY"] == "0.50")
    }

    @Test func emptySelectionFallsBackToTheDefaultSet() {
        var configuration = HUDConfiguration()
        configuration.elements = []
        #expect(configuration.environment["MTL_HUD_ELEMENTS"] == .some(nil))
    }
}
