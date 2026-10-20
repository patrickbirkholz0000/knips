import AppKit
import AVFoundation
import SwiftUI

/// Einstellungen: links eine dunkle, abgerundete Liste (ausgewählter Eintrag mit Pfeil),
/// rechts helle Fläche mit großen Überschriften und weißen Karten.
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: SettingsWindowController?
    static let size = NSSize(width: 900, height: 640)
    /// Bei DockPresence angemeldet (zwischen Öffnen und Schließen) — erneutes Öffnen zählt nicht doppelt.
    private var inDock = false

    /// Fenster unsichtbar anlegen, damit das erste Öffnen nicht hängt.
    static func prewarm() {
        if instance == nil {
            instance = SettingsWindowController()
            instance?.window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    static func show(_ pane: SettingsPane? = nil) {
        Telemetry.count(.settingsOpen)
        if instance == nil { instance = SettingsWindowController() }
        if let pane { SettingsNavigation.shared.pane = pane }
        if let instance, !instance.inDock {
            instance.inDock = true
            DockPresence.windowOpened()
        }
        instance?.showWindow(nil)
        instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Knips – Einstellungen"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(Theme.page)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Self.size.width, height: 520)
        window.contentMaxSize = NSSize(width: Self.size.width, height: 1400)
        window.contentView = NSHostingView(rootView: SettingsRoot(settings: AppSettings.shared, nav: SettingsNavigation.shared))
        window.setFrameAutosaveName("KnipsSettings2")
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("KnipsSettings2") { window.center() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        HotkeyRecorderState.shared.cancel()
        if inDock {
            inDock = false
            DockPresence.windowClosed()
        }
    }
}

/// Farben und Formen der Einstellungen: helle Fläche, dunkle Seitenleiste, weiße Karten, schwarze Knöpfe.
enum Theme {
    static let page = Color(red: 0.955, green: 0.955, blue: 0.962)
    static let sidebar = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let sidebarSelected = Color(white: 0.2)
    static let card = Color.white
    static let border = Color.black.opacity(0.07)
    static let ink = Color(white: 0.09)
    static let muted = Color(white: 0.45)
    static let soft = Color(white: 0.93)
}

@MainActor final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var pane: SettingsPane = SettingsPane(rawValue: UserDefaults.standard.string(forKey: "settingsPane") ?? "") ?? .general {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane") }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcuts, recording, redaction, export, storage, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Allgemein"
        case .shortcuts: "Tastaturkürzel"
        case .recording: "Bildschirmaufnahme"
        case .redaction: "Zensur"
        case .export: "Export"
        case .storage: "Ablage"
        case .privacy: "Datenschutz"
        case .about: "Über Knips"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .recording: "record.circle"
        case .redaction: "eye.slash"
        case .export: "square.and.arrow.up"
        case .storage: "folder"
        case .privacy: "lock"
        case .about: "info.circle"
        }
    }

    var summary: String {
        switch self {
        case .general: "Was nach einem Screenshot oder einer Aufnahme passiert."
        case .shortcuts: "Globale Kürzel für Screenshots und Aufnahmen. Sie funktionieren in jeder App."
        case .recording: "Größe, Format und Darstellung deiner Bildschirmvideos."
        case .redaction: "Wie sensible Stellen in Bildern und Videos unkenntlich werden."
        case .export: "Größe und Format von Screenshots, GIFs und Videos."
        case .storage: "Wo deine Aufnahmen liegen und wie lange Originale bleiben."
        case .privacy: "Freigaben von macOS und anonyme Nutzungsstatistik. Aufnahmen bleiben auf deinem Mac."
        case .about: "Screenshots und kurze Bildschirmaufnahmen — mit Zensur für Bilder und Videos."
        }
    }
}

// MARK: - Gerüst

