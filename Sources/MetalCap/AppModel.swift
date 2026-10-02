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
    @Published var settingsTab = 0
    /// The capture whose name is being edited.
    @Published var renaming: Capture?
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
    /// Overlay appearance; applies to games launched after a change.
    @Published var hudConfiguration: HUDConfiguration {
        didSet {
            guard hudConfiguration != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(hudConfiguration), forKey: "hudConfiguration")
            // Sliders change the value continuously; write the environment once they settle.
            pendingHUDApply?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hudEnabled else { return }
                try? HUDEnvironment.apply(self.hudConfiguration)
            }
            pendingHUDApply = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }
    private var pendingHUDApply: DispatchWorkItem?
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
    private let sampler = SystemSampler()
    private let hardware = HardwareInfo.current()
    private var samplingTimer: Timer?
    /// Power conditions when the current capture started.
    private var startedOnBattery: Bool?
    private var startedInLowPowerMode = false
    private let logSource = LogStreamSource()
    private var launched: [Int32: LaunchedProcessSource] = [:]
    private var lastEventAt = Date.distantPast

    private init() {
        hotKey = UserDefaults.standard.data(forKey: "hotKey")
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .default
        hudConfiguration = UserDefaults.standard.data(forKey: "hudConfiguration")
            .flatMap { try? JSONDecoder().decode(HUDConfiguration.self, from: $0) } ?? HUDConfiguration()
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
            try HUDEnvironment.setEnabled(enabled, configuration: hudConfiguration)
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

        let source = LaunchedProcessSource(url: url, configuration: hudConfiguration)
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
            startedOnBattery = SystemSampler.isOnBattery
            startedInLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.recorder.ingest(self.sampler.read(pids: self.recorder.candidatePIDs))
                }
            }
            timer.fire()
            samplingTimer = timer
            Sounds.start()
            isRecording = true
            message = nil
        }
    }

    private func finishCapture() {
        isFinishing = false
        samplingTimer?.invalidate()
        samplingTimer = nil
        guard var capture = recorder.finish() else {
            Sounds.failure()
            message = frameDataRedacted
                ? tr("Brak klatek: macOS ukrywa czasy klatek tej gry w logu systemowym.",
                     "No frames: macOS hides this game's frame times in the system log.")
                : tr("Brak klatek: żadna gra nie logowała w tym czasie. Sprawdź, czy Metal HUD jest włączony i widoczny.",
                     "No frames: no game was logging during the capture. Check that Metal HUD is on and visible.")
            return
        }
        capture.name = nameAliases[capture.processName]
        capture.hardware = hardware
        capture.onBattery = startedOnBattery
        capture.lowPowerMode = startedInLowPowerMode
        do {
            try store.save(capture)
        } catch {
            message = tr("Nie udało się zapisać przechwycenia: ", "Could not save the capture: ")
                + error.localizedDescription
        }
        captures.insert(capture, at: 0)
        selection = capture.id
    }

    /// Names the user asked to reuse for every capture of a process, keyed by process name.
    private var nameAliases: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "nameAliases") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "nameAliases") }
    }

    /// - Parameter wholeProcess: also rename the other captures of the same process and
    ///   use the name for its future captures.
    func rename(_ id: Capture.ID, to name: String, wholeProcess: Bool) {
        guard let capture = captures.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty || trimmed == capture.processName ? nil : trimmed
        if wholeProcess { nameAliases[capture.processName] = newName }

        for index in captures.indices
        where captures[index].id == id || (wholeProcess && captures[index].processName == capture.processName) {
            guard captures[index].name != newName else { continue }
            captures[index].name = newName
            do {
                try store.save(captures[index])
            } catch {
                message = tr("Nie udało się zapisać nazwy: ", "Could not save the name: ") + error.localizedDescription
            }
        }
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

    // MARK: Export

    enum ExportKind {
        case json, framesCSV, systemCSV, summaryCSV
    }

    /// Asks where to save and writes the export. The summary covers every capture; the others, `capture`.
    func export(_ kind: ExportKind, capture: Capture) {
        let dialect = CSVDialect(rawValue: UserDefaults.standard.string(forKey: "csvDialect") ?? "") ?? .standard
        let stamp = capture.startedAt.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let base = "\(capture.displayName) \(stamp)".replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileName: String
        let contents: Data
        do {
            switch kind {
            case .json:
                (fileName, contents) = ("\(base).json", try CaptureExporter.json(capture))
            case .framesCSV:
                (fileName, contents) = ("\(base) \(tr("klatki", "frames")).csv",
                                        Data(CaptureExporter.framesCSV(capture, dialect: dialect).utf8))
            case .systemCSV:
                (fileName, contents) = ("\(base) system.csv",
                                        Data(CaptureExporter.systemCSV(capture, dialect: dialect).utf8))
            case .summaryCSV:
                (fileName, contents) = ("MetalCap \(tr("podsumowanie", "summary")).csv",
                                        Data(CaptureExporter.summaryCSV(captures, dialect: dialect).utf8))
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = fileName
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try contents.write(to: url, options: .atomic)
        } catch {
            message = tr("Nie udało się wyeksportować: ", "Could not export: ") + error.localizedDescription
        }
    }

    func delete(_ id: Capture.ID) {
        try? store.delete(id)
        captures.removeAll { $0.id == id }
        if selection == id { selection = captures.first?.id }
    }
}
