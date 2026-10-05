import MetalCapCore
import SwiftUI

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
                        Text("\(fps(CaptureCache.shared.entry(for: capture).metrics?.average ?? .nan)) FPS")
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
        // The toolbar stays transparent: an opaque one overhangs the sidebar edge by a few points.
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