struct SettingsRoot: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var nav: SettingsNavigation

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            Sidebar(nav: nav)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(nav.pane.title)
                            .font(.system(size: 30, weight: .bold))
                            .tracking(-0.6)
                            .foregroundStyle(Theme.ink)
                        Text(nav.pane.summary)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 34)
                    detail
                }
                .padding(.trailing, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page)
        .ignoresSafeArea()
        .tint(Theme.ink)
    }

    @ViewBuilder private var detail: some View {
        switch nav.pane {
        case .general: GeneralPane(settings: settings)
        case .shortcuts: ShortcutsPane(settings: settings)
        case .recording: RecordingPane(settings: settings)
        case .redaction: RedactionPane(settings: settings)
        case .export: ExportPane(settings: settings)
        case .storage: StoragePane(settings: settings)
        case .privacy: PrivacyPane()
        case .about: AboutPane()
        }
    }
}

/// Dunkle Seitenleiste: ausgewählter Eintrag heller, mit Pfeil.
private struct Sidebar: View {
    @ObservedObject var nav: SettingsNavigation
    @State private var hovered: SettingsPane?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Knips").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text("Einstellungen").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
            ForEach(SettingsPane.allCases) { pane in
                row(pane)
                if pane == .shortcuts || pane == .export {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 8)
                }
            }
            Spacer(minLength: 12)
            Text(version)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(width: 252)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.sidebar))
        .padding(.top, 30)   // Fensterknöpfe sitzen darüber auf der hellen Fläche
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "1.0.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    private func row(_ pane: SettingsPane) -> some View {
        let selected = nav.pane == pane
        return Button { nav.pane = pane } label: {
            HStack(spacing: 11) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
                Text(pane.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.78))
                Spacer()
                if selected {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Theme.sidebarSelected : Color.white.opacity(hovered == pane ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? pane : (hovered == pane ? nil : hovered) }
    }
}

// MARK: - Bausteine

/// Weiße Karte mit feinem Rand, optional mit Überschrift darüber und Erklärung darunter.
private struct Card<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 6)
            }
            VStack(spacing: 0) { content }
                .padding(.horizontal, 18)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// Zeile in einer Karte: Titel (+ Untertitel) links, Bedienelement rechts.
private struct Row<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.vertical, 13)
        .frame(minHeight: 52)
    }
}

private struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

private struct Switch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Color(red: 0.2, green: 0.72, blue: 0.4))
    }
}

/// Auswahl als kompakte Menü-Schaltfläche.
private struct Choice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// Zahl frei eintippen oder mit den Pfeilen ändern. Übernimmt jede gültige Eingabe sofort,
/// beim Verlassen des Felds wird eine ungültige auf den letzten Wert zurückgesetzt.
private struct SecondsField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .focused($focused)
                .frame(width: 52, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.soft))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Theme.ink.opacity(0.4) : Theme.border))
                .onSubmit(normalize)
                .onChange(of: text) { _, new in
                    if let n = Int(new.filter(\.isNumber)), range.contains(n), n != value { value = n }
                }
                .onChange(of: focused) { _, isFocused in if !isFocused { normalize() } }
            Text(value == 1 ? "Sekunde" : "Sekunden")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .frame(width: 62, alignment: .leading)
            Stepper("", value: $value, in: range).labelsHidden()
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, new in if Int(text) != new { text = "\(new)" } }
    }

    private func normalize() {
        if let n = Int(text.filter(\.isNumber)) { value = n.clamped(to: range) }
        text = "\(value)"
    }
}

/// Schwarze Schaltfläche als Hauptaktion, hellgrau als Nebenaktion.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(primary ? Theme.ink : (destructive ? Color.red.opacity(0.1) : Theme.soft)))
            .foregroundStyle(primary ? .white : (destructive ? .red : Theme.ink))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// Hinweis-Karte (gelb = zu tun, grün = erledigt).
private struct Notice<Action: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                action.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(color.opacity(0.25)))
    }
}

private struct InfoLine: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 0.2, green: 0.6, blue: 0.4))
            Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.vertical, 11)
    }
}

