import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

struct MetalCapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("MetalCap", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }

        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "speedometer")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var status: String {
        if model.isRecording { return "Nagrywanie…" }
        if model.isFinishing { return "Zapisywanie…" }
        if let process = model.activeProcess { return "Wykryto: \(process)" }
        return "Nie wykryto gry z Metal HUD"
    }

    var body: some View {
        Text(status)
        Button("\(model.isRecording ? "Zatrzymaj" : "Rozpocznij") przechwytywanie (\(model.hotKey.display))") {
            model.toggleCapture()
        }
        .disabled(model.isFinishing)
        Divider()
        Toggle("Metal HUD (globalnie)", isOn: Binding(get: { model.hudEnabled }, set: model.setHUDEnabled))
        Button("Uruchom grę przez MetalCap…") { model.launchGame() }
        Divider()
        Button("Pokaż przechwycenia") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Zakończ MetalCap") { NSApp.terminate(nil) }
    }
}
