import Foundation

/// How CSV files are written.
public enum CSVDialect: String, CaseIterable, Sendable {
    /// Comma-separated with decimal points; reads in Numbers, Google Sheets and most tools.
    case standard
    /// Semicolon-separated with decimal commas, as Excel expects under Polish (and many European) settings.
    case semicolon

    var separator: String { self == .standard ? "," : ";" }
    var decimalSeparator: String { self == .standard ? "." : "," }
}

/// Writes captures as JSON and CSV.
public enum CaptureExporter {
    /// Bumped when the JSON layout changes incompatibly.
    public static let formatVersion = 1

    private struct Document: Encodable {
        struct Metrics: Encodable {
            var frameCount: Int
            var durationSeconds, average, median, max, min: Double
            var p99, p95, p5, p1, p0_2, p0_1: Double
            var onePercentLowAverage, pointOnePercentLowAverage: Double
            var onePercentLowIntegral, pointOnePercentLowIntegral: Double
        }

        struct Frames: Encodable {
            var frameTimesMs: [Double]
            var gpuTimesMs: [Double]
        }

        var formatVersion = CaptureExporter.formatVersion
        var application = "MetalCap"
        var id: UUID
        var name: String
        var processName: String
        var comment: String?
        var startedAt: Date
        var hardware: HardwareInfo?
        var window: GameWindow?
        var gameMode: GameModeSummary?
        var onBattery: Bool?
        var lowPowerMode: Bool?
        var metrics: Metrics?
        var frames: Frames
        var system: [SystemSample]?
    }