// MARK: - Bereiche

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "Nach einer Aufnahme") {
                Row(title: "In die Zwischenablage kopieren") { Switch(isOn: $settings.copyToClipboard) }
                RowDivider()
                Row(title: "Editor sofort öffnen") { Switch(isOn: $settings.openEditorAfterCapture) }
                RowDivider()
                Row(title: "Auslöser-Ton") { Switch(isOn: $settings.playSound) }
            }
            Card(title: "Karten unten links",
                 footer: "Ein Klick auf die Karte öffnet die Aufnahme. Über die Knöpfe darauf kopierst du, pinnst an oder kopierst den Text, und du kannst die Karte in eine andere App ziehen. Solange die Maus darauf liegt, bleibt sie stehen.") {
                Row(title: "Karte anzeigen") { Switch(isOn: $settings.showQuickAccess) }
                RowDivider()
                Row(title: "Automatisch ausblenden") {
                    Switch(isOn: $settings.quickAccessAutoHide).disabled(!settings.showQuickAccess)
                }
                RowDivider()
                let timed = settings.showQuickAccess && settings.quickAccessAutoHide
                Row(title: "Anzeigedauer", subtitle: timed ? "So lange bleibt die Karte stehen" : "Die Karte bleibt, bis du sie schließt") {
                    SecondsField(value: $settings.quickAccessSeconds, range: AppSettings.quickAccessSecondsRange)
                }
                .disabled(!timed)
                .opacity(timed ? 1 : 0.45)
            }
            Card(title: "Start") {
                Row(title: "Beim Anmelden öffnen") {
                    Switch(isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                }
            }
            Card(title: "Befehle per Link",
                 footer: "Sonst fragt Knips nach, bevor knips://fullscreen, knips://last oder knips://record aufnehmen – solche Links kann jede App und jede Webseite öffnen.") {
                Row(title: "Aufnahmen per Link ohne Rückfrage") { Switch(isOn: $settings.linkCaptureWithoutConfirm) }
            }
        }
    }
}

