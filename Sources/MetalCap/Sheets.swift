import MetalCapCore
import SwiftUI

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
