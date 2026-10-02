import Charts
import MetalCapCore
import SwiftUI

private func fps(_ value: Double) -> String {
    value.isFinite ? String(format: "%.1f", value) : "–"
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            List(model.captures, selection: $model.selection) { capture in
                VStack(alignment: .leading, spacing: 2) {
                    Text(capture.processName).lineLimit(1)
                    HStack {
                        Text(capture.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text("\(fps(capture.metrics?.average ?? .nan)) FPS")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Usuń", role: .destructive) { model.delete(capture.id) }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                if let message = model.message {
                    Label(message, systemImage: "info.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary)
                }
                if let capture = model.captures.first(where: { $0.id == model.selection }) {
                    CaptureDetailView(capture: capture)
                } else {
                    ContentUnavailableView(
                        "Brak przechwyceń",
                        systemImage: "speedometer",
                        description: Text("Włącz Metal HUD, uruchom grę i naciśnij \(model.hotKey.display), żeby rozpocząć i zakończyć pomiar."))
                }
            }
        }
        // Without this the toolbar gets its own white strip that overhangs the sidebar edge.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationSubtitle(model.activeProcess.map { "Wykryto: \($0)" } ?? "Nie wykryto gry")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 6) {
                    Text("Metal HUD")
                    Toggle("Metal HUD", isOn: Binding(get: { model.hudEnabled }, set: model.setHUDEnabled))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                .padding(.horizontal, 6)
                .help("Włącza Metal HUD i logowanie klatek dla aplikacji uruchomionych od tej chwili")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Uruchom grę…", systemImage: "play.fill") { model.launchGame() }
                    .labelStyle(.titleAndIcon)
                    .help("Uruchamia grę z Metal HUD i czyta czasy klatek bezpośrednio z niej")
                Button(model.isRecording ? "Zatrzymaj" : "Nagrywaj",
                       systemImage: model.isRecording ? "stop.circle.fill" : "record.circle") {
                    model.toggleCapture()
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.isFinishing)
                .help("Start/stop przechwytywania (\(model.hotKey.display))")
                Button("Ustawienia", systemImage: "gearshape") { showingSettings = true }
                    .help("Ustawienia")
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lowVariant") private var lowVariant = LowVariant.average

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent("Skrót start/stop") { HotKeyRecorder(combo: $model.hotKey) }
                Picker("Sposób liczenia 1% Low", selection: $lowVariant) {
                    ForEach(LowVariant.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("Gotowe") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// The two "x% low" definitions CapFrameX offers.
enum LowVariant: String, CaseIterable {
    case average, integral

    var label: String {
        switch self {
        case .average: "Average (średnia z najwolniejszych klatek)"
        case .integral: "Integral (jak MSI Afterburner)"
        }
    }
}

struct CaptureDetailView: View {
    let capture: Capture
    @AppStorage("lowVariant") private var lowVariant = LowVariant.average

    var body: some View {
        if let metrics = capture.metrics {
            // The chart takes whatever height is left; the page scrolls only when the window is too short.
            GeometryReader { geometry in
              ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(metrics)
                    HStack(spacing: 12) {
                        MetricTile(title: "AVG", value: metrics.average, prominent: true)
                        MetricTile(title: "P1", value: metrics.p1, prominent: true)
                        MetricTile(title: "1% Low",
                                   value: lowVariant == .average ? metrics.onePercentLowAverage : metrics.onePercentLowIntegral,
                                   prominent: true)
                    }
                    HStack(spacing: 12) {
                        MetricTile(title: "Max", value: metrics.max)
                        MetricTile(title: "Mediana", value: metrics.median)
                        MetricTile(title: "P5", value: metrics.p5)
                        MetricTile(title: "P0.2", value: metrics.p0_2)
                        MetricTile(title: "0.1% Low",
                                   value: lowVariant == .average ? metrics.pointOnePercentLowAverage : metrics.pointOnePercentLowIntegral)
                        MetricTile(title: "Min", value: metrics.min)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Czas klatki").font(.headline)
                        FrameTimeChart(points: FrameTimeChart.points(for: capture.frameTimes))
                            .frame(minHeight: 240, maxHeight: .infinity)
                    }
                }
                .padding(20)
                .frame(minHeight: geometry.size.height, alignment: .top)
              }
            }
        } else {
            ContentUnavailableView("Przechwycenie nie zawiera klatek", systemImage: "exclamationmark.triangle")
        }
    }

    /// Says when the log did not deliver every frame of the capture window.
    private var warning: String? {
        if let coverage = capture.coverage, coverage < 0.95 {
            return "Klatki pokrywają tylko \(Int((coverage * 100).rounded()))% czasu pomiaru — część nie trafiła do logu."
        }
        if let missing = capture.missingFrames, missing * 100 >= capture.frameTimes.count {
            return "Licznik Metal HUD wskazuje o \(missing) klatek więcej, niż było w logu."
        }
        return nil
    }

    private func header(_ metrics: FrameMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(capture.processName).font(.title2).bold()
            Text("\(capture.startedAt.formatted(date: .long, time: .standard)) · \(String(format: "%.1f", metrics.duration)) s · \(metrics.frameCount) klatek")
                .foregroundStyle(.secondary)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: Double
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(fps(value))
                    .font(prominent ? .system(size: 34, weight: .semibold) : .title3.weight(.medium))
                    .monospacedDigit()
                if prominent { Text("FPS").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct FrameTimeChart: View {
    struct Point: Identifiable {
        let id: Int
        /// Seconds since the start of the capture.
        let time: Double
        /// Frame time in milliseconds.
        let frameTime: Double
    }

    let points: [Point]
    @ViewState private var hovered: Point?

    /// One point per frame; long captures are reduced to the slowest frame per bucket so spikes survive.
    static func points(for frameTimes: [Double], limit: Int = 3000) -> [Point] {
        var elapsed = 0.0
        let all = frameTimes.enumerated().map { index, frameTime -> Point in
            elapsed += frameTime / 1000
            return Point(id: index, time: elapsed, frameTime: frameTime)
        }
        guard all.count > limit else { return all }
        let bucket = Int((Double(all.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: all.count, by: bucket).map { start in
            all[start..<min(start + bucket, all.count)].max { $0.frameTime < $1.frameTime }!
        }
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Czas", point.time), y: .value("Czas klatki", point.frameTime))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let hovered {
                RuleMark(x: .value("Czas", hovered.time))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("\(String(format: "%.2f", hovered.frameTime)) ms · \(fps(1000 / hovered.frameTime)) FPS")
                            .font(.caption)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.background, in: RoundedRectangle(cornerRadius: 4))
                    }
                PointMark(x: .value("Czas", hovered.time), y: .value("Czas klatki", hovered.frameTime))
                    .symbolSize(40)
            }
        }
        .chartXAxisLabel("Czas (s)")
        .chartYAxisLabel("ms")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let frame = proxy.plotFrame,
                              let time: Double = proxy.value(atX: location.x - geometry[frame].origin.x) else {
                            hovered = nil
                            return
                        }
                        hovered = nearestPoint(to: time)
                    }
            }
        }
    }

    private func nearestPoint(to time: Double) -> Point? {
        guard let after = points.firstIndex(where: { $0.time >= time }) else { return points.last }
        guard after > 0 else { return points[after] }
        let before = after - 1
        return time - points[before].time < points[after].time - time ? points[before] : points[after]
    }
}