private struct ShortcutsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var tick = 0

    private let groups: [(String, [HotkeyAction])] = [
        ("Bildschirmfotos", [.captureArea, .captureWindow, .captureFullscreen, .captureLastArea, .captureScrolling, .captureText]),
        ("Bildschirmaufnahme", [.toggleRecording]),
        ("Sonstiges", [.pinClipboard]),
    ]

    var body: some View {
        let _ = tick
        let conflicts = settings.activeHotkeys.values.filter { SystemShortcuts.conflict(for: $0) != nil }.sorted { $0.keyCode < $1.keyCode }
        let blockedIDs = Array(Set(SystemShortcuts.conflictingIDs(for: Array(settings.activeHotkeys.values)))
            .union(SystemShortcuts.enabledScreenshotIDs())).sorted()
        VStack(alignment: .leading, spacing: 22) {
            if !blockedIDs.isEmpty {
                Notice(symbol: "exclamationmark.triangle.fill", color: .orange,
                       title: conflicts.isEmpty ? "macOS belegt \(SystemShortcuts.displayList(blockedIDs)) noch selbst"
                                                : "macOS nutzt \(conflicts.map(\.display).joined(separator: ", ")) noch selbst",
                       detail: "Solange das so ist, kommen diese Kürzel nicht bei Knips an — auch nicht beim Festlegen hier. Knips schaltet die macOS-Kürzel für Bildschirmfotos ab; jederzeit rückgängig zu machen.") {
                    Button("Für Knips freimachen") {
                        SystemShortcuts.takeOver(blockedIDs)
                        tick += 1
                    }
                    .buttonStyle(PillButtonStyle(primary: true))
                }
            } else if SystemShortcuts.hasTakenOver {
                Notice(symbol: "checkmark.circle.fill", color: .green, title: "Knips hat die Bildschirmfoto-Kürzel übernommen",
                       detail: "Die entsprechenden macOS-Kürzel sind abgeschaltet.") {
                    Button("macOS-Kürzel wiederherstellen") {
                        SystemShortcuts.restore()
                        tick += 1
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            ForEach(groups, id: \.0) { title, actions in
                Card(title: title) {
                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        if index > 0 { RowDivider() }
                        ShortcutRow(action: action, settings: settings)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Standardwerte wiederherstellen") {
                    HotkeyRecorderState.shared.cancel()
                    settings.hotkeys = AppSettings.defaultHotkeys
                    settings.disabledHotkeys = []
                    HotkeyManager.shared.apply(settings.activeHotkeys)
                    tick += 1
                }
                .buttonStyle(PillButtonStyle())
                Button("Kurzbefehle von macOS …") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
                .buttonStyle(PillButtonStyle())
            }
            Text("Kürzel anklicken und die neue Kombination drücken. ⌫ entfernt, Esc bricht ab. Standard wie bei macOS: ⇧⌘3 Bildschirm, ⇧⌘4 Bereich (Leertaste: Fenster), ⇧⌘5 Video.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
    }
}

/// Häkchen, Titel, rechts das Kürzel als Tastenkappe; Klick nimmt ein neues auf.
private struct ShortcutRow: View {
    let action: HotkeyAction
    @ObservedObject var settings: AppSettings
    @ObservedObject private var recorder = HotkeyRecorderState.shared
    @State private var hovering = false

    private var combo: KeyCombo? { settings.hotkeys[action] }
    private var isRecording: Bool { recorder.recording == action }

    private var enabled: Binding<Bool> {
        Binding(get: { combo != nil && !settings.disabledHotkeys.contains(action) }, set: { on in
            if on { settings.disabledHotkeys.remove(action) } else { settings.disabledHotkeys.insert(action) }
            HotkeyManager.shared.apply(settings.activeHotkeys)
        })
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: enabled).toggleStyle(.checkbox).labelsHidden().disabled(combo == nil)
            Text(action.title)
                .font(.system(size: 14))
                .foregroundStyle(enabled.wrappedValue ? Theme.ink : Theme.muted)
            Spacer(minLength: 8)
            if let combo, enabled.wrappedValue, let conflict = SystemShortcuts.conflict(for: combo) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Wird auch von macOS verwendet („\(conflict)“).")
            }
            if enabled.wrappedValue, HotkeyManager.shared.failures.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Bereits von einer anderen App belegt.")
            }
            Button {
                if isRecording { recorder.cancel() } else { record() }
            } label: {
                Text(isRecording ? "Kürzel drücken …" : (combo?.display ?? "Kein Kürzel"))
                    .font(.system(size: 13, weight: isRecording || combo == nil ? .regular : .semibold).monospacedDigit())
                    .foregroundStyle(isRecording ? Theme.muted : (combo == nil ? Theme.muted : Theme.ink))
                    .padding(.horizontal, 12)
                    .frame(minWidth: 92, minHeight: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering || isRecording ? Theme.soft : Theme.page))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isRecording ? Theme.ink : Theme.border, lineWidth: isRecording ? 2 : 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Klicken und neue Tastenkombination drücken")
        }
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    private func record() {
        recorder.start(action) { result in
            guard let result else { return }
            var keys = settings.hotkeys
            if result.keyCode == UInt32.max {
                keys[action] = nil
            } else {
                for (other, c) in keys where c == result && other != action { keys[other] = nil }
                keys[action] = result
                settings.disabledHotkeys.remove(action)
            }
            settings.hotkeys = keys
            HotkeyManager.shared.apply(settings.activeHotkeys)
        }
    }
}

private struct RecordingPane: View {
    @ObservedObject var settings: AppSettings
    private var modern: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "Video",
                 footer: "Gemessen am Vollbild je 4 Sekunden: Retina-H.264 2,2 MB · 1×-H.264 1,2 MB · 1×-HEVC 0,9 MB. HEVC spielt jeder Mac ab, Windows nicht immer.") {
                Row(title: "Größe") {
                    Choice(selection: $settings.recordingAtScreenSize, options: [(true, "Bildschirmgröße (1×)"), (false, "Retina (2×)")])
                }
                RowDivider()
                Row(title: "Format") {
                    Choice(selection: $settings.recordingHEVC, options: [(false, "H.264 – überall abspielbar"), (true, "HEVC – kleiner")])
                }
                RowDivider()
                Row(title: "Bildrate") {
                    Choice(selection: $settings.recordingFPS, options: [(30, "30 fps"), (60, "60 fps")])
                }
            }
            Card(title: "Darstellung") {
                Row(title: "Mauszeiger aufnehmen") { Switch(isOn: $settings.recordingShowCursor) }
                RowDivider()
                Row(title: "Mausklicks hervorheben", subtitle: modern ? nil : "braucht macOS 15") {
                    Switch(isOn: $settings.recordingShowClicks).disabled(!modern)
                }
                RowDivider()
                Row(title: "Countdown 3 – 2 – 1") { Switch(isOn: $settings.recordingCountdown) }
            }
            Card(title: "Ton", footer: "Für gesprochene Erklärungen. Beim ersten Mal fragt macOS nach dem Mikrofon.") {
                Row(title: "Mikrofon aufnehmen", subtitle: modern ? nil : "braucht macOS 15") {
                    Switch(isOn: $settings.recordingMicrophone).disabled(!modern)
                }
            }
            Card(title: "Stoppen") {
                Row(title: "Stopp-Leiste, Menüleisten-Symbol oder Kürzel") {
                    Text(settings.activeHotkeys[.toggleRecording]?.display ?? "—")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

private struct RedactionPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "Standardstil",
                 footer: "„Balken“ ist am sichersten. Im Editor: Klick auf Text legt einen Balken über die Zeile, ⌥-Klick über ein Wort; gezogene Balken wachsen auf ganze Wörter.") {
                HStack(spacing: 18) {
                    ForEach(RedactStyle.allCases) { style in
                        RedactStyleCard(style: style, selected: settings.redactStyle == style) { settings.redactStyle = style }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 16)
            }
            Card(title: "Auto-Zensur",
                 footer: "Sucht per Texterkennung nach E-Mails, IBANs, Schlüsseln usw. und legt Balken an. Normalerweise ziehst du Balken selbst — der Knopf ist deshalb aus.") {
                Row(title: "Knopf „Auto-Zensur“ in den Editoren") { Switch(isOn: $settings.showAutoRedact) }
                if settings.showAutoRedact {
                    ForEach(SensitiveDetector.Kind.allCases, id: \.self) { kind in
                        RowDivider()
                        Row(title: kind.longTitle, subtitle: kind.example) {
                            Switch(isOn: Binding(get: { settings.autoRedactKinds.contains(kind) }, set: { on in
                                if on { settings.autoRedactKinds.insert(kind) } else { settings.autoRedactKinds.remove(kind) }
                            }))
                        }
                    }
                }
            }
        }
    }
}

