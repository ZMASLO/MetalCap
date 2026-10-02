import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)

        // `--snapshot <png> [--size WxH]` renders the main window to a file and quits (for UI checks).
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let size = arguments.firstIndex(of: "--size")
                .flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1].split(separator: "x").compactMap { Double($0) } : nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let window = NSApp.windows.first(where: { $0.title == "MetalCap" }) else { exit(1) }
                if let size, size.count == 2 { window.setContentSize(NSSize(width: size[0], height: size[1])) }
                // An inactive window renders its toolbar and selection differently.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let view = window.contentView?.superview,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: arguments[index + 1]))
                    exit(0)
                }
            }
        }
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
