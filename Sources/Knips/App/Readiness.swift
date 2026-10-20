import AppKit
import AVFoundation

/// Bereit-Check der Seite „Start“ (docs/design.md): Bildschirmaufnahme-Freigabe, Mikrofon (freiwillig), Kürzel,
/// Ablageordner. Wird beim Öffnen und immer dann neu geprüft, wenn das Einstellungsfenster aktiv wird — etwa nach
/// einem Abstecher in die Systemeinstellungen.
@MainActor final class Readiness: ObservableObject {
    static let shared = Readiness()

    enum Hotkeys: Equatable {
        case ok([KeyCombo])
        /// Kein Kürzel eingeschaltet.
        case none
        /// macOS belegt diese Kürzel noch für eigene Bildschirmfotos (IDs für `SystemShortcuts.takeOver`).
        case system([KeyCombo], ids: [Int])
        /// Registrieren fehlgeschlagen — eine andere App hat sie.
        case taken([KeyCombo])

        var ok: Bool { if case .ok = self { true } else { false } }
    }

    struct State: Equatable {
        var screen: Bool
        var microphone: AVAuthorizationStatus
        /// „Mikrofon aufnehmen“ ist eingeschaltet — dann zählt eine fehlende Freigabe als offener Schritt.
        var microphoneWanted: Bool
        var hotkeys: Hotkeys
        var folderReachable: Bool

        var microphoneTone: BrandCheckTone {
            if microphone == .authorized { return .done }
            return microphoneWanted ? .missing : .optional
        }

        /// Offene Schritte (das Mikrofon nur, wenn es gebraucht wird).
        var missing: Int {
            [!screen, microphoneTone == .missing, !hotkeys.ok, !folderReachable].filter { $0 }.count
        }
    }

    @Published private(set) var state: State

    #if KNIPS_DEV
    /// Selbsttest: fester Zustand statt der echten Prüfung.
    var simulated: State? { didSet { refresh() } }
    #endif

    private init() {
        state = Self.probe()
    }

    var missing: Int { state.missing }

    /// Sidebar-Status: „Bereit“ bzw. „2 Schritte offen“.
    var summary: String {
        switch missing {
        case 0: "Bereit"
        case 1: "1 Schritt offen"
        default: "\(missing) Schritte offen"
        }
    }

    func refresh() {
        #if KNIPS_DEV
        if let simulated {
            if state != simulated { state = simulated }
            return
        }
        #endif
        let new = Self.probe()
        if new != state { state = new }
    }

    private static func probe() -> State {
        let settings = AppSettings.shared
        return State(screen: ScreenCapture.hasPermission,
                     microphone: AVCaptureDevice.authorizationStatus(for: .audio),
                     microphoneWanted: settings.recordingMicrophone,
                     hotkeys: hotkeyState(settings),
                     folderReachable: folderReachable(settings.saveFolder))
    }

    private static func hotkeyState(_ settings: AppSettings) -> Hotkeys {
        let active = settings.activeHotkeys
        guard !active.isEmpty else { return .none }
        let combos = HotkeyAction.allCases.compactMap { active[$0] }
        let ids = SystemShortcuts.conflictingIDs(for: combos)
        if !ids.isEmpty {
            return .system(combos.filter { SystemShortcuts.conflict(for: $0) != nil }, ids: ids)
        }
        let failed = HotkeyManager.shared.failures.compactMap { active[$0] }
        if !failed.isEmpty { return .taken(failed) }
        return .ok(combos)
    }

    /// Ordner vorhanden und beschreibbar — oder noch nicht da, aber anlegbar (der nächste vorhandene Elternordner
    /// ist beschreibbar). Prüft nur, legt nichts an.
    nonisolated static func folderReachable(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        var current = url.standardizedFileURL
        if fm.fileExists(atPath: current.path, isDirectory: &isDir) {
            return isDir.boolValue && fm.isWritableFile(atPath: current.path)
        }
        while current.path != "/" {
            current = current.deletingLastPathComponent()
            if fm.fileExists(atPath: current.path, isDirectory: &isDir) {
                return isDir.boolValue && fm.isWritableFile(atPath: current.path)
            }
        }
        return false
    }

    // MARK: Aktionen

    static let screenSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// macOS fragt nur beim ersten Mal selbst; danach geht es nur über die Systemeinstellungen.
    func requestScreen() {
        if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(Self.screenSettingsURL) }
        refresh()
    }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { onMainActor { Readiness.shared.refresh() } }
            }
        } else {
            NSWorkspace.shared.open(Self.microphoneSettingsURL)
        }
    }

    /// Schaltet die macOS-Bildschirmfoto-Kürzel ab, die Knips' Kürzel abfangen (jederzeit wiederherstellbar).
    func freeSystemShortcuts(_ ids: [Int]) {
        SystemShortcuts.takeOver(ids)
        HotkeyManager.shared.apply(AppSettings.shared.activeHotkeys)
        refresh()
    }

    /// Ablageordner wählen (auch aus Ablage → „Ändern …“).
    func chooseFolder() {
        let settings = AppSettings.shared
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Auswählen"
        if panel.runModal() == .OK, let url = panel.url { settings.saveFolderPath = url.path }
        refresh()
    }
}