/// Auswahlkarte mit Vorschau.
private struct RedactStyleCard: View {
    let style: RedactStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(nsImage: RedactPreview.image(for: style))
                    .resizable()
                    .frame(width: 112, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Theme.ink : Theme.border, lineWidth: selected ? 2.5 : 1))
                Text(style.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ExportPane: View {
    @ObservedObject var settings: AppSettings

    private var sizeHint: String {
        switch (settings.exportAtScreenSize, settings.imageFormat) {
        case (true, .png): "ca. 0,7–2 MB"
        case (true, .jpeg): "ca. 0,25–0,6 MB"
        case (false, .png): "ca. 2–7 MB"
        case (false, .jpeg): "ca. 0,6–1,6 MB"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "Screenshots",
                 footer: "Bildschirmgröße: so groß wie auf dem Bildschirm, beim Einfügen nicht doppelt so groß. Das Original bleibt für spätere Bearbeitung in voller Auflösung.") {
                Row(title: "Größe") {
                    Choice(selection: $settings.exportAtScreenSize, options: [(true, "Bildschirmgröße (1×)"), (false, "Retina (2×)")])
                }
                RowDivider()
                Row(title: "Format") {
                    Choice(selection: $settings.imageFormat, options: ImageFormat.allCases.map { ($0, $0.title) })
                }
                RowDivider()
                Row(title: "Vollbild-Screenshot") {
                    Text(sizeHint).font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.muted)
                }
            }
            Card(title: "GIF", footer: "Ruhige Stellen werden zusammengefasst — das hält GIFs klein.") {
                Row(title: "Bildrate") {
                    Choice(selection: $settings.gifFPS, options: [(10, "10 fps"), (15, "15 fps"), (20, "20 fps"), (25, "25 fps")])
                }
                RowDivider()
                Row(title: "Maximale Breite") {
                    Choice(selection: $settings.gifWidth, options: [(640, "640 px"), (800, "800 px"), (960, "960 px"), (1280, "1280 px")])
                }
            }
            Card(title: "Video") {
                Row(title: "Zensur und Kürzung", subtitle: "werden beim Speichern eingerechnet, das Format bleibt erhalten") { EmptyView() }
            }
        }
    }
}

