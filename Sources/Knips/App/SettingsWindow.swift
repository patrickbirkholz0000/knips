import AppKit
import AVFoundation
import SwiftUI

/// Einstellungen im Stil der macOS-Systemeinstellungen: Seitenleiste mit Suche und farbigen
/// Symbol-Kacheln, rechts gruppierte Bereiche.
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: SettingsWindowController?
    static let size = NSSize(width: 740, height: 600)

    /// Fenster unsichtbar anlegen, damit das erste Öffnen nicht hängt.
    static func prewarm() {
        if instance == nil {
            instance = SettingsWindowController()
            instance?.window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    static func show(_ pane: SettingsPane? = nil) {
        if instance == nil { instance = SettingsWindowController() }
        if let pane { SettingsNavigation.shared.pane = pane }
        DockPresence.windowOpened()
        instance?.showWindow(nil)
        instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let controller = NSHostingController(rootView: SettingsRoot(settings: AppSettings.shared, nav: SettingsNavigation.shared))
        controller.sizingOptions = []
        controller.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.size)
        window.contentMinSize = NSSize(width: Self.size.width, height: 460)
        window.contentMaxSize = NSSize(width: Self.size.width, height: 1400)
        window.setFrameAutosaveName("KnipsSettings")
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("KnipsSettings") { window.center() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        HotkeyRecorderState.shared.cancel()
        DockPresence.windowClosed()
    }
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
        case .shortcuts: "Tastaturkurzbefehle"
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
        case .general: "gearshape.fill"
        case .shortcuts: "keyboard.fill"
        case .recording: "record.circle.fill"
        case .redaction: "eye.slash.fill"
        case .export: "square.and.arrow.up.fill"
        case .storage: "folder.fill"
        case .privacy: "hand.raised.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: Color(white: 0.55)
        case .shortcuts: Color(white: 0.5)
        case .recording: Color(red: 1, green: 0.27, blue: 0.23)
        case .redaction: Color(red: 0.36, green: 0.35, blue: 0.9)
        case .export: Color(red: 1, green: 0.58, blue: 0)
        case .storage: Color(red: 0.04, green: 0.52, blue: 1)
        case .privacy: Color(red: 0.04, green: 0.52, blue: 1)
        case .about: Color(white: 0.55)
        }
    }

    var summary: String {
        switch self {
        case .general: "Was nach einem Screenshot oder einer Aufnahme passiert."
        case .shortcuts: "Globale Kürzel für Screenshots und Bildschirmaufnahmen. Sie funktionieren in jeder App."
        case .recording: "Bildrate, Mauszeiger, Countdown und Ton für Bildschirmaufnahmen."
        case .redaction: "Wie sensible Stellen in Bildern und Videos unkenntlich gemacht werden."
        case .export: "Einstellungen für den Export als GIF und MP4."
        case .storage: "Wo deine Aufnahmen liegen und wie lange Originale aufbewahrt werden."
        case .privacy: "Freigaben, die Knips von macOS braucht. Alles bleibt auf deinem Mac."
        case .about: ""
        }
    }

    /// Suchbegriffe für das Suchfeld der Seitenleiste.
    var keywords: [String] {
        switch self {
        case .general: ["zwischenablage", "karte", "quick access", "editor", "ton", "sound", "anmelden", "autostart", "ausblenden"]
        case .shortcuts: ["kürzel", "hotkey", "taste", "tastatur", "shortcut", "bereich", "fenster", "vollbild"]
        case .recording: ["video", "fps", "bildrate", "mauszeiger", "cursor", "countdown", "mikrofon", "audio"]
        case .redaction: ["verpixeln", "unschärfe", "schwärzen", "auto", "e-mail", "iban", "telefon", "schlüssel", "token", "ip"]
        case .export: ["gif", "mp4", "breite", "bildrate"]
        case .storage: ["ordner", "speicherort", "original", "aufbewahren", "löschen", "speicher"]
        case .privacy: ["berechtigung", "freigabe", "bildschirmaufnahme", "mikrofon", "datenschutz"]
        case .about: ["version", "info"]
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return title.lowercased().contains(q) || keywords.contains { $0.contains(q) }
    }
}