    /// The whole capture: metadata, hardware, frame-rate metrics, every frame and the system series.
    public static func json(_ capture: Capture) throws -> Data {
        let metrics = capture.metrics.map {
            Document.Metrics(
                frameCount: $0.frameCount, durationSeconds: $0.duration, average: $0.average, median: $0.median,
                max: $0.max, min: $0.min, p99: $0.p99, p95: $0.p95, p5: $0.p5, p1: $0.p1, p0_2: $0.p0_2, p0_1: $0.p0_1,
                onePercentLowAverage: $0.onePercentLowAverage, pointOnePercentLowAverage: $0.pointOnePercentLowAverage,
                onePercentLowIntegral: $0.onePercentLowIntegral, pointOnePercentLowIntegral: $0.pointOnePercentLowIntegral)
        }
        let document = Document(
            id: capture.id, name: capture.displayName, processName: capture.processName, comment: capture.comment,
            startedAt: capture.startedAt, hardware: capture.hardware, window: capture.window,
            gameMode: capture.gameMode, onBattery: capture.onBattery,
            lowPowerMode: capture.lowPowerMode, metrics: metrics,
            frames: .init(frameTimesMs: capture.frameTimes, gpuTimesMs: capture.gpuTimes), system: capture.system)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// One row per frame.
    public static func framesCSV(_ capture: Capture, dialect: CSVDialect) -> String {
        var elapsed = 0.0
        let rows = capture.frameTimes.enumerated().map { index, frameTime -> [Field] in
            elapsed += frameTime / 1000
            let gpuTime = index < capture.gpuTimes.count ? capture.gpuTimes[index] : nil
            return [.integer(index + 1), .number(elapsed, 4), .number(frameTime, 2), .number(gpuTime, 2),
                    .number(frameTime > 0 ? 1000 / frameTime : nil, 1)]
        }
        return csv(header: ["frame", "time_s", "frame_time_ms", "gpu_time_ms", "fps"], rows: rows, dialect: dialect)
    }

    private static let systemColumns: [(String, KeyPath<SystemSample, Double?>, Int)] = [
        ("gpu_load_percent", \.gpuUtilization, 1), ("gpu_memory_mb", \.gpuMemory, 0),
        ("cpu_temp_avg_c", \.cpuTemperatureAverage, 1), ("cpu_temp_max_c", \.cpuTemperature, 1),
        ("gpu_temp_avg_c", \.gpuTemperatureAverage, 1), ("gpu_temp_max_c", \.gpuTemperature, 1),
        ("cpu_power_w", \.cpuPower, 2), ("gpu_power_w", \.gpuPower, 2), ("system_power_w", \.systemPower, 2),
        ("cpu_load_percent", \.cpuUsage, 1), ("game_cpu_percent", \.processCPU, 1),
        ("game_memory_mb", \.processMemory, 0), ("system_memory_mb", \.systemMemory, 0),
        ("fast_cluster_active_percent", \.fastClusterActive, 1), ("fast_cluster_mhz", \.fastClusterFrequency, 0),
        ("second_cluster_active_percent", \.secondClusterActive, 1), ("second_cluster_mhz", \.secondClusterFrequency, 0),
        ("gpu_mhz", \.gpuFrequency, 0), ("fan_rpm", \.fanSpeed, 0),
    ]

    /// One row per system sample (about one per second).
    public static func systemCSV(_ capture: Capture, dialect: CSVDialect) -> String {
        let rows = (capture.system ?? []).map { sample in
            [.number(sample.time, 2)] + systemColumns.map { Field.number(sample[keyPath: $0.1], $0.2) }
                + [.integer(sample.thermalState), .text(sample.gameMode?.rawValue ?? "")]
        }
        return csv(header: ["time_s"] + systemColumns.map(\.0) + ["thermal_state", "game_mode"], rows: rows, dialect: dialect)
    }

    /// One row per capture: what it was, the frame-rate metrics, the machine and the system averages and peaks.
    public static func summaryCSV(_ captures: [Capture], dialect: CSVDialect) -> String {
        let formatter = ISO8601DateFormatter()
        let ranged: [(String, KeyPath<SystemSample, Double?>, Int)] = [
            ("gpu_load_percent", \.gpuUtilization, 1), ("cpu_temp_c", \.cpuTemperatureAverage, 1),
            ("gpu_temp_c", \.gpuTemperatureAverage, 1), ("cpu_power_w", \.cpuPower, 2),
            ("gpu_power_w", \.gpuPower, 2), ("system_power_w", \.systemPower, 2),
            ("game_memory_mb", \.processMemory, 0), ("game_cpu_percent", \.processCPU, 1),
        ]
        let header = ["name", "process", "comment", "started_at", "duration_s", "frames",
                      "avg_fps", "p1_fps", "one_percent_low_avg_fps", "one_percent_low_integral_fps",
                      "point_one_percent_low_avg_fps", "median_fps", "min_fps", "max_fps",
                      "model", "model_identifier", "chip", "cpu_cores", "cpu_core_tiers", "gpu_cores", "memory_gb",
                      "os_version", "window_width", "window_height", "full_screen", "game_mode"]
            + ranged.flatMap { ["\($0.0)_avg", "\($0.0)_max"] }
        let rows = captures.map { capture -> [Field] in
            let metrics = capture.metrics
            let hardware = capture.hardware
            var row: [Field] = [
                .text(capture.displayName), .text(capture.processName), .text(capture.comment ?? ""),
                .text(formatter.string(from: capture.startedAt)), .number(metrics?.duration, 2),
                .integer(metrics?.frameCount), .number(metrics?.average, 1), .number(metrics?.p1, 1),
                .number(metrics?.onePercentLowAverage, 1), .number(metrics?.onePercentLowIntegral, 1),
                .number(metrics?.pointOnePercentLowAverage, 1), .number(metrics?.median, 1),
                .number(metrics?.min, 1), .number(metrics?.max, 1),
                .text(hardware?.modelName ?? ""), .text(hardware?.modelIdentifier ?? ""), .text(hardware?.chip ?? ""),
                .integer(hardware?.cpuCores), .text(hardware?.coreTierDescription ?? ""),
                .integer(hardware?.gpuCores), .integer(hardware?.memoryGB), .text(hardware?.osVersion ?? ""),
                .integer(capture.window?.width), .integer(capture.window?.height),
                .text(capture.window.map { $0.fullScreen ? "yes" : "no" } ?? ""), .text(capture.gameMode?.rawValue ?? ""),
            ]
            for column in ranged {
                let range = capture.system?.range(of: column.1)
                row += [.number(range?.average, column.2), .number(range?.maximum, column.2)]
            }
            return row
        }
        return csv(header: header, rows: rows, dialect: dialect)
    }

    // MARK: CSV

    private enum Field {
        case text(String)
        case integer(Int?)
        /// A value and the number of decimals to write.
        case number(Double?, Int)
    }

    private static func csv(header: [String], rows: [[Field]], dialect: CSVDialect) -> String {
        func cell(_ field: Field) -> String {
            switch field {
            case .text(let raw):
                // A leading =, +, - or @ would make a spreadsheet read the text as a formula.
                let text = raw.first.map { "=+-@".contains($0) } == true ? "'" + raw : raw
                // Quote whatever could be mistaken for structure, doubling embedded quotes.
                guard text.contains(where: { "\",;\n\r".contains($0) }) else { return text }
                return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            case .integer(let value):
                return value.map(String.init) ?? ""
            case .number(let value, let decimals):
                guard let value, value.isFinite else { return "" }
                return String(format: "%.\(decimals)f", value)
                    .replacingOccurrences(of: ".", with: dialect.decimalSeparator)
            }
        }
        let lines = [header.joined(separator: dialect.separator)]
            + rows.map { $0.map(cell).joined(separator: dialect.separator) }
        return lines.joined(separator: "\n") + "\n"
    }
}
