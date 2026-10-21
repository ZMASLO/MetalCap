import MetalCapCore
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("sortKey") private var sortKey = CaptureSortKey.date
    @AppStorage("sortAscending") private var sortAscending = false
    /// Captures waiting for the user to confirm their deletion.
    @ViewState private var pendingDeletion: Set<Capture.ID> = []

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
            }
            // Acts on the right-clicked row, or on the whole selection when that row is part of it.
            .contextMenu(forSelectionType: Capture.ID.self) { ids in
                if ids.count == 1, let capture = model.captures.first(where: { ids.contains($0.id) }) {
                    Button(tr("Zmień nazwę…", "Rename…")) { model.renaming = capture }
                }
                if !ids.isEmpty {
                    Button(ids.count == 1 ? tr("Usuń", "Delete") : tr("Usuń zaznaczone (\(ids.count))", "Delete selected (\(ids.count))"),
                           role: .destructive) { requestDeletion(ids) }
                }
            }
            .onDeleteCommand { requestDeletion(model.selection) }
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
            Group {
                if model.selection.count > 1 {
                    ContentUnavailableView {
                        Label(tr("Zaznaczone wyniki: \(model.selection.count)", "Selected results: \(model.selection.count)"),
                              systemImage: "square.stack")
                    } description: {
                        Text(tr("Shift zaznacza zakres, Cmd pojedyncze wyniki.", "Shift selects a range, Command single results."))
                    } actions: {
                        Button(tr("Usuń zaznaczone…", "Delete selected…"), role: .destructive) { requestDeletion(model.selection) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let capture = model.captures.first(where: { model.selection.contains($0.id) }) {
                    CaptureDetailView(capture: capture)
                } else {
                    ContentUnavailableView(
                        tr("Brak przechwyceń", "No captures"),
                        systemImage: "speedometer",
                        description: Text(tr("Włącz Metal HUD, uruchom grę i naciśnij \(model.hotKey.display), żeby rozpocząć i zakończyć pomiar.",
                                             "Turn on Metal HUD, start a game and press \(model.hotKey.display) to begin and end a capture.")))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Notices sit right under the toolbar and push the content down by their own height.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    if model.frameDataRedacted {
                        NoticeView(systemImage: "eye.slash", text: model.logUnlocked
                              ? tr("Log nadal ukrywa czasy klatek tej gry. Uruchom ją ponownie i odczekaj chwilę; jeśli to nie pomoże, profil nie działa na tej wersji macOS.",
                                   "The log still hides this game's frame times. Restart the game and wait a moment; if that does not help, the profile does not work on this macOS version.")
                              : tr("macOS ukrywa czasy klatek tej gry, więc pomiar będzie pusty.",
                                   "macOS hides this game's frame times, so a capture would be empty.")) {
                            if !model.logUnlocked {
                                Button(tr("Odblokuj…", "Unlock…")) { model.showingUnlockPrompt = true }
                            }
                        }
                    }
                    if let message = model.message {
                        NoticeView(systemImage: "info.circle", text: message) {
                            Button("OK") { model.message = nil }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, model.frameDataRedacted || model.message != nil ? 8 : 0)
                .padding(.bottom, model.frameDataRedacted || model.message != nil ? 4 : 0)
            }
        }
        .legacyTransparentToolbar()
        .navigationSubtitle(model.activeProcess.map { tr("Wykryto: \($0)", "Detected: \($0)") }
                            ?? tr("Nie wykryto gry", "No game detected"))
        .modifier(MainToolbar())
        .sheet(isPresented: $model.showingSettings) { SettingsView().id(model.language) }
        .sheet(isPresented: $model.showingUnlockPrompt) { UnlockPromptView() }
        .sheet(item: $model.renaming) { RenameView(capture: $0) }
        .confirmationDialog(tr("Usunąć zaznaczone wyniki (\(pendingDeletion.count))?", "Delete the selected results (\(pendingDeletion.count))?"),
                            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })) {
            Button(tr("Usuń", "Delete"), role: .destructive) {
                model.delete(pendingDeletion)
                pendingDeletion = []
            }
        } message: {
            Text(tr("Tej operacji nie można cofnąć.", "This cannot be undone."))
        }
    }

    /// One capture goes at once, as before; several ask first.
    private func requestDeletion(_ ids: Set<Capture.ID>) {
        if ids.count == 1 { model.delete(ids) } else if ids.count > 1 { pendingDeletion = ids }
    }
}

/// A notice under the toolbar: an icon, a message and an optional action.
private struct NoticeView<Action: View>: View {
    let systemImage: String
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 10) {
            Label(text, systemImage: systemImage)
            Spacer(minLength: 0)
            action()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .noticeBackground()
    }
}

private extension View {
    /// Glass on macOS 26 and later, a plain rounded card before.
    @ViewBuilder func noticeBackground() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            background(.quaternary, in: .rect(cornerRadius: 12))
        }
    }

    /// Before Liquid Glass an opaque toolbar overhangs the sidebar edge by a few points, so it stays
    /// transparent there; macOS 26 draws its own glass toolbar with a scroll edge effect.
    @ViewBuilder func legacyTransparentToolbar() -> some View {
        if #available(macOS 26, *) {
            self
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

/// Metal HUD switch, launch and record buttons, settings. On macOS 26 and later each part gets its own
/// glass capsule; a spacer only takes effect in an availability-checked toolbar of its own.
private struct MainToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.toolbar {
                // Its own capsule with room around the label, instead of the shared one.
                ToolbarItem(placement: .primaryAction) {
                    HUDSwitch()
                        .padding(.horizontal, 6)
                        .frame(height: 36)
                        .glassEffect(.regular, in: .capsule)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) { CaptureButtons() }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    SettingsButton()
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .primaryAction) { HUDSwitch() }
                ToolbarItemGroup(placement: .primaryAction) {
                    CaptureButtons()
                    SettingsButton()
                }
            }
        }
    }
}

private struct HUDSwitch: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Metal HUD")
            Toggle("Metal HUD", isOn: Binding(get: { model.hudEnabled }, set: model.setHUDEnabled))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .help(tr("Włącza Metal HUD i logowanie klatek dla aplikacji uruchomionych od tej chwili",
                 "Turns on Metal HUD and frame logging for apps launched from now on"))
    }
}

private struct CaptureButtons: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
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
    }
}

private struct SettingsButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button(tr("Ustawienia", "Settings"), systemImage: "gearshape") { model.showingSettings = true }
            .help(tr("Ustawienia", "Settings"))
    }
}
