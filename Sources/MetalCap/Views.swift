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
    @AppStorage("sortKey") private var sortKey = CaptureSortKey.date
    @AppStorage("sortAscending") private var sortAscending = false

    var body: some View {
        NavigationSplitView {
            List(model.captures.sorted(by: sortKey, ascending: sortAscending), selection: $model.selection) { capture in
                VStack(alignment: .leading, spacing: 2) {
                    Text(capture.displayName).lineLimit(1)
                    HStack {
                        Text(formatted(capture.startedAt, date: .abbreviated, time: .shortened))
                        Spacer()
                        Text("\(fps(capture.metrics?.average ?? .nan)) FPS")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let comment = capture.comment {
                        Text(comment).font(.caption).lineLimit(2)
                    }
                }
                .contextMenu {
                    Button(tr("Zmień nazwę…", "Rename…")) { model.renaming = capture }
                    Button(tr("Usuń", "Delete"), role: .destructive) { model.delete(capture.id) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 6) {
                    Picker(tr("Sortuj według", "Sort by"), selection: $sortKey) {
                        Text(tr("Data", "Date")).tag(CaptureSortKey.date)
                        Text(tr("Nazwa gry", "Game name")).tag(CaptureSortKey.name)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    Button(sortAscending ? tr("Rosnąco", "Ascending") : tr("Malejąco", "Descending"),
                           systemImage: sortAscending ? "arrow.up" : "arrow.down") {
                        sortAscending.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .controlSize(.small)
                    .help(sortAscending
                          ? tr("Rosnąco — kliknij, żeby odwrócić", "Ascending — click to reverse")
                          : tr("Malejąco — kliknij, żeby odwrócić", "Descending — click to reverse"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                if model.frameDataRedacted {
                    HStack {
                        Label(model.logUnlocked
                              ? tr("Log nadal ukrywa czasy klatek tej gry. Uruchom ją ponownie i odczekaj chwilę; jeśli to nie pomoże, profil nie działa na tej wersji macOS.",
                                   "The log still hides this game's frame times. Restart the game and wait a moment; if that does not help, the profile does not work on this macOS version.")
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
                    HStack {
                        Label(message, systemImage: "info.circle")
                        Spacer()
                        Button("OK") { model.message = nil }
                    }
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
        .sheet(item: $model.renaming) { RenameView(capture: $0) }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TabView(selection: $model.settingsTab) {
                GeneralSettingsView()
                    .padding(16)
                    .tabItem { Text(tr("Ogólne", "General")) }
                    .tag(0)
                OverlaySettingsView()
                    .padding(16)
                    .tabItem { Text(tr("Nakładka HUD", "HUD overlay")) }
                    .tag(1)
            }
            HStack {
                Spacer()
                Button(tr("Gotowe", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("lowVariant") private var lowVariant = LowVariant.average
    @AppStorage("csvDialect") private var csvDialect = CSVDialect.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                Picker(tr("Format CSV", "CSV format"), selection: $csvDialect) {
                    Text(tr("Standardowy (przecinek, kropka dziesiętna)", "Standard (comma, decimal point)")).tag(CSVDialect.standard)
                    Text(tr("Excel PL (średnik, przecinek dziesiętny)", "European Excel (semicolon, decimal comma)")).tag(CSVDialect.semicolon)
                }
                LabeledContent(tr("Czasy klatek w logu", "Frame times in the log")) {
                    HStack {
                        Text(model.logUnlocked ? tr("Odblokowane", "Unlocked") : tr("Ukryte", "Hidden"))
                            .foregroundStyle(.secondary)
                        if model.logUnlocked {
                            Button(tr("Usuń profil…", "Remove profile…")) { model.openProfileSettings() }
                        } else {
                            Button(tr("Zainstaluj profil…", "Install profile…")) { model.installUnlockProfile() }
                        }
                    }
                }
            }
            Text(tr("Menu systemowe i okna wyboru plików zmienią język po ponownym uruchomieniu MetalCap.",
                    "System menus and file dialogs switch language after MetalCap is restarted."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Appearance of the Metal HUD overlay: metrics, position, size and opacity.
struct OverlaySettingsView: View {
    @EnvironmentObject private var model: AppModel

    /// What a custom selection starts from.
    private static let starterElements: Set<String> = ["fps", "frameinterval", "gputime", "memory"]

    private static func title(for element: String) -> String {
        switch element {
        case "device": tr("Urządzenie (GPU)", "Device (GPU)")
        case "rosetta": "Rosetta"
        case "layersize": tr("Rozmiar warstwy", "Layer size")
        case "layerscale": tr("Skala warstwy", "Layer scale")
        case "memory": tr("Pamięć", "Memory")
        case "fps": "FPS"
        case "frameinterval": tr("Czas klatki", "Frame interval")
        case "gputime": tr("Czas GPU", "GPU time")
        case "thermal": tr("Stan termiczny", "Thermal state")
        case "frameintervalgraph": tr("Wykres czasu klatki", "Frame interval graph")
        case "presentdelay": tr("Opóźnienie prezentacji", "Present delay")
        case "frameintervalhistogram": tr("Histogram czasu klatki", "Frame interval histogram")
        case "metalcpu": tr("Czas CPU Metal", "Metal CPU time")
        case "gputimeline": tr("Oś czasu GPU", "GPU timeline")
        case "shaders": tr("Kompilacja shaderów", "Shader compilation")
        case "framenumber": tr("Numer klatki", "Frame number")
        case "disk": tr("Dysk", "Disk")
        case "fpsgraph": tr("Wykres FPS", "FPS graph")
        case "toplabeledcommandbuffers": tr("Najcięższe bufory poleceń", "Top command buffers")
        case "toplabeledencoders": tr("Najcięższe enkodery", "Top encoders")
        default: element
        }
    }

    private func isShown(_ element: String) -> Binding<Bool> {
        Binding(
            get: { model.hudConfiguration.elements?.contains(element) ?? false },
            set: { shown in
                var elements = model.hudConfiguration.elements ?? []
                if shown { elements.insert(element) } else { elements.remove(element) }
                // The HUD must keep showing something, or it stops logging frame intervals.
                if !elements.isEmpty { model.hudConfiguration.elements = elements }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(tr("Własny wybór elementów", "Choose elements myself"), isOn: Binding(
                get: { model.hudConfiguration.elements != nil },
                set: { model.hudConfiguration.elements = $0 ? Self.starterElements : nil }))
            if model.hudConfiguration.elements != nil {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(HUDConfiguration.allElements, id: \.self) { element in
                        Toggle(Self.title(for: element), isOn: isShown(element))
                    }
                }
                .padding(.leading, 20)
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Pozycja", "Position"))
                    Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                        ForEach(0..<3, id: \.self) { row in
                            GridRow {
                                ForEach(0..<3, id: \.self) { column in
                                    let alignment = HUDConfiguration.alignments[row * 3 + column]
                                    let selected = model.hudConfiguration.alignment == alignment
                                    Button { model.hudConfiguration.alignment = alignment } label: {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                                            .frame(width: 30, height: 20)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(alignment)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(tr("Skala", "Scale")) {
                        HStack {
                            Slider(value: $model.hudConfiguration.scale, in: 0.1...0.6)
                            Text("\(Int((model.hudConfiguration.scale * 100).rounded()))%")
                                .monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    LabeledContent(tr("Krycie", "Opacity")) {
                        HStack {
                            Slider(value: $model.hudConfiguration.opacity, in: 0.2...1)
                            Text("\(Int((model.hudConfiguration.opacity * 100).rounded()))%")
                                .monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    Button(tr("Przywróć domyślne", "Restore defaults")) { model.hudConfiguration = HUDConfiguration() }
                }
            }
            Text(tr("Zmiany dotyczą gier uruchomionych po ich wprowadzeniu. Skala to szerokość nakładki względem szerokości obrazu gry.",
                    "Changes apply to games launched afterwards. Scale is the overlay width relative to the game's image width."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Shown at launch while the unified log still hides frame data: explains why a profile is
/// needed and walks through installing it.
struct UnlockPromptView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var steps: [String] {
        [
            tr("Kliknij „Zainstaluj profil…”. MetalCap przekaże profil systemowi i otworzy Ustawienia systemowe.",
               "Click “Install profile…”. MetalCap hands the profile to macOS and opens System Settings."),
            tr("W Ustawieniach systemowych wejdź w Ogólne → Zarządzanie urządzeniem, kliknij dwukrotnie „MetalCap – czasy klatek” i wybierz Zainstaluj. macOS zapyta o hasło i oznaczy profil jako niepodpisany.",
               "In System Settings go to General → Device Management, double-click “MetalCap – frame times” and choose Install. macOS asks for your password and marks the profile as unsigned."),
            tr("Uruchom ponownie grę. Zmiana może zacząć działać po minucie lub dwóch.",
               "Restart the game. The change can take a minute or two to apply."),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tr("Odblokuj pomiar dla wszystkich gier", "Unlock captures for every game"), systemImage: "lock.open")
                .font(.title3.weight(.semibold))
            Text(tr("macOS ukrywa czasy klatek Metal HUD w logu systemowym. Dlatego MetalCap mierzy teraz tylko gry uruchomione przyciskiem „Uruchom grę…”, a gry ze Steam, CrossOver i innych launcherów pozostają niewidoczne.",
                    "macOS hides Metal HUD frame times in the system log. That is why MetalCap can currently measure only games started with “Launch game…”, while games from Steam, CrossOver and other launchers stay invisible."))
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("Odsłania je profil konfiguracyjny. Dotyczy on wyłącznie komunikatów Metal HUD, czyli numerów i czasów klatek; reszta logu pozostaje ukryta. Usuniesz go w tym samym miejscu Ustawień systemowych.",
                    "A configuration profile reveals them. It covers only Metal HUD messages, i.e. frame numbers and frame times; the rest of the log stays hidden. You can remove it in the same place in System Settings."))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Jak to włączyć", "How to turn it on")).font(.headline)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Toggle(tr("Nie pokazuj ponownie", "Don't show again"), isOn: $model.skipUnlockPrompt)
                Spacer()
                Button(tr("Nie teraz", "Not now")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Zainstaluj profil…", "Install profile…")) {
                    dismiss()
                    model.installUnlockProfile()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 540)
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
    @EnvironmentObject private var model: AppModel
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
                        // The average matches AVG: total time over frame count.
                        if let range = MetricRange(capture.frameTimes.filter { $0 > 0 }) {
                            RangeSummary(range: range) { String(format: "%.2f ms", $0) }
                        }
                    }
                    if let system = capture.system, !system.isEmpty {
                        SystemSectionView(samples: system, duration: metrics.duration, averageFPS: metrics.average,
                                          coreTiers: capture.hardware?.coreTiers.map(\.name) ?? [])
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
            if let hardware = capture.hardware {
                Text(hardware.summary).foregroundStyle(.secondary)
            }
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

/// Asks for a new name for a capture, optionally for every capture of the same process.
struct RenameView: View {
    let capture: Capture
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name: String
    @ViewState private var wholeProcess = false

    init(capture: Capture) {
        self.capture = capture
        _name = ViewState(initialValue: capture.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Zmień nazwę", "Rename")).font(.title3.weight(.semibold))
            TextField(capture.processName, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(tr("Zastosuj do wszystkich wyników procesu „\(capture.processName)”",
                          "Apply to every result of the process “\(capture.processName)”"), isOn: $wholeProcess)
                Text(tr("Nazwa będzie też nadawana przyszłym pomiarom tego procesu. Puste pole przywraca nazwę procesu.",
                        "The name is also given to future captures of this process. An empty field restores the process name."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(tr("Anuluj", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Zapisz", "Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        model.rename(capture.id, to: name, wholeProcess: wholeProcess)
        dismiss()
    }
}

/// The capture's note. Edited locally and saved shortly after typing stops (and on Return or
/// when the capture changes), so the capture file is not rewritten on every keystroke.
struct CommentField: View {
    let capture: Capture
    @EnvironmentObject private var model: AppModel
    @ViewState private var text: String

    init(capture: Capture) {
        self.capture = capture
        _text = ViewState(initialValue: capture.comment ?? "")
    }

    var body: some View {
        TextField(tr("Komentarz, np. ustawienia grafiki", "Comment, e.g. graphics settings"), text: $text)
            .textFieldStyle(.roundedBorder)
            .onSubmit(save)
            .task(id: text) {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { save() }
            }
            .onDisappear(perform: save)
    }

    private func save() {
        model.setComment(text, for: capture.id)
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

/// GPU load, temperatures, CPU and memory use recorded alongside the frames.
struct SystemSectionView: View {
    let samples: [SystemSample]
    let duration: Double
    /// Average frame rate of the capture, for the frames-per-watt figure.
    let averageFPS: Double
    /// Names of the CPU core tiers, fastest first (e.g. "Super", "Performance"), when known.
    var coreTiers: [String] = []

    private var fastClusterName: String { coreTiers.first ?? tr("Szybki klaster", "Fast cluster") }
    private var secondClusterName: String { coreTiers.dropFirst().first ?? tr("Drugi klaster", "Second cluster") }

    private static func megabytes(_ value: Double) -> String {
        value >= 1024 ? String(format: "%.1f GB", value / 1024) : String(format: "%.0f MB", value)
    }

    /// A value axis from zero to a little above the highest point.
    private static func fromZero(_ series: [TimeSeriesChart.Series]) -> ClosedRange<Double> {
        0...((series.flatMap { $0.points.map(\.value) }.max() ?? 1) * 1.15)
    }

    private static func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
    private static func degrees(_ value: Double) -> String { String(format: "%.0f°C", value) }
    private static func megahertz(_ value: Double) -> String { String(format: "%.0f MHz", value) }
    private static func rpm(_ value: Double) -> String { String(format: "%.0f", value) }
    private static func watts(_ value: Double) -> String { String(format: value < 10 ? "%.1f W" : "%.0f W", value) }

    /// Temperature tile: the peak of the hottest sensor, with the mean across sensors underneath.
    private func temperatureTile(_ title: String, hottest: KeyPath<SystemSample, Double?>,
                                 average: KeyPath<SystemSample, Double?>) -> InfoTile? {
        guard let peak = samples.range(of: hottest)?.maximum else { return nil }
        let mean = samples.range(of: average)?.average
        return InfoTile(title: title, value: Self.degrees(peak),
                        detail: mean.map { "\(tr("maks., średnio", "peak, average")) \(Self.degrees($0))" }
                            ?? tr("maksimum", "peak"))
    }

    /// Mean of the sensors where it was recorded, otherwise the hottest sensor (older captures).
    private func temperatureSeries(_ name: String, average: KeyPath<SystemSample, Double?>,
                                   hottest: KeyPath<SystemSample, Double?>) -> TimeSeriesChart.Series? {
        series(name, average) ?? series(name, hottest)
    }

    private func series(_ name: String, _ metric: KeyPath<SystemSample, Double?>) -> TimeSeriesChart.Series? {
        let points = samples.compactMap { sample in
            sample[keyPath: metric].map { TimeSeriesChart.Point(time: sample.time, value: $0) }
        }
        return points.isEmpty ? nil : TimeSeriesChart.Series(id: name, points: points)
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

    var body: some View {
        let tiles = [
            tile(tr("Obciążenie GPU", "GPU load"), \.gpuUtilization, format: Self.percent),
            temperatureTile(tr("Temperatura CPU", "CPU temperature"), hottest: \.cpuTemperature, average: \.cpuTemperatureAverage),
            temperatureTile(tr("Temperatura GPU", "GPU temperature"), hottest: \.gpuTemperature, average: \.gpuTemperatureAverage),
            tile(tr("RAM gry", "Game RAM"), \.processMemory, format: Self.megabytes, peakOnly: true),
            tile(tr("CPU gry", "Game CPU"), \.processCPU, format: Self.percent),
            InfoTile(title: tr("Stan termiczny", "Thermal state"), value: thermalStateName,
                     detail: tr("najgorszy", "worst")),
        ].compactMap { $0 }
        let wholeMac = samples.range(of: \.systemPower)
        let powerTiles = [
            tile(tr("Moc CPU", "CPU power"), \.cpuPower, format: Self.watts),
            tile(tr("Moc GPU", "GPU power"), \.gpuPower, format: Self.watts),
            tile(tr("Moc całego Maca", "Whole-Mac power"), \.systemPower, format: Self.watts),
            wholeMac.flatMap { range in
                range.average > 0 && averageFPS.isFinite
                    ? InfoTile(title: tr("FPS na wat", "FPS per watt"),
                               value: String(format: "%.2f", averageFPS / range.average),
                               detail: tr("średnie FPS / moc Maca", "average FPS / Mac power"))
                    : nil
            },
        ].compactMap { $0 }
        let power = [series("CPU", \.cpuPower), series("GPU", \.gpuPower),
                     series(tr("Cały Mac", "Whole Mac"), \.systemPower)].compactMap { $0 }
        let memory = [series(tr("Gra", "Game"), \.processMemory), series("GPU", \.gpuMemory)].compactMap { $0 }
        let gameCPU = [series("CPU", \.processCPU)].compactMap { $0 }
        let clusterActivity = [series(fastClusterName, \.fastClusterActive),
                               series(secondClusterName, \.secondClusterActive)].compactMap { $0 }
        let clocks = [series(fastClusterName, \.fastClusterFrequency), series(secondClusterName, \.secondClusterFrequency),
                      series("GPU", \.gpuFrequency)].compactMap { $0 }
        let fan = [series(tr("Wentylator", "Fan"), \.fanSpeed)].compactMap { $0 }
        // A nil range lets the chart fit the data; temperatures read better without a zero baseline.
        let charts: [(title: String, series: [TimeSeriesChart.Series], range: ClosedRange<Double>?, format: (Double) -> String)] = [
            (tr("Obciążenie GPU (%)", "GPU load (%)"), [series("GPU", \.gpuUtilization)].compactMap { $0 }, 0...100, Self.percent),
            (tr("Temperatura (°C)", "Temperature (°C)"),
             [temperatureSeries("CPU", average: \.cpuTemperatureAverage, hottest: \.cpuTemperature),
              temperatureSeries("GPU", average: \.gpuTemperatureAverage, hottest: \.gpuTemperature)].compactMap { $0 },
             nil, Self.degrees),
            (tr("Moc (W)", "Power (W)"), power, Self.fromZero(power), Self.watts),
            (tr("Pamięć (MB)", "Memory (MB)"), memory, Self.fromZero(memory), Self.megabytes),
            (tr("CPU gry (% jednego rdzenia)", "Game CPU (% of one core)"), gameCPU, Self.fromZero(gameCPU), Self.percent),
            (tr("Aktywność klastrów CPU (%)", "CPU cluster activity (%)"), clusterActivity, 0...100, Self.percent),
            (tr("Taktowanie (MHz)", "Clock (MHz)"), clocks, Self.fromZero(clocks), Self.megahertz),
            (tr("Wentylator (obr./min)", "Fan (RPM)"), fan, Self.fromZero(fan), Self.rpm),
        ].filter { !$0.series.isEmpty }

        VStack(alignment: .leading, spacing: 12) {
            Text("System").font(.headline)
            HStack(spacing: 12) {
                ForEach(tiles.indices, id: \.self) { tiles[$0] }
            }
            if !powerTiles.isEmpty {
                HStack(spacing: 12) {
                    ForEach(powerTiles.indices, id: \.self) { powerTiles[$0] }
                }
                Text(tr("Moc CPU jest szacowana z histogramów mocy klastrów, bo macOS nie udostępnia licznika energii CPU. Temperatury na wykresie to średnia z czujników.",
                        "CPU power is estimated from per-cluster power histograms, because macOS does not expose the CPU energy counter. Chart temperatures are the mean across sensors."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20, alignment: .top), GridItem(.flexible(), alignment: .top)],
                      alignment: .leading, spacing: 16) {
                ForEach(charts.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(charts[index].title).font(.subheadline).foregroundStyle(.secondary)
                        TimeSeriesChart(series: charts[index].series, duration: duration,
                                        range: charts[index].range, format: charts[index].format)
                    }
                }
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

/// "min · avg · max" for one series, optionally led by the series' colour and name.
struct RangeSummary: View {
    var color: Color?
    var name: String?
    let range: MetricRange
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 8, height: 8) }
            if let name { Text(name) }
            Text("min \(format(range.minimum)) · \(tr("śr.", "avg")) \(format(range.average)) · \(tr("maks.", "max")) \(format(range.maximum))")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// One or more metrics over the capture, with a readout under the pointer and
/// each series' lowest, average and highest value underneath.
struct TimeSeriesChart: View {
    struct Point {
        let time: Double
        let value: Double
    }

    struct Series: Identifiable {
        let id: String
        let points: [Point]
    }

    let series: [Series]
    /// Length of the capture in seconds; the time axis spans it so all charts line up.
    let duration: Double
    /// Fixed value axis, or nil to fit the data.
    let range: ClosedRange<Double>?
    let format: (Double) -> String
    @ViewState private var hoverTime: Double?

    /// Categorical colours in a fixed order, with separate steps for light and dark appearance.
    private static let seriesColors: [Color] = [
        (0x2A78D6, 0x3987E5), (0xEB6834, 0xD95926), (0x1BAF7A, 0x199E70),
    ].map { light, dark in
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    private var fittedRange: ClosedRange<Double> {
        let values = series.flatMap { $0.points.map(\.value) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let margin = Swift.max((high - low) * 0.15, high * 0.02, 1)
        return Swift.max(0, low - margin)...(high + margin)
    }

    private func value(of series: Series, at time: Double) -> Double? {
        series.points.min { abs($0.time - time) < abs($1.time - time) }?.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chart.frame(height: 150)
            // These rows double as the legend.
            ForEach(Array(series.enumerated()), id: \.offset) { index, series in
                if let range = MetricRange(series.points.map(\.value)) {
                    RangeSummary(color: self.series.count > 1 ? Self.seriesColors[index % Self.seriesColors.count] : nil,
                                 name: self.series.count > 1 ? series.id : nil, range: range, format: format)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series) { series in
                ForEach(series.points.indices, id: \.self) { index in
                    LineMark(x: .value("Time", series.points[index].time),
                             y: .value("Value", series.points[index].value),
                             series: .value("Series", series.id))
                        .foregroundStyle(by: .value("Series", series.id))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            if let hoverTime {
                RuleMark(x: .value("Time", hoverTime))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(series.compactMap { series in
                            value(of: series, at: hoverTime).map { value in
                                self.series.count > 1 ? "\(series.id) \(format(value))" : format(value)
                            }
                        }.joined(separator: " · "))
                            .font(.caption)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.background, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.id), range: Self.seriesColors)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(duration, 1))
        .chartYScale(domain: range ?? fittedRange)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let frame = proxy.plotFrame,
                              let time: Double = proxy.value(atX: location.x - geometry[frame].origin.x),
                              (0...duration).contains(time) else {
                            hoverTime = nil
                            return
                        }
                        hoverTime = time
                    }
            }
        }
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
