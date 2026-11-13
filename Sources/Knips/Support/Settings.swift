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

/// Größe der gespeicherten Bildschirmfotos (Einstellungen → Export).
enum ExportSize: String, CaseIterable, Identifiable {
    /// Volle Auflösung mit höchstens 256 Farben, wenn man keinen Unterschied sieht — sonst Bildschirmgröße.
    case auto
    /// Bildschirmgröße (1×), verlustfrei.
    case screen
    /// Volle Auflösung (Retina 2×), verlustfrei.
    case full

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automatisch"
        case .screen: "Bildschirmgröße (1×)"
        case .full: "Retina (2×)"
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
    /// „Automatisch“ (Standard): Retina-scharf bei kleiner Datei — volle Auflösung mit 256 Farben, wenn man keinen
    /// Unterschied sieht, sonst Bildschirmgröße. Daneben wie bisher Bildschirmgröße (1×) oder Retina (2×), verlustfrei.
    @Published var exportSize: ExportSize { didSet { d.set(exportSize.rawValue, forKey: "exportSize") } }
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
    /// Alle Knips-Fenster aus Bildschirmübertragungen anderer Apps heraushalten (`ScreenSharing`), z. B. damit
    /// unzensierte Originale im Editor nicht im Stream landen. Standardmäßig aus.
    @Published var hideFromScreenSharing: Bool {
        didSet {
            d.set(hideFromScreenSharing, forKey: "hideFromScreenSharing")
            ScreenSharing.applyAll()
        }
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
        // Bis 1.0.2 ein Schalter „Bildschirmgröße (1×)“. Wer ihn selbst gestellt hat, behält seine Wahl; alle anderen
        // bekommen „Automatisch“.
        if let raw = d.string(forKey: "exportSize"), let size = ExportSize(rawValue: raw) {
            exportSize = size
        } else if let atScreenSize = d.object(forKey: "exportAtScreenSize") as? Bool {
            exportSize = atScreenSize ? .screen : .full
        } else {
            exportSize = .auto
        }
        imageFormat = ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png
        if let raw = d.stringArray(forKey: "autoRedactKinds") {
            autoRedactKinds = Set(raw.compactMap(SensitiveDetector.Kind.init(rawValue:)))
        } else {
            autoRedactKinds = Set(SensitiveDetector.Kind.allCases)
        }
        retentionDays = d.object(forKey: "retentionDays") as? Int ?? 30
        hideFromScreenSharing = d.object(forKey: "hideFromScreenSharing") as? Bool ?? false
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

    /// Nimmt „Automatisch“ für ein Bild mit `sourceScale` Pixeln pro Punkt die volle Auflösung mit 256 Farben? Nur
    /// bei PNG und nur, wo sonst verkleinert würde (Retina) — auf 1×-Bildschirmen bleibt die Ausgabe verlustfrei.
    func reducesColors(sourceScale: CGFloat, format: ImageFormat? = nil) -> Bool {
        exportSize == .auto && (format ?? imageFormat) == .png && sourceScale > 1
    }

    /// Verkleinerungsfaktor für die Ausgabe eines Bildes mit `scale` Pixeln pro Punkt. Bei „Automatisch“ der
    /// erwartete: volle Auflösung; reichen 256 Farben nicht, wird es doch Bildschirmgröße (`outputPromise`).
    func outputFactor(sourceScale: CGFloat, format: ImageFormat? = nil) -> CGFloat {
        guard sourceScale > 1 else { return 1 }
        switch exportSize {
        case .full: return 1
        case .screen: return 1 / sourceScale
        case .auto: return reducesColors(sourceScale: sourceScale, format: format) ? 1 : 1 / sourceScale
        }
    }

    /// Ausgabe (Datei + Zwischenablage): ggf. verkleinert, im gewählten Format — im Hintergrund.
    func outputPromise(sourceScale: CGFloat, format: ImageFormat? = nil, render: @escaping @Sendable () -> CGImage?) -> ImagePromise {
        let format = format ?? imageFormat
        if reducesColors(sourceScale: sourceScale, format: format) {
            // „Automatisch“: volle Auflösung mit höchstens 256 Farben. Reichen sie nicht, ohne dass man es sähe
            // (Fotos, Videobilder), oder ist das Bild zu groß: Bildschirmgröße, verlustfrei wie bisher.
            return ImagePromise(format: .png, adaptive: {
                guard let full = render() else { return nil }
                if let data = PalettePNG.encode(full, pointScale: sourceScale) { return (full, data, sourceScale) }
                let small = ImageIOHelper.scaled(full, by: 1 / sourceScale)
                return (small, small.pngData(), 1)
            })
        }
        let factor = outputFactor(sourceScale: sourceScale, format: format)
        return ImagePromise(format: format, pointScale: sourceScale * factor) {
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

/// „In Bildschirmübertragungen verbergen“ (Einstellungen → Datenschutz): Ist es an, bekommen alle Knips-Fenster
/// `sharingType = .none` — andere Apps, die den Bildschirm teilen oder aufnehmen (Teams, Zoom, Discord …), sehen sie
/// dann nicht. Standardmäßig aus: Dann sehen andere Apps Knips wie jedes andere Fenster. Knips' eigene Standbilder
/// und Videos lassen Knips-Fenster ohnehin weg (Content-Filter, `ScreenCapture.filter`).
@MainActor enum ScreenSharing {
    static var sharingType: NSWindow.SharingType { AppSettings.shared.hideFromScreenSharing ? .none : .readOnly }

    /// Beim Anlegen eines Fensters, bevor es erscheint.
    static func apply(to window: NSWindow) {
        let type = sharingType
        if window.sharingType != type { window.sharingType = type }
    }

    /// Nach dem Umschalten: alle offenen Fenster sofort.
    static func applyAll() {
        for window in NSApp.windows { apply(to: window) }
    }

    private static var observers: [NSObjectProtocol] = []

    /// Auffangnetz für Fenster, die nicht über `apply(to:)` angelegt werden: beim Erscheinen und beim Aktivieren.
    static func start() {
        guard observers.isEmpty else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                onMainActor { apply(to: window) }
            })
        }
        applyAll()
    }
}
