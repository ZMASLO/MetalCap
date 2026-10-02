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
        #expect(store.loadAll().last?.displayName == "old")

        var renamed = older
        renamed.name = "Game A"
        try store.save(renamed)
        #expect(store.loadAll().first { $0.id == older.id }?.displayName == "Game A")
        try store.save(older)
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

@Suite struct SortTests {
    private func capture(_ process: String, at seconds: Double, name: String? = nil) -> Capture {
        var capture = Capture(processName: process, startedAt: Date(timeIntervalSince1970: seconds),
                              frameTimes: [10], gpuTimes: [1])
        capture.name = name
        return capture
    }

    @Test func sortsByDate() {
        let captures = [capture("b", at: 2), capture("a", at: 3), capture("c", at: 1)]
        #expect(captures.sorted(by: .date, ascending: true).map(\.processName) == ["c", "b", "a"])
        #expect(captures.sorted(by: .date, ascending: false).map(\.processName) == ["a", "b", "c"])
    }

    @Test func sortsByDisplayNameThenNewestFirst() {
        let captures = [
            capture("zeta", at: 1), capture("proc", at: 2, name: "alpha"),
            capture("Zeta", at: 3), capture("beta", at: 4),
        ]
        #expect(captures.sorted(by: .name, ascending: true).map(\.startedAt.timeIntervalSince1970) == [2, 4, 3, 1])
        #expect(captures.sorted(by: .name, ascending: false).map(\.startedAt.timeIntervalSince1970) == [3, 1, 4, 2])
    }
}

@Suite struct SystemTests {
    @Test func rangesIgnoreMissingValues() {
        let samples = [
            SystemSample(time: 0, gpuUtilization: 40, thermalState: 0),
            SystemSample(time: 1, gpuUtilization: nil, thermalState: 2),
            SystemSample(time: 2, gpuUtilization: 80, thermalState: 1),
        ]
        #expect(samples.range(of: \.gpuUtilization) == MetricRange([40, 80]))
        #expect(samples.range(of: \.gpuUtilization)?.average == 60)
        #expect(samples.range(of: \.gpuUtilization)?.maximum == 80)
        #expect(samples.range(of: \.cpuTemperature) == nil)
        #expect(samples.worstThermalState == 2)
    }

    @Test func recorderAttachesTheChosenProcessToSamples() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        func reading(at seconds: Double, memory: [Int32: Double]) -> SystemReading {
            SystemReading(date: t0.addingTimeInterval(seconds), sample: SystemSample(time: 0, gpuUtilization: 50),
                          processes: memory.mapValues { .init(cpu: 120, memory: $0) })
        }
        let frames = Array(repeating: Frame(interval: 100, gpuTime: 1), count: 10)
        let recorder = CaptureRecorder()
        recorder.ingest(reading(at: 0, memory: [7: 1]))             // not recording yet
        recorder.start(at: t0, preferredPID: 7)
        #expect(recorder.candidatePIDs == [7])
        recorder.ingest(HUDEvent(time: t0.addingTimeInterval(1), pid: 7, processName: "game",
                                 sample: HUDSample(frameNumber: 10, frames: frames, isRedacted: false)))
        recorder.ingest(reading(at: 0.5, memory: [7: 2048, 9: 10]))
        recorder.ingest(reading(at: 1.5, memory: [9: 10]))          // the game was not sampled this time
        recorder.stop(at: t0.addingTimeInterval(2))
        recorder.ingest(reading(at: 2.5, memory: [7: 4096]))        // after stop
        let system = recorder.finish()?.system
        #expect(system?.map(\.time) == [0.5, 1.5])
        #expect(system?.map(\.processMemory) == [2048, nil])
        #expect(system?.first?.processCPU == 120)
        #expect(system?.first?.gpuUtilization == 50)
    }

    /// Reads the real machine: checks that every value that is reported is plausible.
    @Test func samplerReportsPlausibleValues() {
        let sampler = SystemSampler()
        let pid = ProcessInfo.processInfo.processIdentifier
        _ = sampler.read(pids: [pid])
        let end = Date().addingTimeInterval(0.4)
        var spin = 0.0
        while Date() < end { spin += 1 }                             // keep one core busy
        let reading = sampler.read(pids: [pid])
        let sample = reading.sample
        print("sampler:", sample, reading.processes[pid] as Any, "battery:", SystemSampler.isOnBattery as Any)

        if let value = sample.gpuUtilization { #expect((0...100).contains(value)) }
        if let value = sample.gpuMemory { #expect(value >= 0) }
        if let value = sample.cpuTemperature { #expect((10...130).contains(value)) }
        if let value = sample.gpuTemperature { #expect((10...130).contains(value)) }
        if let value = sample.cpuUsage { #expect((0...100).contains(value)) }
        if let average = sample.cpuTemperatureAverage, let hottest = sample.cpuTemperature { #expect(average <= hottest) }
        if let value = sample.cpuPower { #expect((0...500).contains(value)) }
        if let value = sample.gpuPower { #expect((0...500).contains(value)) }
        if let value = sample.systemPower { #expect((0...1000).contains(value)) }
        #expect((sample.systemMemory ?? 0) > 500)
        #expect((0...3).contains(sample.thermalState))
        #expect((reading.processes[pid]?.memory ?? 0) > 1)
        // One busy thread: close to 100% of a core.
        #expect((60...160).contains(reading.processes[pid]?.cpu ?? 0))
    }
}

@Suite struct PowerChannelTests {
    @Test func recognizesCPUPowerHistograms() {
        for name in ["PACC", "PACC0", "MACC1", "EACC12", "PACC0 SRAM"] {
            #expect(PowerChannels.isCPUPowerHistogram(subgroup: "Energy", name: name), "\(name)")
        }
        // The GPU, other subgroups and other suffixes are not CPU clusters.
        #expect(!PowerChannels.isCPUPowerHistogram(subgroup: "Energy", name: "AGX"))
        #expect(!PowerChannels.isCPUPowerHistogram(subgroup: "DCS BW", name: "PACC0"))
        #expect(!PowerChannels.isCPUPowerHistogram(subgroup: "Energy", name: "PACC0 RD"))
        #expect(!PowerChannels.isCPUPowerHistogram(subgroup: "Energy", name: "ACC"))
    }

    @Test func readsBinLabels() {
        #expect(PowerChannels.binValue("2W") == 2)
        #expect(PowerChannels.binValue("0.250W") == 0.25)
        #expect(PowerChannels.binValue("  12GB/s") == 12)
        #expect(PowerChannels.binValue("IDLE") == 0)
    }

    @Test func averagesBinsWithTheLowestCountedAsZero() {
        // Half the time in the lowest bin (idle), a quarter each at 4 W and 8 W.
        #expect(PowerChannels.weightedAverage(bins: [2, 4, 8], residency: [50, 25, 25]) == 3)
        #expect(PowerChannels.weightedAverage(bins: [2, 4, 8], residency: [100, 0, 0]) == 0)
        #expect(PowerChannels.weightedAverage(bins: [2, 4], residency: [0, 0]) == 0)
    }

    @Test func convertsEnergyUnits() {
        #expect(PowerChannels.joules(1500, unit: "mJ") == 1.5)
        #expect(PowerChannels.joules(2_000_000, unit: "uJ ") == 2)
        #expect(PowerChannels.joules(3_000_000_000, unit: "nJ") == 3)
        #expect(PowerChannels.joules(1, unit: "8.3ns") == nil)
    }
}
