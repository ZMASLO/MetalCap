import AppKit
import MetalCapCore
import SwiftUI

struct SettingsView: View {
    /// "MetalCap 1.0.0", from the app bundle; a bare development build has no bundle version.
    static var versionText: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return tr("MetalCap (wersja deweloperska)", "MetalCap (development build)")
        }
        return "MetalCap \(version)"
    }

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
            // The version sits centred, the Done button at the right.
            ZStack {
                Text(Self.versionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(tr("Gotowe", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
                }
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
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Zmiany zaczną działać po ponownym uruchomieniu gry.",
                            "Changes take effect after the game is restarted."))
                        .fontWeight(.medium)
                    Text(tr("Gra odczytuje te ustawienia tylko przy starcie. Jeśli po restarcie gry nic się nie zmieni, uruchom ponownie także Steam lub CrossOver. Skala to szerokość nakładki względem szerokości obrazu gry.",
                            "The game reads these settings only when it starts. If nothing changes after restarting the game, restart Steam or CrossOver as well. Scale is the overlay width relative to the game's image width."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.clockwise.circle")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