// MARK: - Gerüst

struct SettingsRoot: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var nav: SettingsNavigation
    @State private var search = ""

    private let groups: [[SettingsPane]] = [[.general, .shortcuts], [.recording, .redaction, .export], [.storage, .privacy]]

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsPane?>(get: { nav.pane }, set: { if let p = $0 { nav.pane = p } })) {
                if search.isEmpty {
                    AppCard().tag(SettingsPane.about)
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    let visible = group.filter { $0.matches(search) }
                    if !visible.isEmpty {
                        Section {
                            ForEach(visible) { pane in
                                Label { Text(pane.title) } icon: { IconTile(symbol: pane.symbol, color: pane.color, size: 20) }
                                    .tag(pane)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Suchen")
            .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 215)
        } detail: {
            detail
                .navigationTitle(nav.pane.title)
                .frame(minWidth: 480)
        }
        .toolbar(removing: .sidebarToggle)
        .onChange(of: search) { _, q in
            if !nav.pane.matches(q), let first = SettingsPane.allCases.first(where: { $0.matches(q) }) { nav.pane = first }
        }
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

private struct AppCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Knips").font(.system(size: 13, weight: .semibold))
                Text("Screenshots & Aufnahmen").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Farbige Kachel mit weißem Symbol, wie in den Systemeinstellungen.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .frame(width: size, height: size)
    }
}

/// Kopfbereich eines Bereichs: große Kachel, Titel, kurze Erklärung.
private struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        Section {
            VStack(spacing: 8) {
                IconTile(symbol: pane.symbol, color: pane.color, size: 56)
                Text(pane.title).font(.system(size: 17, weight: .bold))
                Text(pane.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Bereiche

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            PaneHeader(pane: .general)
            Section("Nach einer Aufnahme") {
                Toggle("In die Zwischenablage kopieren", isOn: $settings.copyToClipboard)
                Toggle("Editor sofort öffnen", isOn: $settings.openEditorAfterCapture)
                Toggle("Auslöser-Ton abspielen", isOn: $settings.playSound)
            }
            Section {
                Toggle("Karte unten links anzeigen", isOn: $settings.showQuickAccess)
                Picker("Karte automatisch ausblenden", selection: $settings.quickAccessAutoClose) {
                    Text("Nie").tag(0)
                    Text("Nach 5 Sekunden").tag(5)
                    Text("Nach 10 Sekunden").tag(10)
                    Text("Nach 30 Sekunden").tag(30)
                    Text("Nach 1 Minute").tag(60)
                }
                .disabled(!settings.showQuickAccess)
            } header: {
                Text("Karten")
            } footer: {
                Text("Auf der Karte kannst du kopieren, bearbeiten, zensieren, anpinnen oder sie in eine andere App ziehen. Unter der Maus blendet sie sich nie aus.")
                    .settingsFootnote()
            }
            Section("Start") {
                Toggle("Beim Anmelden öffnen", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var conflictTick = 0

    private let groups: [(String, [HotkeyAction])] = [
        ("Bildschirmfotos", [.captureArea, .captureWindow, .captureFullscreen]),
        ("Bildschirmaufnahme", [.toggleRecording]),
        ("Sonstiges", [.pinClipboard]),
    ]

    private var conflicting: [KeyCombo] {
        settings.activeHotkeys.values.filter { SystemShortcuts.conflict(for: $0) != nil }.sorted { $0.keyCode < $1.keyCode }
    }

    var body: some View {
        let _ = conflictTick
        let conflicts = conflicting
        let blockedIDs = Array(Set(SystemShortcuts.conflictingIDs(for: Array(settings.activeHotkeys.values)))
            .union(SystemShortcuts.enabledScreenshotIDs())).sorted()
        Form {
            PaneHeader(pane: .shortcuts)
            if !blockedIDs.isEmpty {
                Section {
                    if !blockedIDs.isEmpty {
                        notice(symbol: "exclamationmark.triangle.fill", color: .yellow,
                               title: conflicts.isEmpty
                                   ? "macOS belegt \(SystemShortcuts.displayList(blockedIDs)) noch selbst"
                                   : "macOS nutzt \(conflicts.map(\.display).joined(separator: ", ")) noch selbst",
                               detail: "Solange das so ist, kommen diese Kürzel nicht bei Knips an — auch nicht beim Festlegen hier. Knips schaltet die macOS-Kürzel für Bildschirmfotos ab; jederzeit rückgängig zu machen.") {
                            Button("Für Knips freimachen") {
                                SystemShortcuts.takeOver(blockedIDs)
                                conflictTick += 1
                            }
                        }
                    }
                }
            } else if SystemShortcuts.hasTakenOver {
                Section {
                    notice(symbol: "checkmark.circle.fill", color: .green,
                           title: "Knips hat die Bildschirmfoto-Kürzel von macOS übernommen",
                           detail: "Die entsprechenden macOS-Kürzel sind abgeschaltet.") {
                        Button("macOS-Kürzel wiederherstellen") {
                            SystemShortcuts.restore()
                            conflictTick += 1
                        }
                    }
                }
            }
            ForEach(groups, id: \.0) { title, actions in
                Section(title) {
                    ForEach(actions) { ShortcutRow(action: $0, settings: settings) }
                }
            }
            Section {
                HStack {
                    Button("Standardwerte wiederherstellen") {
                        HotkeyRecorderState.shared.cancel()
                        settings.hotkeys = AppSettings.defaultHotkeys
                        settings.disabledHotkeys = []
                        HotkeyManager.shared.apply(settings.activeHotkeys)
                        conflictTick += 1
                    }
                    Spacer()
                    Button("Tastaturkurzbefehle von macOS …") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                }
            } footer: {
                Text("Kürzel anklicken und die neue Kombination drücken. ⌫ entfernt das Kürzel, Esc bricht ab. Standard wie bei macOS: ⇧⌘3 ganzer Bildschirm, ⇧⌘4 Bereich (Leertaste: Fenster), ⇧⌘5 Bildschirmaufnahme.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }
}

extension ShortcutsPane {
    fileprivate func notice<Action: View>(symbol: String, color: Color, title: String, detail: String,
                                          @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.vertical, 2)
    }
}

/// Zeile wie in Tastatur → Tastaturkurzbefehle: Häkchen, Titel, rechts das Kürzel.
private struct ShortcutRow: View {
    let action: HotkeyAction
    @ObservedObject var settings: AppSettings
    @ObservedObject private var recorder = HotkeyRecorderState.shared
    @State private var hovering = false

    private var enabled: Binding<Bool> {
        Binding(get: { combo != nil && !settings.disabledHotkeys.contains(action) }, set: { on in
            if on { settings.disabledHotkeys.remove(action) } else { settings.disabledHotkeys.insert(action) }
            HotkeyManager.shared.apply(settings.activeHotkeys)
        })
    }

    private var isRecording: Bool { recorder.recording == action }
    private var combo: KeyCombo? { settings.hotkeys[action] }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(combo == nil)
            Text(action.title)
                .foregroundStyle(enabled.wrappedValue && combo != nil ? .primary : .secondary)
            Spacer()
            if let combo, enabled.wrappedValue, let conflict = SystemShortcuts.conflict(for: combo) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Wird auch von macOS verwendet („\(conflict)“). Dort ausschalten oder ein anderes Kürzel wählen.")
            }
            if enabled.wrappedValue, HotkeyManager.shared.failures.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("Dieses Kürzel ist bereits von einer anderen App belegt.")
            }
            shortcutField
        }
    }

    private var shortcutField: some View {
        Button {
            if isRecording { recorder.cancel() } else { startRecording() }
        } label: {
            Text(isRecording ? "Kürzel eingeben" : (combo?.display ?? "Kein"))
                .font(.system(size: 13, weight: isRecording ? .regular : .medium))
                .foregroundStyle(isRecording ? .secondary : (combo == nil ? .tertiary : (enabled.wrappedValue ? .primary : .secondary)))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .frame(minWidth: 96, minHeight: 22, alignment: .trailing)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isRecording ? Color(nsColor: .textBackgroundColor) : (hovering ? Color.primary.opacity(0.06) : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 2.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Klicken und neue Tastenkombination drücken")
    }

    private func startRecording() {
        recorder.start(action) { result in
            guard let result else { return }
            var keys = settings.hotkeys
            if result.keyCode == UInt32.max {
                keys[action] = nil
            } else {
                // Doppelte Belegung auflösen: das andere Kürzel wird entfernt.
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
    private var micAvailable: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 }

    var body: some View {
        Form {
            PaneHeader(pane: .recording)
            Section("Video") {
                Picker("Bildrate", selection: $settings.recordingFPS) {
                    Text("30 Bilder pro Sekunde").tag(30)
                    Text("60 Bilder pro Sekunde").tag(60)
                }
                Toggle("Mauszeiger aufnehmen", isOn: $settings.recordingShowCursor)
                Toggle("Countdown vor dem Start (3 – 2 – 1)", isOn: $settings.recordingCountdown)
            }
            Section {
                Toggle("Mikrofon aufnehmen", isOn: $settings.recordingMicrophone)
                    .disabled(!micAvailable)
            } header: {
                Text("Ton")
            } footer: {
                Text(micAvailable
                     ? "Für gesprochene Erklärungen. Beim ersten Mal fragt macOS nach der Mikrofon-Freigabe."
                     : "Mikrofon-Aufnahme braucht macOS 15 oder neuer.")
                    .settingsFootnote()
            }
            Section {
                LabeledContent("Stoppen") {
                    Text("Stopp-Leiste, Menüleisten-Symbol oder \(settings.activeHotkeys[.toggleRecording]?.display ?? "Kürzel")")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Format") { Text("MP4 (H.264)").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RedactionPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            PaneHeader(pane: .redaction)
            Section {
                HStack(spacing: 18) {
                    Spacer(minLength: 0)
                    ForEach(RedactStyle.allCases) { style in
                        RedactStyleCard(style: style, selected: settings.redactStyle == style) { settings.redactStyle = style }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            } header: {
                Text("Standardstil")
            } footer: {
                Text("„Balken“ ist am sichersten. Verpixeln und Unschärfe machen normale Schrift unlesbar, lassen aber Länge und grobe Form erkennen. Im Editor: Werkzeug „Zensieren“ (X) wählen und Balken über die Stelle ziehen.")
                    .settingsFootnote()
            }
            Section {
                Toggle("Auto-Zensur-Knopf in den Editoren zeigen", isOn: $settings.showAutoRedact)
            } header: {
                Text("Auto-Zensur")
            } footer: {
                Text("Sucht per Texterkennung nach E-Mails, IBANs, Schlüsseln usw. und legt Balken an. Normalerweise ziehst du Balken selbst — der Knopf ist deshalb aus.")
                    .settingsFootnote()
            }
            if settings.showAutoRedact {
            Section {
                ForEach(SensitiveDetector.Kind.allCases, id: \.self) { kind in
                    Toggle(isOn: Binding(get: { settings.autoRedactKinds.contains(kind) }, set: { on in
                        if on { settings.autoRedactKinds.insert(kind) } else { settings.autoRedactKinds.remove(kind) }
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.longTitle)
                            Text(kind.example).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Auto-Zensur erkennt")
            } footer: {
                Text("Die Texterkennung läuft auf deinem Mac. Vorschläge erscheinen als normale Zensurfelder und lassen sich einzeln löschen.")
                    .settingsFootnote()
            }
            }
        }
        .formStyle(.grouped)
    }
}

/// Auswahlkarte mit Vorschau, wie die Erscheinungsbild-Auswahl in macOS.
private struct RedactStyleCard: View {
    let style: RedactStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(nsImage: RedactPreview.image(for: style))
                    .resizable()
                    .frame(width: 112, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1)
                    )
                    .padding(selected ? 0 : 1)
                Text(style.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Kleine Vorschaubilder für die Stil-Auswahl, mit dem echten Renderer erzeugt.
@MainActor enum RedactPreview {
    private static var cache: [RedactStyle: NSImage] = [:]

    static func image(for style: RedactStyle) -> NSImage {
        if let hit = cache[style] { return hit }
        // Doppelte Größe und Effektmaßstab 1: so zeigt die kleine Vorschau ein erkennbares Mosaik.
        let w = 448, h = 264, scale: CGFloat = 1
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.87, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 44))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: NSColor.black]
        NSAttributedString(string: "Kontakt", attributes: attrs.merging([.font: NSFont.systemFont(ofSize: 40, weight: .bold)]) { $1 })
            .draw(at: CGPoint(x: 32, y: 64))
        NSAttributedString(string: "max@example.com", attributes: attrs).draw(at: CGPoint(x: 32, y: 128))
        NSAttributedString(string: "+49 170 123456", attributes: attrs).draw(at: CGPoint(x: 32, y: 188))
        NSGraphicsContext.restoreGraphicsState()
        let base = ctx.makeImage()!
        var doc = ImageDocument()
        var a = Annotation(kind: .redact, start: CGPoint(x: 24, y: 126), end: CGPoint(x: 424, y: 248))
        a.redactStyle = style
        doc.annotations = [a]
        let rendered = Renderer.render(base: base, document: doc, scale: scale, effects: EffectsCache(base: base, scale: scale)) ?? base
        let image = NSImage(cgImage: rendered, size: NSSize(width: w / 4, height: h / 4))
        cache[style] = image
        return image
    }
}

private struct ExportPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            PaneHeader(pane: .export)
            Section {
                Picker("Bildrate", selection: $settings.gifFPS) {
                    Text("10 Bilder pro Sekunde").tag(10)
                    Text("15 Bilder pro Sekunde").tag(15)
                    Text("20 Bilder pro Sekunde").tag(20)
                    Text("25 Bilder pro Sekunde").tag(25)
                }
                Picker("Maximale Breite", selection: $settings.gifWidth) {
                    Text("640 Pixel").tag(640)
                    Text("800 Pixel").tag(800)
                    Text("960 Pixel").tag(960)
                    Text("1280 Pixel").tag(1280)
                }
            } header: {
                Text("GIF")
            } footer: {
                Text("Kleinere Werte ergeben deutlich kleinere Dateien — gut für Tickets, Slack und GitHub.")
                    .settingsFootnote()
            }
            Section("Video") {
                LabeledContent("Format") { Text("MP4 (H.264), beste Qualität").foregroundStyle(.secondary) }
                LabeledContent("Zensur und Kürzung") { Text("werden beim Speichern eingerechnet").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct StoragePane: View {
    @ObservedObject var settings: AppSettings
    @State private var usage: String = "…"
    @State private var confirmPurge = false

    var body: some View {
        Form {
            PaneHeader(pane: .storage)
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Ändern …") { chooseFolder() }
                        Button("Im Finder zeigen") {
                            try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(settings.saveFolder)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: FileManager.default.fileExists(atPath: settings.saveFolder.path)
                              ? NSWorkspace.shared.icon(forFile: settings.saveFolder.path)
                              : NSWorkspace.shared.icon(for: .folder))
                            .resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(settings.saveFolder.lastPathComponent)
                            Text(settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            } header: {
                Text("Ablageordner")
            } footer: {
                Text("Dort liegt immer die bearbeitete Fassung — zensierte Stellen sind darin endgültig unkenntlich.")
                    .settingsFootnote()
            }
            Section {
                Picker("Originale aufbewahren", selection: $settings.retentionDays) {
                    Text("7 Tage").tag(7)
                    Text("30 Tage").tag(30)
                    Text("90 Tage").tag(90)
                    Text("1 Jahr").tag(365)
                    Text("Unbegrenzt").tag(0)
                }
                LabeledContent("Belegt") { Text(usage).foregroundStyle(.secondary).monospacedDigit() }
                HStack {
                    Spacer()
                    Button("Originale jetzt löschen …", role: .destructive) { confirmPurge = true }
                }
            } header: {
                Text("Originale")
            } footer: {
                Text("Mit dem Original lässt sich eine Zensur später wieder aufheben oder ändern. Es liegt getrennt in der App-Ablage und wird nie geteilt.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshUsage)
        .confirmationDialog("Alle Originale löschen?", isPresented: $confirmPurge) {
            Button("Löschen", role: .destructive) {
                CaptureStore.shared.purgeOriginals()
                refreshUsage()
            }
        } message: {
            Text("Die Dateien im Ablageordner bleiben. Bereits gespeicherte Zensuren lassen sich danach nicht mehr rückgängig machen.")
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
    @State private var screen = ScreenCapture.hasPermission
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            PaneHeader(pane: .privacy)
            Section {
                permissionRow(symbol: "rectangle.dashed.badge.record", color: Color(red: 0.36, green: 0.35, blue: 0.9),
                              title: "Bildschirm- & Systemaudioaufnahme", detail: "Für Screenshots und Videos nötig",
                              granted: screen) {
                    if !CGRequestScreenCaptureAccess() { PermissionWindowController.show() }
                }
                permissionRow(symbol: "mic.fill", color: Color(red: 1, green: 0.58, blue: 0),
                              title: "Mikrofon", detail: "Nur für Aufnahmen mit Kommentar",
                              granted: mic == .authorized, optional: true) {
                    if mic == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            } header: {
                Text("Freigaben")
            }
            Section {
                Label("Texterkennung für die Auto-Zensur läuft auf diesem Mac.", systemImage: "cpu")
                Label("Knips hat keinen Account und sendet nichts ins Internet.", systemImage: "network.slash")
                Label("Geteilte und kopierte Dateien enthalten immer die zensierte Fassung.", systemImage: "checkmark.shield")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            screen = ScreenCapture.hasPermission
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private func permissionRow(symbol: String, color: Color, title: String, detail: String, granted: Bool,
                               optional: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Erlaubt", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                Button(optional ? "Erlauben …" : "Freigabe einrichten …", action: action)
            }
        }
    }
}

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                    Text("Knips").font(.system(size: 22, weight: .bold))
                    Text(version).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Screenshots und kurze Bildschirmaufnahmen — mit Zensur für Bilder und Videos.")
                        .font(.system(size: 12.5))
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            Section {
                LabeledContent("Ablageordner") {
                    Button("Öffnen") { NSWorkspace.shared.open(AppSettings.shared.saveFolder) }
                }
                LabeledContent("Befehle für Raycast & Co.") {
                    Text("knips://area · window · fullscreen · record").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("© 2026 Patrick Birkholz").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }
}

private extension Text {
    func settingsFootnote() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SensitiveDetector.Kind {
    var longTitle: String {
        switch self {
        case .email: "E-Mail-Adressen"
        case .iban: "IBANs"
        case .phone: "Telefonnummern"
        case .card: "Kreditkartennummern"
        case .secret: "API-Schlüssel, Tokens, Passwörter"
        case .ip: "IP-Adressen"
        }
    }

    var example: String {
        switch self {
        case .email: "name@example.com"
        case .iban: "DE89 3704 0044 0532 0130 00 (mit Prüfsumme)"
        case .phone: "+49 170 1234567, 030 1234567"
        case .card: "4111 1111 1111 1111 (mit Luhn-Prüfung)"
        case .secret: "sk_live_…, ghp_…, xoxb-…, AKIA…, JWT, „Passwort: …“"
        case .ip: "192.168.178.1"
        }
    }
}

// MARK: - Kürzel aufnehmen

@MainActor final class HotkeyRecorderState: ObservableObject {
    static let shared = HotkeyRecorderState()
    @Published var recording: HotkeyAction?
    private var monitor: Any?

    /// Liefert die neue Kombination, `keyCode == UInt32.max` für „entfernen“, oder nil bei Abbruch.
    func start(_ action: HotkeyAction, onCombo: @escaping (KeyCombo?) -> Void) {
        cancel()
        recording = action
        // Solange aufgenommen wird, dürfen die alten Kürzel nicht auslösen.
        HotkeyManager.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.finish(); onCombo(nil); return nil }
            if event.keyCode == 51 || event.keyCode == 117, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                self.finish()
                onCombo(KeyCombo(keyCode: UInt32.max, modifiers: 0))
                return nil
            }
            guard let combo = KeyCombo(event: event) else { NSSound.beep(); return nil }
            self.finish()
            onCombo(combo)
            return nil
        }
    }

    func cancel() {
        if recording != nil { finish() }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        HotkeyManager.shared.apply(AppSettings.shared.activeHotkeys)
    }
}
