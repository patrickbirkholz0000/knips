import AppKit
import Carbon
import Combine
import OSLog
import ServiceManagement

enum Log {
    private static let logger = Logger(subsystem: "de.birkgroup.knips", category: "app")
    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}

enum RedactStyle: String, Codable, CaseIterable, Identifiable {
    case pixelate, blur, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pixelate: "Verpixeln"
        case .blur: "Unschärfe"
        case .solid: "Balken"
        }
    }
    var symbol: String {
        switch self {
        case .pixelate: "square.grid.3x3.fill"
        case .blur: "drop.fill"
        case .solid: "rectangle.fill"
        }
    }
}

@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var saveFolderPath: String { didSet { d.set(saveFolderPath, forKey: "saveFolder") } }
    @Published var copyToClipboard: Bool { didSet { d.set(copyToClipboard, forKey: "copyToClipboard") } }
    @Published var showQuickAccess: Bool { didSet { d.set(showQuickAccess, forKey: "showQuickAccess") } }
    /// 0 = nie automatisch ausblenden.
    @Published var quickAccessAutoClose: Int { didSet { d.set(quickAccessAutoClose, forKey: "quickAccessAutoClose") } }
    @Published var openEditorAfterCapture: Bool { didSet { d.set(openEditorAfterCapture, forKey: "openEditorAfterCapture") } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: "playSound") } }
    @Published var recordingFPS: Int { didSet { d.set(recordingFPS, forKey: "recordingFPS") } }
    @Published var recordingShowCursor: Bool { didSet { d.set(recordingShowCursor, forKey: "recordingShowCursor") } }
    @Published var recordingCountdown: Bool { didSet { d.set(recordingCountdown, forKey: "recordingCountdown") } }
    @Published var recordingMicrophone: Bool { didSet { d.set(recordingMicrophone, forKey: "recordingMicrophone") } }
    @Published var gifFPS: Int { didSet { d.set(gifFPS, forKey: "gifFPS") } }
    @Published var gifWidth: Int { didSet { d.set(gifWidth, forKey: "gifWidth") } }
    @Published var redactStyle: RedactStyle { didSet { d.set(redactStyle.rawValue, forKey: "redactStyle") } }
    /// Auto-Zensur-Knopf in den Editoren anbieten (standardmäßig aus — Zensur wird von Hand gezogen).
    @Published var showAutoRedact: Bool { didSet { d.set(showAutoRedact, forKey: "showAutoRedact") } }
    /// Welche Datenarten die Auto-Zensur sucht.
    @Published var autoRedactKinds: Set<SensitiveDetector.Kind> {
        didSet { d.set(autoRedactKinds.map(\.rawValue).sorted(), forKey: "autoRedactKinds") }
    }
    /// Tage, die Originale + Bearbeitungsstand behalten werden (0 = unbegrenzt).
    @Published var retentionDays: Int { didSet { d.set(retentionDays, forKey: "retentionDays") } }
    /// Abgehakte Kürzel bleiben gespeichert, werden aber nicht registriert (wie die Häkchen in macOS).
    @Published var disabledHotkeys: Set<HotkeyAction> {
        didSet { d.set(disabledHotkeys.map(\.rawValue).sorted(), forKey: "disabledHotkeys") }
    }
    @Published var hotkeys: [HotkeyAction: KeyCombo] {
        didSet {
            if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })) {
                d.set(data, forKey: "hotkeys")
            }
        }
    }

    private init() {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        saveFolderPath = d.string(forKey: "saveFolder") ?? pictures.appendingPathComponent("Knips").path
        copyToClipboard = d.object(forKey: "copyToClipboard") as? Bool ?? true
        showQuickAccess = d.object(forKey: "showQuickAccess") as? Bool ?? true
        quickAccessAutoClose = d.object(forKey: "quickAccessAutoClose") as? Int ?? 0
        openEditorAfterCapture = d.object(forKey: "openEditorAfterCapture") as? Bool ?? false
        playSound = d.object(forKey: "playSound") as? Bool ?? true
        recordingFPS = d.object(forKey: "recordingFPS") as? Int ?? 30
        recordingShowCursor = d.object(forKey: "recordingShowCursor") as? Bool ?? true
        recordingCountdown = d.object(forKey: "recordingCountdown") as? Bool ?? true
        recordingMicrophone = d.object(forKey: "recordingMicrophone") as? Bool ?? false
        gifFPS = d.object(forKey: "gifFPS") as? Int ?? 15
        gifWidth = d.object(forKey: "gifWidth") as? Int ?? 960
        redactStyle = RedactStyle(rawValue: d.string(forKey: "redactStyle") ?? "") ?? .solid
        showAutoRedact = d.object(forKey: "showAutoRedact") as? Bool ?? false
        if let raw = d.stringArray(forKey: "autoRedactKinds") {
            autoRedactKinds = Set(raw.compactMap(SensitiveDetector.Kind.init(rawValue:)))
        } else {
            autoRedactKinds = Set(SensitiveDetector.Kind.allCases)
        }
        retentionDays = d.object(forKey: "retentionDays") as? Int ?? 30
        var keys: [HotkeyAction: KeyCombo] = [:]
        if let data = d.data(forKey: "hotkeys"),
           let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (raw, combo) in stored { if let a = HotkeyAction(rawValue: raw) { keys[a] = combo } }
        } else {
            for a in HotkeyAction.allCases { if let c = a.defaultCombo { keys[a] = c } }
        }
        hotkeys = keys
        disabledHotkeys = Set((d.stringArray(forKey: "disabledHotkeys") ?? []).compactMap(HotkeyAction.init(rawValue:)))
        migrate()
    }

    /// v2 (08.10.2026): Kürzel wie macOS (⌘⇧ statt ⌥⇧), Zensur standardmäßig als Balken,
    /// Editor startet mit dem Zensur-Werkzeug.
    private func migrate() {
        guard d.integer(forKey: "settingsVersion") < 2 else { return }
        let old = UInt32(optionKey | shiftKey)
        var keys = hotkeys
        for action in HotkeyAction.allCases {
            if let combo = keys[action], combo.modifiers == old, let new = action.defaultCombo { keys[action] = new }
        }
        hotkeys = keys
        redactStyle = .solid
        d.removeObject(forKey: "editorTool")
        d.set(2, forKey: "settingsVersion")
    }

    /// Tatsächlich registrierte Kürzel.
    var activeHotkeys: [HotkeyAction: KeyCombo] { hotkeys.filter { !disabledHotkeys.contains($0.key) } }

    static var defaultHotkeys: [HotkeyAction: KeyCombo] {
        var keys: [HotkeyAction: KeyCombo] = [:]
        for a in HotkeyAction.allCases { if let c = a.defaultCombo { keys[a] = c } }
        return keys
    }

    var saveFolder: URL {
        if let root = Paths.testRoot { return root.appendingPathComponent("ablage", isDirectory: true) }
        return URL(fileURLWithPath: saveFolderPath, isDirectory: true)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.error("Autostart umschalten fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }
}
