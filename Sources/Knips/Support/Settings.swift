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

extension UserDefaults {
    /// Domäne der Selbsttests und der Test-Sandbox.
    static let sandboxSuite = "de.birkgroup.knips.sandbox"

    /// Einstellungen und Merker von Knips. Selbsttests und die Test-Sandbox (`KNIPS_TEST_DIR`) schreiben in eine
    /// eigene Domäne — die echten Einstellungen (`de.birkgroup.knips`) bleiben dabei unberührt.
    static let knips: UserDefaults = Paths.testRoot == nil ? .standard : UserDefaults(suiteName: sandboxSuite) ?? .standard
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

/// Darstellung der Fenster (docs/design.md, „Hell und Dunkel“). Menü-Panel, Pillen und Seitenleiste bleiben immer dunkel.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }
    /// `nil` folgt macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.knips

    @Published var saveFolderPath: String { didSet { d.set(saveFolderPath, forKey: "saveFolder") } }
    @Published var copyToClipboard: Bool { didSet { d.set(copyToClipboard, forKey: "copyToClipboard") } }
    @Published var showQuickAccess: Bool { didSet { d.set(showQuickAccess, forKey: "showQuickAccess") } }
    /// Karten unten links nach `quickAccessSeconds` ausblenden.
    @Published var quickAccessAutoHide: Bool { didSet { d.set(quickAccessAutoHide, forKey: "quickAccessAutoHide") } }
    /// Anzeigedauer der Karten, frei wählbar.
    @Published var quickAccessSeconds: Int {
        didSet {
            let clamped = quickAccessSeconds.clamped(to: Self.quickAccessSecondsRange)
            if clamped != quickAccessSeconds { quickAccessSeconds = clamped }
            d.set(quickAccessSeconds, forKey: "quickAccessSeconds")
        }
    }
    static let quickAccessSecondsRange = 1...3600
    /// 0 = nie automatisch ausblenden.
    var quickAccessAutoClose: Int { quickAccessAutoHide ? quickAccessSeconds : 0 }
    @Published var openEditorAfterCapture: Bool { didSet { d.set(openEditorAfterCapture, forKey: "openEditorAfterCapture") } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: "playSound") } }
    @Published var recordingFPS: Int { didSet { d.set(recordingFPS, forKey: "recordingFPS") } }
    @Published var recordingShowCursor: Bool { didSet { d.set(recordingShowCursor, forKey: "recordingShowCursor") } }
    @Published var recordingCountdown: Bool { didSet { d.set(recordingCountdown, forKey: "recordingCountdown") } }
    @Published var recordingMicrophone: Bool { didSet { d.set(recordingMicrophone, forKey: "recordingMicrophone") } }
    /// Videos in Bildschirmgröße (1×): halb so große Dateien wie Retina (gemessen 08.10.2026).
    @Published var recordingAtScreenSize: Bool { didSet { d.set(recordingAtScreenSize, forKey: "recordingAtScreenSize") } }
    @Published var recordingHEVC: Bool { didSet { d.set(recordingHEVC, forKey: "recordingHEVC") } }
    /// Klicks als Kreis einblenden (ScreenCaptureKit, macOS 15+).
    @Published var recordingShowClicks: Bool { didSet { d.set(recordingShowClicks, forKey: "recordingShowClicks") } }
    @Published var gifFPS: Int { didSet { d.set(gifFPS, forKey: "gifFPS") } }
    @Published var gifWidth: Int { didSet { d.set(gifWidth, forKey: "gifWidth") } }
    @Published var redactStyle: RedactStyle { didSet { d.set(redactStyle.rawValue, forKey: "redactStyle") } }
    /// Bildschirmgröße (1×) statt Retina (2×): Dateien ~⅓ so groß, beim Einfügen so groß wie auf dem Bildschirm.
    @Published var exportAtScreenSize: Bool { didSet { d.set(exportAtScreenSize, forKey: "exportAtScreenSize") } }
    @Published var imageFormat: ImageFormat { didSet { d.set(imageFormat.rawValue, forKey: "imageFormat") } }
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
    /// Hell, Dunkel oder wie macOS — gilt sofort für alle Fenster (`NSApp.appearance`).
    @Published var appearance: AppearanceMode {
        didSet {
            d.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
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
        // Bis 09.10.2026 eine feste Auswahl (0 = nie) unter „quickAccessAutoClose“.
        let legacyAutoClose = d.object(forKey: "quickAccessAutoClose") as? Int ?? 0
        quickAccessAutoHide = d.object(forKey: "quickAccessAutoHide") as? Bool ?? (legacyAutoClose > 0)
        quickAccessSeconds = (d.object(forKey: "quickAccessSeconds") as? Int ?? (legacyAutoClose > 0 ? legacyAutoClose : 10))
            .clamped(to: Self.quickAccessSecondsRange)
        openEditorAfterCapture = d.object(forKey: "openEditorAfterCapture") as? Bool ?? false
        playSound = d.object(forKey: "playSound") as? Bool ?? true
        recordingFPS = d.object(forKey: "recordingFPS") as? Int ?? 30
        recordingShowCursor = d.object(forKey: "recordingShowCursor") as? Bool ?? true
        recordingCountdown = d.object(forKey: "recordingCountdown") as? Bool ?? true
        recordingMicrophone = d.object(forKey: "recordingMicrophone") as? Bool ?? false
        recordingAtScreenSize = d.object(forKey: "recordingAtScreenSize") as? Bool ?? true
        recordingHEVC = d.object(forKey: "recordingHEVC") as? Bool ?? false
        recordingShowClicks = d.object(forKey: "recordingShowClicks") as? Bool ?? true
        gifFPS = d.object(forKey: "gifFPS") as? Int ?? 15
        gifWidth = d.object(forKey: "gifWidth") as? Int ?? 960
        redactStyle = RedactStyle(rawValue: d.string(forKey: "redactStyle") ?? "") ?? .solid
        showAutoRedact = d.object(forKey: "showAutoRedact") as? Bool ?? false
        exportAtScreenSize = d.object(forKey: "exportAtScreenSize") as? Bool ?? true
        imageFormat = ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png
        if let raw = d.stringArray(forKey: "autoRedactKinds") {
            autoRedactKinds = Set(raw.compactMap(SensitiveDetector.Kind.init(rawValue:)))
        } else {
            autoRedactKinds = Set(SensitiveDetector.Kind.allCases)
        }
        retentionDays = d.object(forKey: "retentionDays") as? Int ?? 30
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        // Bis 20.10.2026 ließ sich die Rückfrage vor Aufnahmen per Link hier abschalten. Jedes andere Programm kann
        // die Benutzereinstellungen umschreiben — die Rückfrage kommt deshalb immer (`LinkCommands`).
        d.removeObject(forKey: "linkCaptureWithoutConfirm")
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

    private func migrate() {
        let version = d.integer(forKey: "settingsVersion")
        guard version < 3 else { return }
        var keys = hotkeys
        if version < 2 {
            // v2 (08.10.2026): Zensur standardmäßig als Balken, Editor startet mit dem Zensur-Werkzeug.
            redactStyle = .solid
            d.set(RedactStyle.solid.rawValue, forKey: "redactStyle")
            d.removeObject(forKey: "editorTool")
        }
        // v3: Kürzel wie macOS. Alte ⌥⇧-Belegung → ⌘⇧. ⌘3/⌘4/⌘5 ohne ⇧ entstehen, wenn macOS ⌘⇧3/⌘⇧5
        // beim Festlegen abfängt — global würde ⌘3 dann in jeder App fehlen.
        let optShift = UInt32(optionKey | shiftKey), cmdOnly = UInt32(cmdKey), cmdShift = UInt32(cmdKey | shiftKey)
        for action in HotkeyAction.allCases {
            guard let combo = keys[action] else { continue }
            if combo.modifiers == optShift, let new = action.defaultCombo {
                keys[action] = new
            } else if combo.modifiers == cmdOnly, [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].map(UInt32.init).contains(combo.keyCode) {
                keys[action] = KeyCombo(keyCode: combo.keyCode, modifiers: cmdShift)
            }
        }
        hotkeys = keys
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, $0.value) })) {
            d.set(data, forKey: "hotkeys")
        }
        d.set(3, forKey: "settingsVersion")
    }

    /// Darstellung auf die ganze App anwenden (beim Start und bei jeder Änderung).
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    /// Tatsächlich registrierte Kürzel.
    var activeHotkeys: [HotkeyAction: KeyCombo] { hotkeys.filter { !disabledHotkeys.contains($0.key) } }

    static var defaultHotkeys: [HotkeyAction: KeyCombo] {
        var keys: [HotkeyAction: KeyCombo] = [:]
        for a in HotkeyAction.allCases { if let c = a.defaultCombo { keys[a] = c } }
        return keys
    }

    /// Verkleinerungsfaktor für die Ausgabe eines Bildes mit `scale` Pixeln pro Punkt.
    func outputFactor(sourceScale: CGFloat) -> CGFloat {
        exportAtScreenSize && sourceScale > 1 ? 1 / sourceScale : 1
    }

    /// Ausgabe (Datei + Zwischenablage): ggf. verkleinert, im gewählten Format — im Hintergrund.
    func outputPromise(sourceScale: CGFloat, format: ImageFormat? = nil, render: @escaping @Sendable () -> CGImage?) -> ImagePromise {
        let factor = outputFactor(sourceScale: sourceScale)
        return ImagePromise(format: format ?? imageFormat) {
            render().map { ImageIOHelper.scaled($0, by: factor) }
        }
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