private struct StoragePane: View {
    @ObservedObject var settings: AppSettings
    @State private var usage = "…"
    @State private var confirmPurge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "Ablageordner", footer: "Dort liegt immer die bearbeitete Fassung — zensierte Stellen sind darin endgültig unkenntlich.") {
                HStack(spacing: 12) {
                    Image(nsImage: FileManager.default.fileExists(atPath: settings.saveFolder.path)
                          ? NSWorkspace.shared.icon(forFile: settings.saveFolder.path)
                          : NSWorkspace.shared.icon(for: .folder))
                        .resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.saveFolder.lastPathComponent).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                        Text(settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Ändern …") { chooseFolder() }.buttonStyle(PillButtonStyle())
                    Button("Öffnen") {
                        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(settings.saveFolder)
                    }
                    .buttonStyle(PillButtonStyle(primary: true))
                }
                .padding(.vertical, 14)
            }
            Card(title: "Originale", footer: "Mit dem Original lässt sich eine Zensur später ändern. Es liegt getrennt in der App-Ablage und wird nie geteilt.") {
                Row(title: "Aufbewahren") {
                    Choice(selection: $settings.retentionDays,
                           options: [(7, "7 Tage"), (30, "30 Tage"), (90, "90 Tage"), (365, "1 Jahr"), (0, "Unbegrenzt")])
                }
                RowDivider()
                Row(title: "Belegt") { Text(usage).font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.muted) }
                RowDivider()
                Row(title: "Alle Originale löschen", subtitle: "Dateien im Ablageordner bleiben") {
                    Button("Löschen …") { confirmPurge = true }.buttonStyle(PillButtonStyle(destructive: true))
                }
            }
        }
        .onAppear(perform: refreshUsage)
        .confirmationDialog("Alle Originale löschen?", isPresented: $confirmPurge) {
            Button("Löschen", role: .destructive) {
                CaptureStore.shared.purgeOriginals()
                refreshUsage()
            }
        } message: {
            Text("Bereits gespeicherte Zensuren lassen sich danach nicht mehr ändern.")
        }
    }

    private func refreshUsage() {
        let bytes = CaptureStore.shared.storageSize()
        usage = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " · \(CaptureStore.shared.items.count) Aufnahmen"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Auswählen"
        if panel.runModal() == .OK, let url = panel.url { settings.saveFolderPath = url.path }
    }
}

