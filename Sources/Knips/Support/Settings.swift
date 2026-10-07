import AppKit
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
        case .solid: "Schwärzen"
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
        redactStyle = RedactStyle(rawValue: d.string(forKey: "redactStyle") ?? "") ?? .pixelate
        var keys: [HotkeyAction: KeyCombo] = [:]
        if let data = d.data(forKey: "hotkeys"),
           let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (raw, combo) in stored { if let a = HotkeyAction(rawValue: raw) { keys[a] = combo } }
        } else {
            for a in HotkeyAction.allCases { if let c = a.defaultCombo { keys[a] = c } }
        }
        hotkeys = keys
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
