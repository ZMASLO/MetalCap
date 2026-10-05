import MetalCapCore
import SwiftUI

/// The machine and context of the capture, the system metrics' averages and peaks, the frame time
/// chart and the system charts in themed pairs.
struct SystemSectionView: View {
    let capture: Capture
    /// Average frame rate of the capture, for the frames-per-watt figure.
    let averageFPS: Double
    /// The moment under the pointer, shared with the frame time chart.
    @Binding var hoverTime: Double?

    private var samples: [SystemSample] { capture.system ?? [] }
    private var cached: CaptureCache.Entry { CaptureCache.shared.entry(for: capture) }
    private var duration: Double { cached.metrics?.duration ?? 0 }

    /// "CPU: 18 rdzeni (6 Super + 12 Performance) · GPU: 20 rdzeni"
    private func coresLine(_ hardware: HardwareInfo) -> String {
        func cores(_ count: Int) -> String {
            guard L10n.language == .polish else { return "\(count) \(count == 1 ? "core" : "cores")" }
            return "\(count) " + PolishGrammar.form(for: count, one: "rdzeń", few: "rdzenie", many: "rdzeni")
        }
        let cpu = "CPU: \(cores(hardware.cpuCores)) (\(hardware.coreTierDescription))"
        return [cpu, hardware.gpuCores.map { "GPU: \(cores($0))" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Okno gry: 3456×2234 (pełny ekran) · Tryb gry: włączony"
    private var gameContextLine: String? {
        var parts: [String] = []
        if let window = capture.window {
            parts.append(tr("Okno gry: ", "Game window: ") + "\(window.width)×\(window.height)"
                         + (window.fullScreen ? tr(" (pełny ekran)", " (full screen)") : tr(" (w oknie)", " (windowed)")))
        }
        switch capture.gameMode {
        case .wholeCapture: parts.append(tr("Tryb gry: włączony", "Game Mode: on"))
        case .partOfCapture: parts.append(tr("Tryb gry: włączony przez część pomiaru", "Game Mode: on for part of the capture"))
        case .off: parts.append(tr("Tryb gry: wyłączony", "Game Mode: off"))
        case nil: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Tiles

    /// Temperature tile: the peak of the hottest sensor, with the mean across sensors underneath.
    private func temperatureTile(_ title: String, hottest: KeyPath<SystemSample, Double?>,
                                 average: KeyPath<SystemSample, Double?>) -> InfoTile? {
        guard let peak = samples.range(of: hottest)?.maximum else { return nil }
        let mean = samples.range(of: average)?.average
        return InfoTile(title: title, value: MetricFormat.degrees(peak),
                        detail: mean.map { "\(tr("maks., średnio", "peak, average")) \(MetricFormat.degrees($0))" }
                            ?? tr("maksimum", "peak"))
    }

    private var thermalStateName: String {
        switch samples.worstThermalState {
        case 0: tr("Nominalny", "Nominal")
        case 1: tr("Podwyższony", "Fair")
        case 2: tr("Poważny", "Serious")
        default: tr("Krytyczny", "Critical")
        }
    }

    private func tile(_ title: String, _ metric: KeyPath<SystemSample, Double?>,
                      format: (Double) -> String, peakOnly: Bool = false) -> InfoTile? {
        guard let range = samples.range(of: metric) else { return nil }
        return InfoTile(title: title,
                        value: format(peakOnly ? range.maximum : range.average),
                        detail: peakOnly ? tr("maksimum", "peak") : "\(tr("maks.", "max")) \(format(range.maximum))")
    }

    // MARK: Charts

    private struct ChartSpec {
        let title: String
        let series: [TimeSeriesChart.Series]
        /// Fixed value axis, or nil to fit the data (temperatures read better without a zero baseline).
        let range: ClosedRange<Double>?
        let format: (Double) -> String
    }

    private var fastClusterName: String { capture.hardware?.coreTiers.first?.name ?? tr("Szybki klaster", "Fast cluster") }
    private var secondClusterName: String {
        capture.hardware?.coreTiers.dropFirst().first?.name ?? tr("Drugi klaster", "Second cluster")
    }

    /// A value axis from zero to a little above the highest point.
    private static func fromZero(_ series: [TimeSeriesChart.Series]) -> ClosedRange<Double> {
        0...((series.flatMap { $0.points.map(\.value) }.max() ?? 1) * 1.15)
    }

    private func series(_ name: String, _ metric: KeyPath<SystemSample, Double?>) -> TimeSeriesChart.Series? {
        let points = samples.compactMap { sample in
            sample[keyPath: metric].map { TimeSeriesChart.Point(time: sample.time, value: $0) }
        }
        return points.isEmpty ? nil : TimeSeriesChart.Series(id: name, points: points)
    }

    /// Mean of the sensors where it was recorded, otherwise the hottest sensor (older captures).
    private func temperatureSeries(_ name: String, average: KeyPath<SystemSample, Double?>,
                                   hottest: KeyPath<SystemSample, Double?>) -> TimeSeriesChart.Series? {
        series(name, average) ?? series(name, hottest)
    }

    private func spec(_ title: String, _ series: [TimeSeriesChart.Series?], range: ClosedRange<Double>?? = nil,
                      format: @escaping (Double) -> String) -> ChartSpec? {
        let present = series.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return ChartSpec(title: title, series: present, range: range ?? Self.fromZero(present), format: format)
    }

    /// Pairs that explain each other: load, what it costs, the heat it makes, memory and the game's CPU use.
    private var groups: [(title: String, charts: [ChartSpec])] {
        let groups: [(String, [ChartSpec?])] = [
            (tr("Obciążenie", "Load"), [
                spec(tr("Obciążenie GPU (%)", "GPU load (%)"), [series("GPU", \.gpuUtilization)],
                     range: 0...100, format: MetricFormat.percent),
                spec(tr("Aktywność klastrów CPU (%)", "CPU cluster activity (%)"),
                     [series(fastClusterName, \.fastClusterActive), series(secondClusterName, \.secondClusterActive)],
                     range: 0...100, format: MetricFormat.percent),
            ]),
            (tr("Taktowanie i moc", "Clocks and power"), [
                spec(tr("Taktowanie (MHz)", "Clock (MHz)"),
                     [series(fastClusterName, \.fastClusterFrequency), series(secondClusterName, \.secondClusterFrequency),
                      series("GPU", \.gpuFrequency)], format: MetricFormat.megahertz),
                spec(tr("Moc (W)", "Power (W)"),
                     [series("CPU", \.cpuPower), series("GPU", \.gpuPower), series(tr("Cały Mac", "Whole Mac"), \.systemPower)],
                     format: MetricFormat.watts),
            ]),
            (tr("Ciepło", "Heat"), [
                spec(tr("Temperatura (°C)", "Temperature (°C)"),
                     [temperatureSeries("CPU", average: \.cpuTemperatureAverage, hottest: \.cpuTemperature),
                      temperatureSeries("GPU", average: \.gpuTemperatureAverage, hottest: \.gpuTemperature)],
                     range: .some(nil), format: MetricFormat.degrees),
                spec(tr("Wentylator (obr./min)", "Fan (RPM)"), [series(tr("Wentylator", "Fan"), \.fanSpeed)],
                     format: MetricFormat.rpm),
            ]),
            (tr("Pamięć i proces", "Memory and process"), [
                spec(tr("Pamięć (MB)", "Memory (MB)"),
                     [series(tr("Gra", "Game"), \.processMemory), series("GPU", \.gpuMemory)], format: MetricFormat.megabytes),
                spec(tr("CPU gry (% jednego rdzenia)", "Game CPU (% of one core)"), [series("CPU", \.processCPU)],
                     format: MetricFormat.percent),
            ]),
        ]
        return groups.map { ($0.0, $0.1.compactMap { $0 }) }.filter { !$0.charts.isEmpty }
    }

    /// Full width, above the system charts so a stutter can be traced down to them.
    private var frameTime: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Czas klatki (ms)", "Frame time (ms)")).font(.headline)
            FrameTimeChart(points: cached.points, duration: duration, hoverTime: $hoverTime)
                .frame(height: 220)
            // The average matches AVG: total time over frame count.
            if let range = cached.frameTimeRange {
                RangeSummary(range: range) { String(format: "%.2f ms", $0) }
            }
        }
    }

    private func chart(_ spec: ChartSpec, showsTimeAxis: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(spec.title).font(.subheadline).foregroundStyle(.secondary)
            TimeSeriesChart(series: spec.series, duration: duration, range: spec.range, format: spec.format,
                            hoverTime: $hoverTime, height: 120, showsTimeAxis: showsTimeAxis)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var body: some View {
        let infoLines = [
            capture.hardware.map(\.summary),
            capture.hardware.flatMap { $0.coreTiers.isEmpty ? nil : coresLine($0) },
            gameContextLine,
        ].compactMap { $0 }
        let groups = groups

        if !infoLines.isEmpty || !samples.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("System").font(.headline)
                if !infoLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(infoLines, id: \.self) { Text($0) }
                    }
                    .foregroundStyle(.secondary)
                    .help(tr("Rozdzielczość okna gry to rozdzielczość wyjściowa. Gra może renderować w niższej i skalować obraz, np. przez MetalFX. W trybie okienkowym wymiar obejmuje też pasek tytułu okna.",
                             "The game window's resolution is the output resolution. The game may render lower and upscale, e.g. with MetalFX. In windowed mode the size also includes the window's title bar."))
                }
                if !samples.isEmpty {
                    tiles
                }
                frameTime
                    .padding(.top, 8)
                ForEach(groups.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(groups[index].title.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 24) {
                            let last = index == groups.count - 1
                            chart(groups[index].charts[0], showsTimeAxis: last)
                            if groups[index].charts.count > 1 {
                                chart(groups[index].charts[1], showsTimeAxis: last)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                if !groups.isEmpty {
                    Text(tr("Czas od początku pomiaru (s)", "Time since the start of the capture (s)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            // Old captures without hardware or system data still get their frame time chart.
            frameTime
        }
    }

    private var tiles: some View {
        let tiles = [
            tile(tr("Obciążenie GPU", "GPU load"), \.gpuUtilization, format: MetricFormat.percent),
            temperatureTile(tr("Temperatura CPU", "CPU temperature"), hottest: \.cpuTemperature, average: \.cpuTemperatureAverage),
            temperatureTile(tr("Temperatura GPU", "GPU temperature"), hottest: \.gpuTemperature, average: \.gpuTemperatureAverage),
            tile(tr("RAM gry", "Game RAM"), \.processMemory, format: MetricFormat.megabytes, peakOnly: true),
            tile(tr("CPU gry", "Game CPU"), \.processCPU, format: MetricFormat.percent),
            InfoTile(title: tr("Stan termiczny", "Thermal state"), value: thermalStateName,
                     detail: tr("najgorszy", "worst")),
        ].compactMap { $0 }
        let wholeMac = samples.range(of: \.systemPower)
        let powerTiles = [
            tile(tr("Moc CPU", "CPU power"), \.cpuPower, format: MetricFormat.watts),
            tile(tr("Moc GPU", "GPU power"), \.gpuPower, format: MetricFormat.watts),
            tile(tr("Moc całego Maca", "Whole-Mac power"), \.systemPower, format: MetricFormat.watts),
            wholeMac.flatMap { range in
                range.average > 0 && averageFPS.isFinite
                    ? InfoTile(title: tr("FPS na wat", "FPS per watt"),
                               value: String(format: "%.2f", averageFPS / range.average),
                               detail: tr("średnie FPS / moc Maca", "average FPS / Mac power"))
                    : nil
            },
        ].compactMap { $0 }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ForEach(tiles.indices, id: \.self) { tiles[$0] }
            }
            if !powerTiles.isEmpty {
                HStack(spacing: 12) {
                    ForEach(powerTiles.indices, id: \.self) { powerTiles[$0] }
                }
                Text(tr("Moc CPU jest szacowana z histogramów mocy klastrów, bo macOS nie udostępnia licznika energii CPU. Temperatury na wykresach to średnia z czujników.",
                        "CPU power is estimated from per-cluster power histograms, because macOS does not expose the CPU energy counter. Chart temperatures are the mean across sensors."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A tile for a value that is not a frame rate.
struct InfoTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
