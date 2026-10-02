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
    /// Frame data has been un-redacted in the unified log (see `LogPrivacy`).
    @Published private(set) var logUnlocked = AppModel.readLogUnlocked()
    @Published var showingUnlockPrompt = false
    @Published var showingSettings = false
    @Published var message: String?
    @Published private(set) var language = L10n.language
    @Published var hotKey: KeyCombo {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey")
            registerHotKey()
        }
    }
    /// "auto", "pl" or "en".
    @Published var languagePreference = L10n.preference {
        didSet {
            let defaults = UserDefaults.standard
            defaults.set(languagePreference, forKey: L10n.preferenceKey)
            L10n.language = Language.resolve(preference: languagePreference,
                                             preferredLanguages: Language.systemLanguages)
            language = L10n.language
            // System-provided menus and panels follow this on the next launch.
            if Language(rawValue: languagePreference) != nil {
                defaults.set([languagePreference], forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }
    @Published var skipUnlockPrompt = UserDefaults.standard.bool(forKey: "skipUnlockPrompt") {
        didSet { UserDefaults.standard.set(skipUnlockPrompt, forKey: "skipUnlockPrompt") }
    }

    /// Set once unredacted frames have actually arrived through the log, whatever installed the configuration.
    private static let unlockVerifiedKey = "logUnlockVerified"

    private static func readLogUnlocked() -> Bool {
        LogPrivacy.isUnlocked() || UserDefaults.standard.bool(forKey: unlockVerifiedKey)
    }

    /// How long after "stop" to wait for the HUD line covering the last frames.
    private static let finishDelay: TimeInterval = 2

    /// `METALCAP_CAPTURES_DIR` points the app at another capture folder (used for UI checks with sample data).
    private let store = CaptureStore(directory: ProcessInfo.processInfo.environment["METALCAP_CAPTURES_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) })
    private let recorder = CaptureRecorder()
    private let logSource = LogStreamSource()
    private var launched: [Int32: LaunchedProcessSource] = [:]
    private var lastEventAt = Date.distantPast

    private init() {
        hotKey = UserDefaults.standard.data(forKey: "hotKey")
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .default
        captures = store.loadAll()
        selection = captures.first?.id
        showingUnlockPrompt = !logUnlocked && !skipUnlockPrompt

        GlobalHotKey.shared.onPress = { [weak self] in
            Task { @MainActor in self?.toggleCapture() }
        }
        registerHotKey()

        logSource.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event, fromLog: true) }
        }
        do { try logSource.start() } catch {
            message = tr("Nie udało się uruchomić odczytu logu: ", "Could not start reading the log: ")
                + error.localizedDescription
        }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Picks up a profile installed or removed in System Settings.
                let unlocked = Self.readLogUnlocked()
                if self.logUnlocked != unlocked { self.logUnlocked = unlocked }
                guard self.activeProcess != nil, Date().timeIntervalSince(self.lastEventAt) > 3 else { return }
                self.activeProcess = nil
                self.frameDataRedacted = false
            }
        }
    }

    func shutdown() {
        logSource.stop()
    }

    private func registerHotKey() {
        if !GlobalHotKey.shared.register(hotKey) {
            message = tr("Skrót \(hotKey.display) jest zajęty — wybierz inny w ustawieniach.",
                         "The shortcut \(hotKey.display) is taken — choose another one in settings.")
        }
    }

    // MARK: Metal HUD

    func setHUDEnabled(_ enabled: Bool) {
        do {
            try HUDEnvironment.setEnabled(enabled)
            message = enabled
                ? tr("Metal HUD włączony. Uruchom ponownie grę oraz Steam/CrossOver, żeby zadziałał.",
                     "Metal HUD is on. Restart the game and Steam/CrossOver for it to take effect.")
                : nil
        } catch {
            message = tr("Nie udało się zmienić ustawienia Metal HUD: ", "Could not change the Metal HUD setting: ")
                + error.localizedDescription
        }
        hudEnabled = HUDEnvironment.isEnabled
    }

    /// Hands the logging profile to macOS and opens the System Settings pane where the user installs it.
    func installUnlockProfile() {
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetalCap-FrameTimes.mobileconfig")
        let profile = LogPrivacy.profileData(
            displayName: tr("MetalCap – czasy klatek", "MetalCap – frame times"),
            description: tr("Odsłania czasy klatek Metal HUD w logu systemowym, żeby MetalCap mógł mierzyć każdą grę.",
                            "Reveals Metal HUD frame times in the system log so MetalCap can measure any game."))
        do {
            try profile.write(to: url, options: .atomic)
        } catch {
            message = tr("Nie udało się zapisać profilu: ", "Could not save the profile: ") + error.localizedDescription
            return
        }
        NSWorkspace.shared.open(url)
        openProfileSettings()
        message = tr("Profil czeka w Ustawieniach systemowych: Ogólne → Zarządzanie urządzeniem. Po instalacji uruchom ponownie grę.",
                     "The profile is waiting in System Settings: General → Device Management. After installing it, restart the game.")
    }

    /// Opens the System Settings pane that lists configuration profiles, where the profile can be removed.
    func openProfileSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Lets the user pick a game and starts it with the HUD on, reading frame data from its stderr.
    func launchGame() {
        let panel = NSOpenPanel()
        panel.title = tr("Wybierz grę", "Choose a game")
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
            message = tr("Nie udało się uruchomić \(url.lastPathComponent): ",
                         "Could not launch \(url.lastPathComponent): ") + error.localizedDescription
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
            if frameDataRedacted != event.sample.isRedacted { frameDataRedacted = event.sample.isRedacted }
            // Frames arriving through the log are the proof that unlocking works; redacted lines disprove it.
            if event.sample.isRedacted || !event.sample.frames.isEmpty {
                let verified = !event.sample.isRedacted
                if UserDefaults.standard.bool(forKey: Self.unlockVerifiedKey) != verified {
                    UserDefaults.standard.set(verified, forKey: Self.unlockVerifiedKey)
                }
            }
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
                ? tr("Brak klatek: macOS ukrywa czasy klatek tej gry w logu systemowym.",
                     "No frames: macOS hides this game's frame times in the system log.")
                : tr("Brak klatek: żadna gra nie logowała w tym czasie. Sprawdź, czy Metal HUD jest włączony i widoczny.",
                     "No frames: no game was logging during the capture. Check that Metal HUD is on and visible.")
            return
        }
        do {
            try store.save(capture)
        } catch {
            message = tr("Nie udało się zapisać przechwycenia: ", "Could not save the capture: ")
                + error.localizedDescription
        }
        captures.insert(capture, at: 0)
        selection = capture.id
    }

    func setComment(_ comment: String, for id: Capture.ID) {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = trimmed.isEmpty ? nil : trimmed
        guard captures[index].comment != newValue else { return }
        captures[index].comment = newValue
        do {
            try store.save(captures[index])
        } catch {
            message = tr("Nie udało się zapisać komentarza: ", "Could not save the comment: ")
                + error.localizedDescription
        }
    }

    func delete(_ id: Capture.ID) {
        try? store.delete(id)
        captures.removeAll { $0.id == id }
        if selection == id { selection = captures.first?.id }
    }
}
