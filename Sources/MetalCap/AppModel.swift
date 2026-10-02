import AppKit
import MetalCapCore
import SwiftUI

enum Sounds {
    static func start() { NSSound(named: "Ping")?.play() }
    static func stop() { NSSound(named: "Glass")?.play() }
    static func failure() { NSSound(named: "Basso")?.play() }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var hudEnabled = HUDEnvironment.isEnabled
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var captures: [Capture] = []
    @Published var selection: Capture.ID?
    /// Process currently emitting HUD lines, if any.
    @Published private(set) var activeProcess: String?
    /// The unified log delivers HUD lines without frame data.
    @Published private(set) var frameDataRedacted = false
    @Published var message: String?
    @Published var hotKey: KeyCombo {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey")
            registerHotKey()
        }
    }

    /// How long after "stop" to wait for the HUD line covering the last frames.
    private static let finishDelay: TimeInterval = 2

    private let store = CaptureStore()
    private let recorder = CaptureRecorder()
    private let logSource = LogStreamSource()
    private var launched: [Int32: LaunchedProcessSource] = [:]
    private var lastEventAt = Date.distantPast

    private init() {
        hotKey = UserDefaults.standard.data(forKey: "hotKey")
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .default
        captures = store.loadAll()
        selection = captures.first?.id

        GlobalHotKey.shared.onPress = { [weak self] in
            Task { @MainActor in self?.toggleCapture() }
        }
        registerHotKey()

        logSource.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event, fromLog: true) }
        }
        do { try logSource.start() } catch {
            message = "Nie udało się uruchomić odczytu logu: \(error.localizedDescription)"
        }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeProcess != nil,
                      Date().timeIntervalSince(self.lastEventAt) > 3 else { return }
                self.activeProcess = nil
            }
        }
    }

    func shutdown() {
        logSource.stop()
    }

    private func registerHotKey() {
        if !GlobalHotKey.shared.register(hotKey) {
            message = "Skrót \(hotKey.display) jest zajęty — wybierz inny w ustawieniach."
        }
    }

    // MARK: Metal HUD

    func setHUDEnabled(_ enabled: Bool) {
        do {
            try HUDEnvironment.setEnabled(enabled)
            message = enabled
                ? "Metal HUD włączony. Uruchom ponownie grę oraz Steam/CrossOver, żeby zadziałał."
                : nil
        } catch {
            message = "Nie udało się zmienić ustawienia Metal HUD: \(error.localizedDescription)"
        }
        hudEnabled = HUDEnvironment.isEnabled
    }

    /// Lets the user pick a game and starts it with the HUD on, reading frame data from its stderr.
    func launchGame() {
        let panel = NSOpenPanel()
        panel.title = "Wybierz grę"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let source = LaunchedProcessSource(url: url)
        source.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event, fromLog: false) }
        }
        do {
            try source.start()
        } catch {
            message = "Nie udało się uruchomić \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        let pid = source.pid
        source.onExit = { [weak self] in
            Task { @MainActor in self?.launched[pid] = nil }
        }
        launched[pid] = source
    }

    // MARK: Capture

    private func handle(_ event: HUDEvent, fromLog: Bool) {
        if fromLog {
            // A game we launched is read from stderr; its log entries are duplicates.
            if launched[event.pid] != nil { return }
            frameDataRedacted = event.sample.isRedacted
        }
        lastEventAt = Date()
        if activeProcess != event.processName { activeProcess = event.processName }
        recorder.ingest(event)
    }

    func toggleCapture() {
        guard !isFinishing else { return }
        if isRecording {
            recorder.stop(at: Date())
            Sounds.stop()
            isRecording = false
            isFinishing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishDelay) { [weak self] in
                self?.finishCapture()
            }
        } else {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            recorder.start(at: Date(), preferredPID: frontmost)
            Sounds.start()
            isRecording = true
            message = nil
        }
    }

    private func finishCapture() {
        isFinishing = false
        guard let capture = recorder.finish() else {
            Sounds.failure()
            message = frameDataRedacted
                ? "Brak klatek: macOS ukrywa czasy klatek w logu systemowym. Uruchom grę przez „Uruchom grę przez MetalCap…”."
                : "Brak klatek: żadna gra nie logowała w tym czasie. Sprawdź, czy Metal HUD jest włączony i widoczny."
            return
        }
        do {
            try store.save(capture)
        } catch {
            message = "Nie udało się zapisać przechwycenia: \(error.localizedDescription)"
        }
        captures.insert(capture, at: 0)
        selection = capture.id
    }

    func delete(_ id: Capture.ID) {
        try? store.delete(id)
        captures.removeAll { $0.id == id }
        if selection == id { selection = captures.first?.id }
    }
}
