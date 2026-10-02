import Charts
import MetalCapCore
import SwiftUI

private func fps(_ value: Double) -> String {
    value.isFinite ? String(format: "%.1f", value) : "–"
}

private func formatted(_ date: Date, date dateStyle: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
    date.formatted(Date.FormatStyle(date: dateStyle, time: time).locale(L10n.language.locale))
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(model.captures, selection: $model.selection) { capture in
                VStack(alignment: .leading, spacing: 2) {
                    Text(capture.processName).lineLimit(1)
                    HStack {
                        Text(formatted(capture.startedAt, date: .abbreviated, time: .shortened))
                        Spacer()
                        Text("\(fps(capture.metrics?.average ?? .nan)) FPS")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button(tr("Usuń", "Delete"), role: .destructive) { model.delete(capture.id) }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                if model.frameDataRedacted {
                    HStack {
                        Label(model.logUnlocked
                              ? tr("Log nadal ukrywa czasy klatek tej gry. Uruchom ją ponownie; jeśli to nie pomoże, odblokowanie nie działa na tej wersji macOS.",
                                   "The log still hides this game's frame times. Restart the game; if that does not help, unlocking does not work on this macOS version.")
                              : tr("macOS ukrywa czasy klatek tej gry, więc pomiar będzie pusty.",
                                   "macOS hides this game's frame times, so a capture would be empty."),
                              systemImage: "eye.slash")
                        Spacer()
                        if !model.logUnlocked {
                            Button(tr("Odblokuj…", "Unlock…")) { model.showingUnlockPrompt = true }
                        }
                    }
                    .padding(10)
                    .background(.quaternary)
                }
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
                        tr("Brak przechwyceń", "No captures"),
                        systemImage: "speedometer",
                        description: Text(tr("Włącz Metal HUD, uruchom grę i naciśnij \(model.hotKey.display), żeby rozpocząć i zakończyć pomiar.",
                                             "Turn on Metal HUD, start a game and press \(model.hotKey.display) to begin and end a capture.")))
                }
            }
        }
        // Without this the toolbar gets its own white strip that overhangs the sidebar edge.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationSubtitle(model.activeProcess.map { tr("Wykryto: \($0)", "Detected: \($0)") }
                            ?? tr("Nie wykryto gry", "No game detected"))
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
                .help(tr("Włącza Metal HUD i logowanie klatek dla aplikacji uruchomionych od tej chwili",
                         "Turns on Metal HUD and frame logging for apps launched from now on"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(tr("Uruchom grę…", "Launch game…"), systemImage: "play.fill") { model.launchGame() }
                    .labelStyle(.titleAndIcon)
                    .help(tr("Uruchamia grę z Metal HUD i czyta czasy klatek bezpośrednio z niej",
                             "Starts a game with Metal HUD and reads frame times directly from it"))
                Button(model.isRecording ? tr("Zatrzymaj", "Stop") : tr("Nagrywaj", "Record"),
                       systemImage: model.isRecording ? "stop.circle.fill" : "record.circle") {
                    model.toggleCapture()
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.isFinishing)
                .help(tr("Start/stop przechwytywania", "Start/stop capture") + " (\(model.hotKey.display))")
                Button(tr("Ustawienia", "Settings"), systemImage: "gearshape") { model.showingSettings = true }
                    .help(tr("Ustawienia", "Settings"))
            }
        }
        .sheet(isPresented: $model.showingSettings) { SettingsView().id(model.language) }
        .sheet(isPresented: $model.showingUnlockPrompt) { UnlockPromptView() }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lowVariant") private var lowVariant = LowVariant.average

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                LabeledContent(tr("Skrót start/stop", "Start/stop shortcut")) { HotKeyRecorder(combo: $model.hotKey) }
                Picker(tr("Sposób liczenia 1% Low", "1% Low method"), selection: $lowVariant) {
                    ForEach(LowVariant.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker(tr("Język", "Language"), selection: $model.languagePreference) {
                    Text(tr("Automatycznie", "Automatic")).tag("auto")
                    Text("Polski").tag("pl")
                    Text("English").tag("en")
                }
                LabeledContent(tr("Czasy klatek w logu", "Frame times in the log")) {
                    HStack {
                        Text(model.logUnlocked ? tr("Odblokowane", "Unlocked") : tr("Ukryte", "Hidden"))
                            .foregroundStyle(.secondary)
                        Button(model.logUnlocked ? tr("Zablokuj ponownie…", "Lock again…") : tr("Odblokuj…", "Unlock…")) {
                            model.setLogUnlocked(!model.logUnlocked)
                        }
                    }
                }
            }
            Text(tr("Menu systemowe i okna wyboru plików zmienią język po ponownym uruchomieniu MetalCap.",
                    "System menus and file dialogs switch language after MetalCap is restarted."))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(tr("Gotowe", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Shown at launch while the unified log still hides frame data: explains why unlocking is needed.
struct UnlockPromptView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var points: [String] {
        [
            tr("Powstanie jeden plik: \(LogPrivacy.preferenceURL.path)",
               "One file is created: \(LogPrivacy.preferenceURL.path)"),
            tr("Odsłania on wyłącznie komunikaty Metal HUD, czyli numery i czasy klatek. Reszta logu pozostaje ukryta.",
               "It reveals only Metal HUD messages, i.e. frame numbers and frame times. The rest of the log stays hidden."),
            tr("macOS poprosi o hasło administratora.", "macOS will ask for an administrator password."),
            tr("Możesz to cofnąć w ustawieniach MetalCap.", "You can undo this in MetalCap's settings."),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tr("Odblokuj pomiar dla wszystkich gier", "Unlock captures for every game"), systemImage: "lock.open")
                .font(.title3.weight(.semibold))
            Text(tr("macOS ukrywa czasy klatek Metal HUD w logu systemowym. Dlatego MetalCap mierzy teraz tylko gry uruchomione przyciskiem „Uruchom grę…”, a gry ze Steam, CrossOver i innych launcherów pozostają niewidoczne.",
                    "macOS hides Metal HUD frame times in the system log. That is why MetalCap can currently measure only games started with “Launch game…”, while games from Steam, CrossOver and other launchers stay invisible."))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Co się zmieni", "What changes")).font(.headline)
                ForEach(points, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(point).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Toggle(tr("Nie pokazuj ponownie", "Don't show again"), isOn: $model.skipUnlockPrompt)
                Spacer()
                Button(tr("Nie teraz", "Not now")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Odblokuj…", "Unlock…")) {
                    dismiss()
                    model.setLogUnlocked(true)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 520)
    }
}

/// The two "x% low" definitions CapFrameX offers.
enum LowVariant: String, CaseIterable {
    case average, integral

    var label: String {
        switch self {
        case .average: tr("Average (średnia z najwolniejszych klatek)", "Average (mean of the slowest frames)")
        case .integral: tr("Integral (jak MSI Afterburner)", "Integral (as in MSI Afterburner)")
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
                        MetricTile(title: tr("Mediana", "Median"), value: metrics.median)
                        MetricTile(title: "P5", value: metrics.p5)
                        MetricTile(title: "P0.2", value: metrics.p0_2)
                        MetricTile(title: "0.1% Low",
                                   value: lowVariant == .average ? metrics.pointOnePercentLowAverage : metrics.pointOnePercentLowIntegral)
                        MetricTile(title: "Min", value: metrics.min)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FPS").font(.headline)
                        MetricBarChart(items: [
                            .init(id: "AVG", value: metrics.average),
                            .init(id: "P1", value: metrics.p1),
                            .init(id: "1% Low",
                                  value: lowVariant == .average ? metrics.onePercentLowAverage : metrics.onePercentLowIntegral),
                        ])
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Czas klatki", "Frame time")).font(.headline)
                        FrameTimeChart(points: FrameTimeChart.points(for: capture.frameTimes))
                            .frame(minHeight: 240, maxHeight: .infinity)
                    }
                }
                .padding(20)
                .frame(minHeight: geometry.size.height, alignment: .top)
              }
            }
        } else {
            ContentUnavailableView(tr("Przechwycenie nie zawiera klatek", "The capture contains no frames"), systemImage: "exclamationmark.triangle")
        }
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
            Text(capture.processName).font(.title2).bold()
            Text("\(formatted(capture.startedAt, date: .long, time: .standard)) · \(String(format: "%.1f", metrics.duration)) s · \(tr("klatki", "frames")): \(metrics.frameCount)")
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

/// Horizontal bars comparing the headline metrics, as on CapFrameX's analysis page.
struct MetricBarChart: View {
    struct Item: Identifiable {
        let id: String
        let value: Double
    }

    let items: [Item]

    var body: some View {
        Chart(items) { item in
            BarMark(x: .value("FPS", item.value), y: .value("Metric", item.id), height: .fixed(18))
                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                .annotation(position: .trailing, spacing: 6) {
                    Text(fps(item.value)).font(.callout.weight(.medium)).monospacedDigit()
                }
        }
        // Headroom so the value label of the longest bar is not clipped.
        .chartXScale(domain: 0...((items.map(\.value).filter(\.isFinite).max() ?? 1) * 1.12))
        .chartYAxis {
            AxisMarks(preset: .extended, position: .leading) { _ in AxisValueLabel(centered: true) }
        }
        .frame(height: CGFloat(items.count) * 32 + 24)
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
                LineMark(x: .value("Time", point.time), y: .value("Frame time", point.frameTime))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let hovered {
                RuleMark(x: .value("Time", hovered.time))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("\(String(format: "%.2f", hovered.frameTime)) ms · \(fps(1000 / hovered.frameTime)) FPS")
                            .font(.caption)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.background, in: RoundedRectangle(cornerRadius: 4))
                    }
                PointMark(x: .value("Time", hovered.time), y: .value("Frame time", hovered.frameTime))
                    .symbolSize(40)
            }
        }
        .chartXAxisLabel(tr("Czas (s)", "Time (s)"))
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