private struct PrivacyPane: View {
    @ObservedObject private var telemetry = Telemetry.shared
    @State private var screen = ScreenCapture.hasPermission
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "Freigaben") {
                permission("rectangle.dashed.badge.record", "Bildschirm- & Systemaudioaufnahme", "Für Screenshots und Videos nötig", screen) {
                    if !CGRequestScreenCaptureAccess() { PermissionWindowController.show() }
                }
                RowDivider()
                permission("mic", "Mikrofon", "Nur für Aufnahmen mit Kommentar", mic == .authorized) {
                    if mic == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }
            Card(title: "Nutzungsstatistik",
                 footer: telemetry.config.enabled ? nil : "Entwickler-Build: Hier wird nichts gesendet. KNIPS_TELEMETRY=1 schaltet das Senden ein.") {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Anonyme Nutzungsstatistik").font(.system(size: 14)).foregroundStyle(Theme.ink)
                        Text("Zählt nur, welche Funktionen wie oft genutzt werden — nie Bilder, Texte oder Dateinamen.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        Link(destination: Telemetry.infoURL) {
                            HStack(spacing: 3) {
                                Text("Was wird gesendet?")
                                Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 8)
                    Switch(isOn: Binding(get: { telemetry.consent == true }, set: { telemetry.setConsent($0) }))
                }
                .padding(.vertical, 13)
            }
            Card(title: "So arbeitet Knips") {
                InfoLine(symbol: "cpu", text: "Texterkennung läuft auf diesem Mac")
                RowDivider()
                InfoLine(symbol: "network.slash", text: telemetry.consent == true
                         ? "Kein Konto — ins Internet gehen nur die anonymen Zähler"
                         : "Kein Konto, nichts geht ins Internet")
                RowDivider()
                InfoLine(symbol: "checkmark.shield", text: "Geteilte Dateien sind immer die zensierte Fassung")
                RowDivider()
                InfoLine(symbol: "doc.on.clipboard", text: "„Text kopieren“ lässt zensierte Wörter weg")
            }
        }
        .onReceive(timer) { _ in
            screen = ScreenCapture.hasPermission
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private func permission(_ symbol: String, _ title: String, _ detail: String, _ granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 30, height: 30)
                .background(Circle().fill(Theme.soft)).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if granted {
                Label("Erlaubt", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 0.4))
            } else {
                Button("Erlauben …", action: action).buttonStyle(PillButtonStyle(primary: true))
            }
        }
        .padding(.vertical, 12)
    }
}

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "1.0.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                    Text("Knips").font(.system(size: 26, weight: .bold)).tracking(-0.5).foregroundStyle(Theme.ink)
                    Text(version).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    VStack(spacing: 3) {
                        Text("© 2026 Patrick Birkholz").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                        Text("Freie Software unter der GNU GPL v3 oder neuer — ohne jede Gewährleistung.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    Button { NSWorkspace.shared.open(AboutPane.sourceURL) } label: {
                        HStack(spacing: 5) {
                            Text("Quellcode")
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .help(AboutPane.sourceURL.absoluteString)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            Card(title: "Funktionen") {
                InfoLine(symbol: "", text: "Bereich, Fenster oder Bildschirm — Auswahl auf eingefrorenem Bild")
                RowDivider()
                InfoLine(symbol: "", text: "Zensur-Balken mit Text-Erkennung, auch in Videos")
                RowDivider()
                InfoLine(symbol: "", text: "Bildschirmvideos als MP4 oder GIF")
                RowDivider()
                InfoLine(symbol: "", text: "Text aus Screenshots kopieren")
            }
            Card(title: "Für Raycast & Co.") {
                Row(title: "Befehle", subtitle: "Bildschirm, letzter Bereich und Videostart fragen vorher nach (Allgemein)") {
                    Text("knips://area · window · fullscreen · record · text · last · menu")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    static let sourceURL = URL(string: "https://github.com/patrickbirkholz0000/knips")!
}
