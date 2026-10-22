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

    /// Was gedrückt wurde. Jede Taste taugt als Kürzel, auch allein (↖, „A“, ⇧A) — Carbon registriert sie mit
    /// Modifiern 0 genauso; macOS gibt den Tastendruck dann nicht an die App im Vordergrund weiter.
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    /// Taste, die beim Tippen oder Navigieren gebraucht wird (Buchstaben, Ziffern, Zeichen, Leertaste, ↩, ⇥, ↖, ↘,
    /// ⇞, ⇟, Pfeile, ⌦, Ziffernblock), ohne ⌘/⌥/⌃ — als Kürzel fehlt sie dann in allen anderen Apps. Die
    /// Einstellungen sagen das dazu.
    var isTypingKey: Bool {
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) == 0 else { return false }
        switch Int(keyCode) {
        case 0x00...0x32,                                        // Buchstaben, Ziffern, Zeichen, ↩, ⇥, Leertaste
             0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51,     // Ziffernblock: , * + Clear / Enter - =
             0x52...0x59, 0x5B, 0x5C,                            // Ziffernblock 0–9
             0x5D...0x5F,                                        // JIS: ¥ _ Komma
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
             kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow:
            return true
        default:
            return false
        }
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
    case captureArea, captureWindow, captureFullscreen, captureLastArea, captureText, captureScrolling, toggleRecording, pinClipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: "Bereich aufnehmen"
        case .captureWindow: "Fenster aufnehmen"
        case .captureFullscreen: "Ganzen Bildschirm aufnehmen"
        case .captureLastArea: "Letzten Bereich wiederholen"
        case .captureText: "Text aus Bereich erfassen"
        case .captureScrolling: "Scroll-Screenshot"
        case .toggleRecording: "Bildschirmaufnahme starten/stoppen"
        case .pinClipboard: "Bild aus Zwischenablage anpinnen"
        }
    }

    /// Wie macOS: ⇧⌘3 Bildschirm, ⇧⌘4 Bereich, ⇧⌘5 Aufnahme. Die gleichnamigen macOS-Kürzel
    /// schaltet Knips auf Nachfrage ab (`SystemShortcuts.takeOver`).
    var defaultCombo: KeyCombo? {
        let mods = UInt32(cmdKey | shiftKey)
        switch self {
        case .captureArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: mods)
        case .captureWindow: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: mods)
        case .captureFullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: mods)
        case .toggleRecording: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: mods)
        case .pinClipboard, .captureLastArea, .captureText, .captureScrolling: return nil
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
            DispatchQueue.main.async { onMainActor { HotkeyManager.shared.fire(id: id) } }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
    }
}

/// Erkennt und löst Konflikte mit den macOS-Bildschirmfoto-Kürzeln.
enum SystemShortcuts {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    /// Zeichen, Tastencode, Modifier je Eintrag (macOS-Standard).
    private static let defaultParams: [Int: [Int]] = [
        28: [51, 20, 0x120000], 29: [51, 20, 0x160000], 30: [52, 21, 0x120000], 31: [52, 21, 0x160000], 184: [53, 23, 0x120000],
    ]

    /// macOS-Einträge, die eines der Kürzel selbst belegen.
    static func conflictingIDs(for combos: [KeyCombo]) -> [Int] {
        screenshotIDs.keys.sorted().filter { id in combos.contains { conflictID(for: $0) == id } }
    }

    /// Schaltet die kollidierenden macOS-Kürzel ab und lädt die Tastaturbelegung sofort neu.
    @discardableResult
    static func takeOver(_ ids: [Int]) -> Bool {
        guard !ids.isEmpty else { return true }
        var dict = (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
        for id in ids {
            var entry = dict[String(id)] as? [String: Any] ?? [:]
            if entry["value"] == nil, let p = defaultParams[id] {
                entry["value"] = ["type": "standard", "parameters": p] as [String: Any]
            }
            entry["enabled"] = false
            dict[String(id)] = entry
        }
        CFPreferencesSetAppValue(key, dict as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else { return false }
        var taken = Set(UserDefaults.knips.array(forKey: "takenSystemShortcuts") as? [Int] ?? [])
        taken.formUnion(ids)
        UserDefaults.knips.set(Array(taken).sorted(), forKey: "takenSystemShortcuts")
        reloadSystemHotkeys()
        return true
    }

    /// Gibt die von Knips abgeschalteten macOS-Kürzel zurück.
    static func restore() {
        let taken = UserDefaults.knips.array(forKey: "takenSystemShortcuts") as? [Int] ?? []
        guard !taken.isEmpty, var dict = CFPreferencesCopyAppValue(key, domain) as? [String: Any] else { return }
        for id in taken {
            guard var entry = dict[String(id)] as? [String: Any] else { continue }
            entry["enabled"] = true
            dict[String(id)] = entry
        }
        CFPreferencesSetAppValue(key, dict as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        UserDefaults.knips.removeObject(forKey: "takenSystemShortcuts")
        reloadSystemHotkeys()
    }

    /// Eingeschaltete macOS-Kürzel ⇧⌘3 / ⇧⌘4 / ⇧⌘5. Solange sie aktiv sind, fängt macOS die Tasten ab —
    /// auch beim Festlegen in den Knips-Einstellungen.
    static func enabledScreenshotIDs() -> [Int] {
        let dict = (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
        return [28, 30, 184].filter { id in
            guard let entry = dict[String(id)] as? [String: Any] else { return true }
            return (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1)
        }
    }

    static var hasTakenOver: Bool { !(UserDefaults.knips.array(forKey: "takenSystemShortcuts") as? [Int] ?? []).isEmpty }

    private static func reloadSystemHotkeys() {
        let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-u"]
        try? p.run()
    }

    static func displayList(_ ids: [Int]) -> String {
        ids.compactMap { id -> String? in
            guard let p = defaultParams[id] else { return nil }
            return KeyCombo(keyCode: UInt32(p[1]), modifiers: p[2] & 0x40000 != 0 ? UInt32(cmdKey | shiftKey | controlKey) : UInt32(cmdKey | shiftKey)).display
        }.joined(separator: ", ")
    }

    private static func conflictID(for combo: KeyCombo) -> Int? {
        let dict = (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
        for (id, _) in screenshotIDs {
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
            if keyCode == nil, let p = defaultParams[id] { keyCode = p[1]; mods = p[2] }
            guard enabled, let keyCode, let mods else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(mods)).intersection([.command, .shift, .option, .control])
            if UInt32(keyCode) == combo.keyCode && flags == combo.cocoaModifiers { return id }
        }
        return nil
    }

    private static let screenshotIDs: [Int: String] = [
        28: "Bildschirm als Datei sichern", 29: "Bildschirm in Zwischenablage",
        30: "Auswahl als Datei sichern", 31: "Auswahl in Zwischenablage", 184: "Bildschirmfoto-Optionen",
    ]

    static func conflict(for combo: KeyCombo) -> String? {
        conflictID(for: combo).flatMap { screenshotIDs[$0] }
    }
}
