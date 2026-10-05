import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)

        // `--snapshot <png> [--size WxH] [--show settings|overlay|unlock|rename|system] [--lang pl|en] [--scroll N] [--pointer seconds]` renders the main
        // window, or the requested sheet, to a file and quits (for UI checks).
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let sheet = arguments.firstIndex(of: "--show").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            // `--show system` renders just the System section, which sits below the fold in the window.
            if sheet == "system" {
                guard let capture = AppModel.shared.captures.first(where: { $0.system != nil }),
                      let samples = capture.system, let metrics = capture.metrics else { exit(1) }
                let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 20) {
                    SystemSectionView(samples: samples, averageFPS: metrics.average)
                    CaptureTimeline(frameTimes: capture.frameTimes, samples: samples, duration: metrics.duration,
                                    coreTiers: capture.hardware?.coreTiers.map(\.name) ?? [],
                                    pointerAt: arguments.firstIndex(of: "--pointer")
                                        .flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil })
                }
                .padding(20).frame(width: 900).background(Color(nsColor: .windowBackgroundColor)))
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
                try? png.write(to: URL(fileURLWithPath: arguments[index + 1]))
                exit(0)
            }
            AppModel.shared.showingUnlockPrompt = sheet == "unlock"
            AppModel.shared.showingSettings = sheet == "settings" || sheet == "overlay"
            AppModel.shared.settingsTab = sheet == "overlay" ? 1 : 0
            if sheet == "rename" { AppModel.shared.renaming = AppModel.shared.captures.first }
            let size = arguments.firstIndex(of: "--size")
                .flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1].split(separator: "x").compactMap { Double($0) } : nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let window = NSApp.windows.first(where: { $0.title == "MetalCap" }) else { exit(1) }
                if let size, size.count == 2 { window.setContentSize(NSSize(width: size[0], height: size[1])) }
                // An inactive window renders its toolbar and selection differently.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                // `--scroll <points>` scrolls the tallest scroll view, to check what passes under the toolbar.
                if let scrollIndex = arguments.firstIndex(of: "--scroll"), scrollIndex + 1 < arguments.count,
                   let offset = Double(arguments[scrollIndex + 1]), let content = window.contentView {
                    func scrollViews(in view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
                    }
                    if let scrollView = scrollViews(in: content)
                        .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) {
                        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let view = (window.attachedSheet ?? window).contentView?.superview,
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
                .id(model.language)
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }

        MenuBarExtra {
            MenuContent().id(model.language).environmentObject(model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "speedometer")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var status: String {
        if model.isRecording { return tr("Nagrywanie…", "Recording…") }
        if model.isFinishing { return tr("Zapisywanie…", "Saving…") }
        if let process = model.activeProcess { return tr("Wykryto: \(process)", "Detected: \(process)") }
        return tr("Nie wykryto gry z Metal HUD", "No game with Metal HUD detected")
    }

    var body: some View {
        Text(status)
        Button((model.isRecording ? tr("Zatrzymaj przechwytywanie", "Stop capture") : tr("Rozpocznij przechwytywanie", "Start capture"))
               + " (\(model.hotKey.display))") {
            model.toggleCapture()
        }
        .disabled(model.isFinishing)
        Divider()
        Toggle(tr("Metal HUD (globalnie)", "Metal HUD (system-wide)"), isOn: Binding(get: { model.hudEnabled }, set: model.setHUDEnabled))
        Button(tr("Uruchom grę przez MetalCap…", "Launch game through MetalCap…")) { model.launchGame() }
        Divider()
        Button(tr("Pokaż przechwycenia", "Show captures")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(tr("Zakończ MetalCap", "Quit MetalCap")) { NSApp.terminate(nil) }
    }
}
