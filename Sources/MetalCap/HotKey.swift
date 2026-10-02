import AppKit
import Carbon.HIToolbox
import SwiftUI

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, limited to ⌃⌥⇧⌘.
    var modifiers: UInt
    var keyName: String

    static let `default` = KeyCombo(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
        keyName: "R")

    private static let specialKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]

    init(keyCode: UInt32, modifiers: UInt, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command]).rawValue
        keyName = Self.specialKeys[Int(event.keyCode)]
            ?? event.charactersIgnoringModifiers?.uppercased()
            ?? "#\(event.keyCode)"
    }

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var result = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }

    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyName
    }
}

/// A system-wide hot key registered through Carbon, which needs no Accessibility permission.
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onPress?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// - Returns: false if the system refused the combination (e.g. already taken).
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x4D43_4150), id: 1)  // 'MCAP'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}

/// A button that records the next key press as the new shortcut. Esc cancels.
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo
    @ViewState private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? combo.display : "Naciśnij skrót…") {
            monitor == nil ? begin() : end()
        }
        .onDisappear(perform: end)
    }

    private func begin() {
        // The current shortcut would otherwise be swallowed before reaching the monitor.
        GlobalHotKey.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode != UInt16(kVK_Escape) { combo = KeyCombo(event: event) }
            end()
            return nil
        }
    }

    private func end() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        GlobalHotKey.shared.register(combo)
    }
}
