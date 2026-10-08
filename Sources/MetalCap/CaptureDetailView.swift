import MetalCapCore
import SwiftUI

struct CaptureDetailView: View {
    let capture: Capture
    @EnvironmentObject private var model: AppModel
    @AppStorage("lowVariant") private var lowVariant = LowVariant.average
    /// The moment under the pointer, shared by the frame time chart and every system chart.
    @ViewState private var hoverTime: Double?

    var body: some View {
        if let metrics = CaptureCache.shared.entry(for: capture).metrics {
            // The chart takes whatever height is left; the page scrolls only when the window is too short.
            GeometryReader { geometry in
              ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(metrics)
                    HStack(spacing: 12) {
                        MetricTile(title: "AVG", value: metrics.average, prominent: true)
                        MetricTile(title: "P1", value: metrics.p1, prominent: true)
                        MetricTile(title: lowVariant.metricName("1%"),
                                   value: lowVariant == .average ? metrics.onePercentLowAverage : metrics.onePercentLowIntegral,
                                   prominent: true)
                    }
                    HStack(spacing: 12) {
                        MetricTile(title: "Max", value: metrics.max)
                        MetricTile(title: tr("Mediana", "Median"), value: metrics.median)
                        MetricTile(title: "P5", value: metrics.p5)
                        MetricTile(title: "P0.2", value: metrics.p0_2)
                        MetricTile(title: lowVariant.metricName("0.1%"),
                                   value: lowVariant == .average ? metrics.pointOnePercentLowAverage : metrics.pointOnePercentLowIntegral)
                        MetricTile(title: "Min", value: metrics.min)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FPS").font(.headline)
                        MetricBarChart(items: [
                            .init(id: "AVG", value: metrics.average),
                            .init(id: "P1", value: metrics.p1),
                            .init(id: lowVariant.metricName("1%"),
                                  value: lowVariant == .average ? metrics.onePercentLowAverage : metrics.onePercentLowIntegral),
                        ])
                    }
                    SystemSectionView(capture: capture, averageFPS: metrics.average, hoverTime: $hoverTime)
                }
                .padding(20)
                .frame(minHeight: geometry.size.height, alignment: .top)
              }
            }
            // Content must not scroll up under the transparent toolbar.
            .clipped()
        } else {
            ContentUnavailableView(tr("Przechwycenie nie zawiera klatek", "The capture contains no frames"), systemImage: "exclamationmark.triangle")
        }
    }

    /// Conditions that make the result less comparable: gaps in the log, heat, power saving.
    private var notes: [String] {
        var notes = warning.map { [$0] } ?? []
        switch capture.system?.worstThermalState ?? 0 {
        case 1: notes.append(tr("Mac się nagrzewał w trakcie pomiaru (stan termiczny: podwyższony).",
                                "The Mac was warming up during the capture (thermal state: fair)."))
        case 2...: notes.append(tr("Mac ograniczał wydajność z powodu temperatury w trakcie pomiaru.",
                                   "The Mac was throttling because of heat during the capture."))
        default: break
        }
        if capture.onBattery == true {
            notes.append(tr("Pomiar na zasilaniu z baterii.", "Captured on battery power."))
        }
        if capture.gameMode == .partOfCapture {
            notes.append(tr("Tryb gry nie działał przez cały pomiar — wyniki mogą być niższe.",
                            "Game Mode was not on for the whole capture — results may be lower."))
        }
        if capture.lowPowerMode == true {
            notes.append(tr("Pomiar w trybie niskiego zużycia energii.", "Captured in Low Power Mode."))
        }
        return notes
    }

    /// Says when the log did not deliver every frame of the capture window.
    private var warning: String? {
        if let coverage = capture.coverage, coverage < 0.95 {
            let percent = Int((coverage * 100).rounded())
            return tr("Klatki pokrywają tylko \(percent)% czasu pomiaru — część nie trafiła do logu.",
                      "The frames cover only \(percent)% of the capture time — some never reached the log.")
        }
        if let missing = capture.missingFrames, missing * 100 >= capture.frameTimes.count {
            return tr("Licznik Metal HUD wskazuje więcej klatek, niż było w logu (różnica: \(missing)).",
                      "The Metal HUD counter reports more frames than the log contained (difference: \(missing)).")
        }
        return nil
    }

    private func header(_ metrics: FrameMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(capture.displayName).font(.title2).bold()
                Button(tr("Zmień nazwę", "Rename"), systemImage: "pencil") { model.renaming = capture }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(tr("Zmień nazwę", "Rename"))
                Spacer()
                Menu(tr("Eksportuj", "Export"), systemImage: "square.and.arrow.up") {
                    Button(tr("Pełny wynik (JSON)…", "Full result (JSON)…")) { model.export(.json, capture: capture) }
                    Button(tr("Klatki (CSV)…", "Frames (CSV)…")) { model.export(.framesCSV, capture: capture) }
                    Button(tr("Metryki systemowe (CSV)…", "System metrics (CSV)…")) { model.export(.systemCSV, capture: capture) }
                        .disabled(capture.system?.isEmpty != false)
                    Divider()
                    Button(tr("Podsumowanie wszystkich wyników (CSV)…", "Summary of all results (CSV)…")) {
                        model.export(.summaryCSV, capture: capture)
                    }
                }
                .fixedSize()
            }
            if capture.name != nil {
                Text(tr("Proces: \(capture.processName)", "Process: \(capture.processName)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(formatted(capture.startedAt, date: .long, time: .standard)) · \(String(format: "%.1f", metrics.duration)) s · \(tr("klatki", "frames")): \(metrics.frameCount)")
                .foregroundStyle(.secondary)
            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            CommentField(capture: capture)
                .id(capture.id)
                .padding(.top, 6)
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: Double
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
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
