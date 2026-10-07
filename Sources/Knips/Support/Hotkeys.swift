import AppKit
import Carbon

struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon-Modifier (cmdKey, shiftKey, optionKey, controlKey).
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        // Ohne ⌘/⌥/⌃ wäre die Taste beim normalen Tippen belegt.
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        return f
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    /// Zeichen für NSMenuItem.keyEquivalent (nur Anzeige im Menü).
    var menuKeyEquivalent: String { KeyCombo.keyName(keyCode).lowercased() }

    private static let specialKeys: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Leertaste",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_Escape): "⎋", UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
    ]

    static func keyName(_ keyCode: UInt32) -> String {
        if let name = specialKeys[keyCode] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "#\(keyCode)" }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return "#\(keyCode)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case captureArea, captureWindow, captureFullscreen, toggleRecording, pinClipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: "Bereich aufnehmen"
        case .captureWindow: "Fenster aufnehmen"
        case .captureFullscreen: "Ganzen Bildschirm aufnehmen"
        case .toggleRecording: "Bildschirmaufnahme starten/stoppen"
        case .pinClipboard: "Bild aus Zwischenablage anpinnen"
        }
    }

    /// ⌥⇧ statt ⌘⇧: ⌘⇧3/4/5 gehören dem System.
    var defaultCombo: KeyCombo? {
        let mods = UInt32(optionKey | shiftKey)
        switch self {
        case .captureArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: mods)
        case .captureWindow: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: mods)
        case .captureFullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: mods)
        case .toggleRecording: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: mods)
        case .pinClipboard: return nil
        }
    }
}

/// Globale Kürzel über Carbon `RegisterEventHotKey` — braucht keine Bedienungshilfen-Freigabe.
@MainActor final class HotkeyManager {
    static let shared = HotkeyManager()

    var onAction: ((HotkeyAction) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotkeyAction] = [:]
    private var handlerInstalled = false
    private(set) var failures: [HotkeyAction] = []
    private static let signature: OSType = 0x4B4E_5053 // "KNPS"

    func apply(_ combos: [HotkeyAction: KeyCombo]) {
        unregisterAll()
        installHandlerIfNeeded()
        failures = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let combo = combos[action] else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = action
            } else {
                failures.append(action)
                Log.info("RegisterEventHotKey fehlgeschlagen für \(action.rawValue): \(status)")
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        guard let action = actions[id] else { return }
        onAction?(action)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr else { return err }
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyManager.shared.fire(id: id) } }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
    }
}

/// Erkennt, ob ein Kürzel mit den macOS-Bildschirmfoto-Kürzeln kollidiert.
enum SystemShortcuts {
    private static let screenshotIDs: [Int: String] = [
        28: "Bildschirm als Datei sichern", 29: "Bildschirm in Zwischenablage",
        30: "Auswahl als Datei sichern", 31: "Auswahl in Zwischenablage", 184: "Bildschirmfoto-Optionen",
    ]

    /// Standardbelegung, falls der Eintrag fehlt: (keyCode, Cocoa-Modifier-Rohwert).
    private static let defaults: [Int: (Int, Int)] = [
        28: (20, 0x120000), 29: (20, 0x160000), 30: (21, 0x120000), 31: (21, 0x160000), 184: (23, 0x120000),
    ]

    static func conflict(for combo: KeyCombo) -> String? {
        let dict = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        for (id, name) in screenshotIDs {
            var enabled = true
            var keyCode: Int?
            var mods: Int?
            if let entry = dict[String(id)] as? [String: Any] {
                enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1)
                if let value = entry["value"] as? [String: Any], let params = value["parameters"] as? [Int], params.count >= 3 {
                    keyCode = params[1]
                    mods = params[2]
                }
            }
            if keyCode == nil, let d = defaults[id] { keyCode = d.0; mods = d.1 }
            guard enabled, let keyCode, let mods else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(mods)).intersection([.command, .shift, .option, .control])
            if UInt32(keyCode) == combo.keyCode && flags == combo.cocoaModifiers { return name }
        }
        return nil
    }
}
