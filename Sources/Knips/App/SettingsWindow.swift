import AppKit
import AVFoundation
import SwiftUI

/// Einstellungen in der Markensprache (docs/design.md): dunkle Seitenleiste über die volle Höhe (Zeichen, Wortmarke,
/// Gruppen, Status unten), rechts Papier mit Seitentitel, Abschnitten und weißen Karten.
@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: SettingsWindowController?
    static let size = NSSize(width: 920, height: 700)
    /// Bei DockPresence angemeldet (zwischen Öffnen und Schließen) — erneutes Öffnen zählt nicht doppelt.
    private var inDock = false

    /// Fenster unsichtbar anlegen, damit das erste Öffnen nicht hängt.
    static func prewarm() {
        if instance == nil {
            instance = SettingsWindowController()
            instance?.window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Ohne Bereich: der zuletzt gezeigte — oder „Start“, solange im Bereit-Check noch etwas fehlt.
    static func show(_ pane: SettingsPane? = nil) {
        Telemetry.count(.settingsOpen)
        if instance == nil { instance = SettingsWindowController() }
        Readiness.shared.refresh()
        if let pane {
            SettingsNavigation.shared.pane = pane
        } else if Readiness.shared.missing > 0 {
            SettingsNavigation.shared.pane = .start
        }
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
        // Keine feste Darstellung: das Fenster folgt `NSApp.appearance` (Einstellung „Darstellung“).
        window.backgroundColor = Brand.canvas
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Self.size.width, height: 640)
        window.contentMaxSize = NSSize(width: Self.size.width, height: 1400)
        window.contentView = NSHostingView(rootView: SettingsRoot(settings: AppSettings.shared, nav: SettingsNavigation.shared,
                                                                  readiness: Readiness.shared))
        // Fensterposition merkt sich AppKit in der echten Domäne — Selbsttests legen das Fenster neben den Bildschirm.
        let autosave = Paths.testRoot == nil
        if autosave { window.setFrameAutosaveName("KnipsSettings3") }
        super.init(window: window)
        window.delegate = self
        if !autosave || !window.setFrameUsingName("KnipsSettings3") { window.center() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// Zurück aus den Systemeinstellungen: Freigaben, Kürzel und Ordner neu prüfen.
    func windowDidBecomeKey(_ notification: Notification) { Readiness.shared.refresh() }

    func windowWillClose(_ notification: Notification) {
        HotkeyRecorderState.shared.cancel()
        if inDock {
            inDock = false
            DockPresence.windowClosed()
        }
    }
}

@MainActor final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var pane: SettingsPane = SettingsPane(rawValue: UserDefaults.knips.string(forKey: "settingsPane") ?? "") ?? .start {
        didSet { UserDefaults.knips.set(pane.rawValue, forKey: "settingsPane") }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case start, general, shortcuts, recording, redaction, export, storage, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: "Start"
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

    /// Überschrift der Seite (die Startseite heißt wie in der App-Familie „So geht's“).
    var pageTitle: String { self == .start ? "So geht's" : title }

    var symbol: String {
        switch self {
        case .start: "house"
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
        case .start: "Knips nimmt Bereich, Fenster oder Bildschirm auf und macht sensible Stellen unkenntlich, bevor du teilst."
        case .general: "Was nach einer Aufnahme passiert, die Karten unten links und wie Knips aussieht."
        case .shortcuts: "Globale Kürzel für Screenshots und Aufnahmen. Sie funktionieren in jeder App."
        case .recording: "Größe, Format und Darstellung deiner Bildschirmvideos."
        case .redaction: "Wie sensible Stellen in Bildern und Videos unkenntlich werden."
        case .export: "Größe und Format von Screenshots, GIFs und Videos."
        case .storage: "Wo deine Aufnahmen liegen und wie lange Originale bleiben."
        case .privacy: "Freigaben von macOS und anonyme Nutzungsstatistik. Aufnahmen bleiben auf deinem Mac."
        case .about: "Screenshots und kurze Bildschirmaufnahmen, mit Zensur für Bilder und Videos."
        }
    }
}

/// Gruppen der Seitenleiste (Mono-Überschrift in Versalien).
enum SettingsGroup: CaseIterable, Identifiable {
    case start, capture, edit, app

    var id: Self { self }

    var title: String {
        switch self {
        case .start: "Start"
        case .capture: "Aufnahme"
        case .edit: "Bearbeiten"
        case .app: "App"
        }
    }

    var panes: [SettingsPane] {
        switch self {
        case .start: [.start]
        case .capture: [.general, .shortcuts, .recording]
        case .edit: [.redaction, .export]
        case .app: [.storage, .privacy, .about]
        }
    }
}

enum AppVersion {
    static var short: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }
}

// MARK: - Gerüst

struct SettingsRoot: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject var readiness: Readiness

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(nav: nav, readiness: readiness)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(nav.pane.pageTitle)
                            .font(Brand.font(28, .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(Color.brand(Brand.ink))
                        Text(nav.pane.summary)
                            .font(Brand.font(14))
                            .foregroundStyle(Color.brand(Brand.inkSoft))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    detail
                }
                .padding(.horizontal, 32)
                .padding(.top, 44)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .id(nav.pane)   // neue Seite beginnt oben
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brand(Brand.canvas))
        .ignoresSafeArea()
        .tint(Color.brand(Brand.accent))
    }

    @ViewBuilder private var detail: some View {
        switch nav.pane {
        case .start: StartPane(settings: settings, readiness: readiness) { nav.pane = $0 }
        case .general: GeneralPane(settings: settings)
        case .shortcuts: ShortcutsPane(settings: settings, readiness: readiness)
        case .recording: RecordingPane(settings: settings, readiness: readiness)
        case .redaction: RedactionPane(settings: settings)
        case .export: ExportPane(settings: settings)
        case .storage: StoragePane(settings: settings, readiness: readiness)
        case .privacy: PrivacyPane(readiness: readiness)
        case .about: AboutPane()
        }
    }
}

/// Dunkle Seitenleiste über die volle Fensterhöhe (die Fensterknöpfe sitzen oben darauf).
private struct SettingsSidebar: View {
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject var readiness: Readiness
    @State private var hovered: SettingsPane?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandMark(size: 26)
                Wordmark(size: 22)
            }
            .padding(.leading, 10)
            .padding(.top, 52)
            .padding(.bottom, 14)
            ForEach(SettingsGroup.allCases) { group in
                BrandOverline(group.title, color: Brand.Side.muted)
                    .padding(.leading, 10)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                ForEach(group.panes) { row($0) }
            }
            Spacer(minLength: 16)
            Button { nav.pane = .start } label: {
                VStack(alignment: .leading, spacing: 6) {
                    BrandStatusDot(ok: readiness.missing == 0, text: readiness.summary, ink: Brand.Side.ink,
                                   green: successOnDark, red: Brand.Dark.record)
                    Text("Version \(AppVersion.short) · \(AppVersion.build)")
                        .font(Brand.mono(11))
                        .foregroundStyle(Color.brand(Brand.Side.muted))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(readiness.missing == 0 ? "Alles eingerichtet" : "Zum Bereit-Check")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 14)
        .frame(width: 216)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.brand(Brand.Side.fill))
    }

    /// Grün für „erledigt“ auf der immer dunklen Seitenleiste (wie `Brand.success` im Dunkeln).
    private var successOnDark: NSColor { Brand.success.resolved(dark: true) }

    private func row(_ pane: SettingsPane) -> some View {
        let selected = nav.pane == pane
        let open = pane == .start ? readiness.missing : 0
        return Button { nav.pane = pane } label: {
            HStack(spacing: 9) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(pane.title)
                    .font(Brand.font(13, selected ? .medium : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if open > 0 {
                    Text("\(open)")
                        .font(Brand.mono(10.5, .semibold))
                        .foregroundStyle(Color.brand(Brand.Dark.record))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Color.brand(Brand.Dark.record).opacity(0.16)))
                        .accessibilityLabel("\(open) offen")
                } else if selected {
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(Color.brand(selected || hovered == pane ? Brand.Side.ink : Brand.Side.muted))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.brand(Brand.Side.raised).opacity(selected ? 1 : (hovered == pane ? 0.55 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? pane : (hovered == pane ? nil : hovered) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension NSColor {
    /// Dynamische Farbe in einer festen Darstellung auflösen (für immer dunkle Flächen).
    func resolved(dark: Bool) -> NSColor {
        var result = self
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            result = NSColor(cgColor: self.cgColor) ?? self
        }
        return result
    }
}

// MARK: - Bausteine der Seiten

/// Zeile im Bereit-Check: Zustand, Titel, Beschreibung, Knopf rechts.
private struct CheckRow<Accessory: View>: View {
    let tone: BrandCheckTone
    let title: String
    let detail: Text
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            BrandStatusIcon(tone: tone)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.font(14, .medium)).foregroundStyle(Color.brand(Brand.ink))
                detail
                    .font(Brand.font(12.5))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.vertical, 14)
        .frame(minHeight: 62)
    }
}

/// Kürzel im Fließtext in Mono („macOS belegt ⇧⌘3, ⇧⌘4 …“).
private func keysText(_ combos: [KeyCombo], size: CGFloat = 12.5) -> Text {
    combos.enumerated().reduce(Text("")) { text, entry in
        text + Text(entry.offset == 0 ? "" : ", ") + entry.element.inlineText(size: size)
    }
}

/// Infozeile mit Icon-Kachel.
private struct InfoLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            BrandIconTile(symbol: symbol, size: 28)
            Text(text)
                .font(Brand.font(13.5))
                .foregroundStyle(Color.brand(Brand.ink))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }
}

/// Zahl frei eintippen oder mit den Pfeilen ändern. Übernimmt jede gültige Eingabe sofort,
/// beim Verlassen des Felds wird eine ungültige auf den letzten Wert zurückgesetzt.
private struct SecondsField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Brand.mono(13.5, .medium))
                    .foregroundStyle(Color.brand(Brand.ink))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .frame(width: 54)
                    .onSubmit(normalize)
                    .onChange(of: text) { _, new in
                        if let n = Int(new.filter(\.isNumber)), range.contains(n), n != value { value = n }
                    }
                    .onChange(of: focused) { _, isFocused in if !isFocused { normalize() } }
                Rectangle().fill(Color.brand(Brand.line)).frame(width: 1)
                VStack(spacing: 0) {
                    step("chevron.up", +1)
                    Rectangle().fill(Color.brand(Brand.line)).frame(height: 1)
                    step("chevron.down", -1)
                }
                .frame(width: 24)
            }
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous).fill(Color.brand(Brand.surfaceRaised)))
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                .strokeBorder(Color.brand(focused ? Brand.accent : Brand.line)))
            .background(RoundedRectangle(cornerRadius: Brand.Radius.field + 3, style: .continuous)
                .stroke(Color.brand(Brand.accentSoft), lineWidth: focused ? 3 : 0).padding(-1.5))
            Text(value == 1 ? "Sekunde" : "Sekunden")
                .font(Brand.font(13))
                .foregroundStyle(Color.brand(Brand.inkSoft))
                .frame(width: 62, alignment: .leading)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, new in if Int(text) != new { text = "\(new)" } }
    }

    private func step(_ symbol: String, _ delta: Int) -> some View {
        Button { value = (value + delta).clamped(to: range) } label: {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.brand(Brand.inkMuted))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta > 0 ? "Mehr" : "Weniger")
    }

    private func normalize() {
        if let n = Int(text.filter(\.isNumber)) { value = n.clamped(to: range) }
        text = "\(value)"
    }
}

/// Zeitgeber für Seiten mit Freigaben: Freigaben in den Systemeinstellungen ändern sich, ohne dass Knips es erfährt.
private let readinessTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

// MARK: - Start

private struct StartPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var readiness: Readiness
    let open: (SettingsPane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if readiness.missing > 0 {
                check
                howTo
            } else {
                howTo
                check
            }
        }
        .onAppear { readiness.refresh() }
        .onReceive(readinessTimer) { _ in readiness.refresh() }
    }

    // MARK: So geht's

    private static let shortcuts: [(HotkeyAction, String)] = [
        (.captureArea, "Bereich"), (.captureFullscreen, "Bildschirm"), (.captureWindow, "Fenster"), (.toggleRecording, "Video"),
    ]

    private static let steps: [(String, String)] = [
        ("Aufnehmen", "Kürzel drücken, Bereich ziehen. Leertaste wählt ein Fenster."),
        ("Zensieren", "Balken über Namen, E-Mails oder Schlüssel ziehen."),
        ("Teilen", "Kopieren oder die Karte in eine App ziehen."),
    ]

    private var howTo: some View {
        BrandCard {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Deine Kürzel").font(Brand.font(14, .semibold)).foregroundStyle(Color.brand(Brand.ink))
                    Text("Funktionieren in jeder App, ohne Knips zu öffnen.")
                        .font(Brand.font(12.5)).foregroundStyle(Color.brand(Brand.inkSoft))
                }
                Spacer(minLength: 8)
                Button("Ändern") { open(.shortcuts) }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, compact: true))
            }
            .padding(.top, 20)
            HStack(alignment: .top, spacing: 8) {
                ForEach(Self.shortcuts, id: \.0) { action, label in
                    VStack(spacing: 10) {
                        BrandKeys(combo: settings.activeHotkeys[action], large: true)
                            .frame(height: 36)
                        Text(label).font(Brand.font(12.5, .medium)).foregroundStyle(Color.brand(Brand.inkMuted))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 20)
            BrandRowDivider().padding(.top, 20)
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    StepTile(number: index + 1, title: step.0, text: step.1)
                }
            }
            .padding(.vertical, 20)
        }
    }

    // MARK: Bereit-Check

    private var checkTitle: String {
        switch readiness.missing {
        case 0: "Alles bereit"
        case 1: "Noch ein Schritt"
        default: "Noch \(readiness.missing) Schritte"
        }
    }

    private var check: some View {
        let state = readiness.state
        return VStack(alignment: .leading, spacing: 0) {
            Text(checkTitle)
                .font(Brand.font(17, .semibold))
                .foregroundStyle(Color.brand(Brand.ink))
                .padding(.bottom, 10)
            BrandCard {
                ScreenCheckRow(granted: state.screen, readiness: readiness)
                BrandRowDivider()
                MicrophoneCheckRow(state: state, readiness: readiness)
                BrandRowDivider()
                hotkeyRow(state.hotkeys)
                BrandRowDivider()
                folderRow(state.folderReachable)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Änderst du etwas in den Systemeinstellungen, prüft Knips neu, sobald du hierher zurückkommst.")
                    .font(Brand.font(12.5))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Neu prüfen") { readiness.refresh() }
                    .buttonStyle(BrandButtonStyle(kind: .quiet, compact: true))
            }
            .padding(.top, 8)
            .padding(.leading, 4)
        }
    }

    @ViewBuilder private func hotkeyRow(_ hotkeys: Readiness.Hotkeys) -> some View {
        switch hotkeys {
        case .ok:
            CheckRow(tone: .done, title: "Kürzel aktiv", detail: Text("Knips bekommt deine Kürzel in jeder App.")) { EmptyView() }
        case .none:
            CheckRow(tone: .missing, title: "Kürzel aktiv", detail: Text("Kein Kürzel eingeschaltet.")) {
                Button("Festlegen") { open(.shortcuts) }.buttonStyle(BrandButtonStyle(kind: .primary, compact: true))
            }
        case let .system(combos, ids):
            CheckRow(tone: .missing, title: "Kürzel aktiv",
                     detail: Text("macOS belegt ") + keysText(combos) + Text(" noch für eigene Bildschirmfotos. Knips schaltet sie ab, jederzeit rückgängig.")) {
                Button("Freimachen") { readiness.freeSystemShortcuts(ids) }
                    .buttonStyle(BrandButtonStyle(kind: .primary, compact: true))
            }
        case let .taken(combos):
            CheckRow(tone: .missing, title: "Kürzel aktiv",
                     detail: keysText(combos) + Text(combos.count == 1 ? " ist schon von einer anderen App belegt." : " sind schon von anderen Apps belegt.")) {
                Button("Ändern") { open(.shortcuts) }.buttonStyle(BrandButtonStyle(kind: .primary, compact: true))
            }
        }
    }

    private func folderRow(_ reachable: Bool) -> some View {
        let path = settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return CheckRow(tone: reachable ? .done : .missing, title: "Ablageordner erreichbar",
                        detail: Text(reachable ? path : "„\(path)“ ist nicht erreichbar. Bis dahin landen Aufnahmen in Bilder/Knips.")) {
            if !reachable {
                Button("Ordner wählen") { readiness.chooseFolder() }.buttonStyle(BrandButtonStyle(kind: .primary, compact: true))
            }
        }
    }
}

/// Schritt in heller Kachel mit Königsblau-Nummer.
private struct StepTile: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(Brand.mono(11, .semibold))
                    .foregroundStyle(Color.brand(Brand.onAccent))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.brand(Brand.accent)))
                Text(title).font(Brand.font(13.5, .semibold)).foregroundStyle(Color.brand(Brand.ink))
            }
            Text(text)
                .font(Brand.font(12))
                .foregroundStyle(Color.brand(Brand.inkSoft))
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.brand(Brand.canvas)))
    }
}

/// Bildschirmaufnahme-Freigabe (Start und Datenschutz).
private struct ScreenCheckRow: View {
    let granted: Bool
    let readiness: Readiness

    var body: some View {
        CheckRow(tone: granted ? .done : .missing, title: "Bildschirm aufnehmen (Bildschirmaufnahme-Freigabe)",
                 detail: Text(granted ? "Erlaubt. Für Screenshots und Videos nötig."
                                      : "Ohne Freigabe sieht Knips nur den Schreibtisch. Nach dem Erlauben Knips neu starten.")) {
            if !granted {
                Button("Erlauben") { readiness.requestScreen() }.buttonStyle(BrandButtonStyle(kind: .primary, compact: true))
            }
        }
    }
}

/// Mikrofon — freiwillig, nur für Videos mit Ton (Start und Datenschutz).
private struct MicrophoneCheckRow: View {
    let state: Readiness.State
    let readiness: Readiness

    private var detail: String {
        switch state.microphoneTone {
        case .done: "Erlaubt. Videos können deine Stimme mit aufnehmen."
        case .missing: "„Mikrofon aufnehmen“ ist an, aber Knips darf noch nicht zuhören."
        case .optional: "Freiwillig, nur für Videos mit Ton."
        }
    }

    var body: some View {
        CheckRow(tone: state.microphoneTone, title: "Mikrofon", detail: Text(detail)) {
            if state.microphoneTone != .done {
                Button("Erlauben") { readiness.requestMicrophone() }
                    .buttonStyle(BrandButtonStyle(kind: state.microphoneTone == .missing ? .primary : .secondary, compact: true))
            }
        }
    }
}

// MARK: - Allgemein

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            BrandSection(title: "Nach einer Aufnahme") {
                BrandRow(title: "In die Zwischenablage kopieren", detail: "Gleich einfügen, ohne Umweg über eine Datei.") {
                    BrandToggle(isOn: $settings.copyToClipboard, label: "In die Zwischenablage kopieren")
                }
                BrandRowDivider()
                BrandRow(title: "Editor sofort öffnen", detail: "Sonst erscheint die Aufnahme als Karte unten links.") {
                    BrandToggle(isOn: $settings.openEditorAfterCapture, label: "Editor sofort öffnen")
                }
                BrandRowDivider()
                BrandRow(title: "Auslöser-Ton") { BrandToggle(isOn: $settings.playSound, label: "Auslöser-Ton") }
            }
            BrandSection(title: "Karten unten links",
                         footer: "Ein Klick auf die Karte öffnet die Aufnahme. Über die Knöpfe darauf kopierst du, pinnst an oder kopierst den Text, und du kannst die Karte in eine andere App ziehen. Solange die Maus darauf liegt, bleibt sie stehen.") {
                BrandRow(title: "Karte anzeigen") { BrandToggle(isOn: $settings.showQuickAccess, label: "Karte anzeigen") }
                BrandRowDivider()
                BrandRow(title: "Automatisch ausblenden") {
                    BrandToggle(isOn: $settings.quickAccessAutoHide, label: "Automatisch ausblenden").disabled(!settings.showQuickAccess)
                }
                BrandRowDivider()
                let timed = settings.showQuickAccess && settings.quickAccessAutoHide
                BrandRow(title: "Anzeigedauer", detail: timed ? "So lange bleibt die Karte stehen." : "Die Karte bleibt, bis du sie schließt.") {
                    SecondsField(value: $settings.quickAccessSeconds, range: AppSettings.quickAccessSecondsRange)
                }
                .disabled(!timed)
            }
            BrandSection(title: "Darstellung und Start") {
                BrandRow(title: "Darstellung", detail: "Gilt für alle Fenster. Menü, Leisten und Karten-Knöpfe bleiben dunkel.") {
                    BrandSegmented(selection: $settings.appearance, options: AppearanceMode.allCases.map { ($0, $0.title) })
                }
                BrandRowDivider()
                BrandRow(title: "Beim Anmelden öffnen", detail: "Knips startet still in der Menüleiste.") {
                    BrandToggle(isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }),
                                label: "Beim Anmelden öffnen")
                }
            }
        }
    }
}

// MARK: - Tastaturkürzel

private struct ShortcutsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var readiness: Readiness
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
        VStack(alignment: .leading, spacing: 30) {
            if !blockedIDs.isEmpty {
                notice(tone: .missing,
                       title: conflicts.isEmpty ? Text("macOS belegt ") + Text(SystemShortcuts.displayList(blockedIDs)) + Text(" noch selbst")
                                                : Text("macOS nutzt ") + keysText(conflicts, size: 14) + Text(" noch selbst"),
                       detail: "Solange das so ist, kommen diese Kürzel nicht bei Knips an, auch nicht beim Festlegen hier. Knips schaltet die macOS-Kürzel für Bildschirmfotos ab, jederzeit rückgängig zu machen.") {
                    Button("Für Knips freimachen") {
                        SystemShortcuts.takeOver(blockedIDs)
                        HotkeyManager.shared.apply(settings.activeHotkeys)
                        readiness.refresh()
                        tick += 1
                    }
                    .buttonStyle(BrandButtonStyle(kind: .primary, compact: true))
                }
            } else if SystemShortcuts.hasTakenOver {
                notice(tone: .done, title: Text("Knips hat die Bildschirmfoto-Kürzel übernommen"),
                       detail: "Die entsprechenden macOS-Kürzel sind abgeschaltet.") {
                    Button("macOS-Kürzel wiederherstellen") {
                        SystemShortcuts.restore()
                        readiness.refresh()
                        tick += 1
                    }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, compact: true))
                }
            }
            ForEach(groups, id: \.0) { title, actions in
                BrandSection(title: title) {
                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        if index > 0 { BrandRowDivider() }
                        ShortcutRow(action: action, settings: settings)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("Standardwerte wiederherstellen") {
                        HotkeyRecorderState.shared.cancel()
                        settings.hotkeys = AppSettings.defaultHotkeys
                        settings.disabledHotkeys = []
                        HotkeyManager.shared.apply(settings.activeHotkeys)
                        readiness.refresh()
                        tick += 1
                    }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
                    Button("Kurzbefehle von macOS …") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    .buttonStyle(BrandButtonStyle(kind: .quiet))
                }
                (Text("Kürzel anklicken und die neue Kombination drücken. ") + Text(Image(systemName: "delete.left"))
                 + Text(" entfernt, ") + Text("Esc").font(Brand.mono(12)) + Text(" bricht ab. Standard wie bei macOS: ")
                 + defaultKeys(.captureFullscreen) + Text(" Bildschirm, ") + defaultKeys(.captureArea)
                 + Text(" Bereich (Leertaste: Fenster), ") + defaultKeys(.toggleRecording) + Text(" Video."))
                    .font(Brand.font(12.5))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func defaultKeys(_ action: HotkeyAction) -> Text {
        action.defaultCombo.map { $0.inlineText(size: 12) } ?? Text("")
    }

    private func notice<Action: View>(tone: BrandCheckTone, title: Text, detail: String, @ViewBuilder action: () -> Action) -> some View {
        BrandCard {
            HStack(alignment: .top, spacing: 14) {
                BrandStatusIcon(tone: tone)
                VStack(alignment: .leading, spacing: 4) {
                    title.font(Brand.font(14, .semibold)).foregroundStyle(Color.brand(Brand.ink))
                    Text(detail)
                        .font(Brand.font(12.5))
                        .foregroundStyle(Color.brand(Brand.inkSoft))
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                    action().padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 18)
        }
    }
}

/// Titel links; rechts das Kürzel als Tastenkappen (Klick nimmt ein neues auf) und der Schalter.
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
            Readiness.shared.refresh()
        })
    }

    private var warning: String? {
        guard let combo, enabled.wrappedValue else { return nil }
        if let conflict = SystemShortcuts.conflict(for: combo) { return "macOS nutzt das Kürzel auch („\(conflict)“)" }
        if HotkeyManager.shared.failures.contains(action) { return "Schon von einer anderen App belegt" }
        return nil
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                    .font(Brand.font(14, .medium))
                    .foregroundStyle(Color.brand(enabled.wrappedValue ? Brand.ink : Brand.inkSoft))
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(Brand.font(12))
                        .foregroundStyle(Color.brand(Brand.warn))
                        .labelStyle(.titleAndIcon)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if isRecording { recorder.cancel() } else { record() }
            } label: {
                Group {
                    if isRecording {
                        Text("Kürzel drücken …").font(Brand.font(12.5, .medium)).foregroundStyle(Color.brand(Brand.accent))
                    } else if let combo {
                        BrandKeys(combo: combo).opacity(enabled.wrappedValue ? 1 : 0.5)
                    } else {
                        Text("Kein Kürzel").font(Brand.font(12.5)).foregroundStyle(Color.brand(Brand.inkSoft))
                    }
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 118, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                    .fill(Color.brand(isRecording ? Brand.accentSoft : (hovering ? Brand.fill : Brand.surfaceRaised))))
                .overlay(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                    .strokeBorder(Color.brand(isRecording ? Brand.accent : Brand.line), lineWidth: isRecording ? 1.5 : 1))
                .background(RoundedRectangle(cornerRadius: Brand.Radius.field + 3, style: .continuous)
                    .stroke(Color.brand(Brand.accentSoft), lineWidth: isRecording ? 3 : 0).padding(-1.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Klicken und neue Tastenkombination drücken")
            BrandToggle(isOn: enabled, label: action.title).disabled(combo == nil)
        }
        .padding(.vertical, 12)
        .frame(minHeight: 60)
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
            Readiness.shared.refresh()
        }
    }
}

// MARK: - Bildschirmaufnahme

private struct RecordingPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var readiness: Readiness
    private var modern: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            BrandSection(title: "Video",
                         footer: "Gemessen am Vollbild je 4 Sekunden: Retina-H.264 2,2 MB · 1×-H.264 1,2 MB · 1×-HEVC 0,9 MB. HEVC spielt jeder Mac ab, Windows nicht immer.") {
                BrandRow(title: "Größe") {
                    BrandSelect(selection: $settings.recordingAtScreenSize,
                                options: [(true, "Bildschirmgröße (1×)"), (false, "Retina (2×)")], minWidth: 220)
                }
                BrandRowDivider()
                BrandRow(title: "Format") {
                    BrandSelect(selection: $settings.recordingHEVC,
                                options: [(false, "H.264 – überall abspielbar"), (true, "HEVC – kleiner")], minWidth: 220)
                }
                BrandRowDivider()
                BrandRow(title: "Bildrate") {
                    BrandSegmented(selection: $settings.recordingFPS, options: [(30, "30 fps"), (60, "60 fps")])
                }
            }
            BrandSection(title: "Im Video") {
                BrandRow(title: "Mauszeiger aufnehmen") {
                    BrandToggle(isOn: $settings.recordingShowCursor, label: "Mauszeiger aufnehmen")
                }
                BrandRowDivider()
                BrandRow(title: "Mausklicks hervorheben", detail: modern ? "Ein Kreis zeigt, wo du klickst." : "Braucht macOS 15.") {
                    BrandToggle(isOn: $settings.recordingShowClicks, label: "Mausklicks hervorheben").disabled(!modern)
                }
                BrandRowDivider()
                BrandRow(title: "Countdown 3 – 2 – 1") {
                    BrandToggle(isOn: $settings.recordingCountdown, label: "Countdown")
                }
            }
            BrandSection(title: "Ton", footer: "Für gesprochene Erklärungen. Beim ersten Mal fragt macOS nach dem Mikrofon.") {
                BrandRow(title: "Mikrofon aufnehmen", detail: modern ? microphoneDetail : "Braucht macOS 15.") {
                    BrandToggle(isOn: Binding(get: { settings.recordingMicrophone }, set: {
                        settings.recordingMicrophone = $0
                        readiness.refresh()
                    }), label: "Mikrofon aufnehmen").disabled(!modern)
                }
            }
            BrandSection(title: "Stoppen") {
                BrandRow(title: "Stopp-Leiste, Menüleisten-Symbol oder Kürzel") {
                    BrandKeys(combo: settings.activeHotkeys[.toggleRecording])
                }
            }
        }
    }

    private var microphoneDetail: String {
        switch readiness.state.microphone {
        case .authorized: "Mikrofon ist erlaubt."
        case .denied, .restricted: "Mikrofon ist in den Systemeinstellungen gesperrt."
        default: "Fragt beim ersten Video mit Ton nach dem Mikrofon."
        }
    }
}

// MARK: - Zensur

private struct RedactionPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            BrandSection(title: "Standardstil",
                         footer: "„Balken“ ist am sichersten. Im Editor: Klick auf Text legt einen Balken über die Zeile, ⌥-Klick über ein Wort; gezogene Balken wachsen auf ganze Wörter.") {
                HStack(spacing: 16) {
                    ForEach(RedactStyle.allCases) { style in
                        RedactStyleCard(style: style, selected: settings.redactStyle == style) { settings.redactStyle = style }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 20)
            }
            BrandSection(title: "Auto-Zensur",
                         footer: "Sucht per Texterkennung nach E-Mails, IBANs, Schlüsseln usw. und legt Balken an. Normalerweise ziehst du Balken selbst, der Knopf ist deshalb aus.") {
                BrandRow(title: "Knopf „Auto-Zensur“ in den Editoren") {
                    BrandToggle(isOn: $settings.showAutoRedact, label: "Knopf Auto-Zensur")
                }
                if settings.showAutoRedact {
                    ForEach(SensitiveDetector.Kind.allCases, id: \.self) { kind in
                        BrandRowDivider()
                        BrandRow(title: kind.longTitle, detail: kind.example) {
                            BrandToggle(isOn: Binding(get: { settings.autoRedactKinds.contains(kind) }, set: { on in
                                if on { settings.autoRedactKinds.insert(kind) } else { settings.autoRedactKinds.remove(kind) }
                            }), label: kind.longTitle)
                        }
                    }
                }
            }
        }
    }
}

/// Auswahlkarte mit Vorschau; die gewählte trägt einen Königsblau-Rahmen.
private struct RedactStyleCard: View {
    let style: RedactStyle
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(nsImage: RedactPreview.image(for: style))
                    .resizable()
                    .frame(width: 120, height: 71)
                    .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                        .strokeBorder(Color.brand(selected ? Brand.accent : (hovering ? Brand.lineStrong : Brand.line)),
                                      lineWidth: selected ? 2 : 1))
                    .background(RoundedRectangle(cornerRadius: Brand.Radius.field + 3, style: .continuous)
                        .stroke(Color.brand(Brand.accentSoft), lineWidth: selected ? 4 : 0).padding(-2))
                Text(style.title)
                    .font(Brand.font(12.5, selected ? .semibold : .regular))
                    .foregroundStyle(Color.brand(selected ? Brand.ink : Brand.inkSoft))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Export

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
        VStack(alignment: .leading, spacing: 30) {
            BrandSection(title: "Screenshots",
                         footer: "Bildschirmgröße: so groß wie auf dem Bildschirm, beim Einfügen nicht doppelt so groß. Das Original bleibt für spätere Bearbeitung in voller Auflösung.") {
                BrandRow(title: "Größe") {
                    BrandSelect(selection: $settings.exportAtScreenSize,
                                options: [(true, "Bildschirmgröße (1×)"), (false, "Retina (2×)")], minWidth: 220)
                }
                BrandRowDivider()
                BrandRow(title: "Format") {
                    BrandSelect(selection: $settings.imageFormat, options: ImageFormat.allCases.map { ($0, $0.title) }, minWidth: 220)
                }
                BrandRowDivider()
                BrandRow(title: "Vollbild-Screenshot", detail: "Ungefähre Dateigröße") {
                    Text(sizeHint).font(Brand.mono(12.5)).foregroundStyle(Color.brand(Brand.inkMuted))
                }
            }
            BrandSection(title: "GIF", footer: "Ruhige Stellen werden zusammengefasst, das hält GIFs klein.") {
                BrandRow(title: "Bildrate") {
                    BrandSegmented(selection: $settings.gifFPS, options: [(10, "10 fps"), (15, "15 fps"), (20, "20 fps"), (25, "25 fps")])
                }
                BrandRowDivider()
                BrandRow(title: "Maximale Breite") {
                    BrandSelect(selection: $settings.gifWidth,
                                options: [(640, "640 px"), (800, "800 px"), (960, "960 px"), (1280, "1280 px")], minWidth: 130)
                }
            }
            BrandSection(title: "Video") {
                BrandRow(title: "Zensur und Kürzung", detail: "Werden beim Speichern eingerechnet, das Format bleibt erhalten.") { EmptyView() }
            }
        }
    }
}

// MARK: - Ablage

private struct StoragePane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var readiness: Readiness
    @State private var usage = "…"
    @State private var confirmPurge = false

    var body: some View {
        let reachable = readiness.state.folderReachable
        VStack(alignment: .leading, spacing: 30) {
            BrandSection(title: "Ablageordner", footer: "Dort liegt immer die bearbeitete Fassung, zensierte Stellen sind darin endgültig unkenntlich.") {
                HStack(spacing: 14) {
                    BrandIconTile(symbol: "folder", size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(settings.saveFolder.lastPathComponent)
                            .font(Brand.font(14, .medium))
                            .foregroundStyle(Color.brand(Brand.ink))
                        Text(reachable ? settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                                       : "Nicht erreichbar. Bis dahin landen Aufnahmen in Bilder/Knips.")
                            .font(Brand.font(12.5))
                            .foregroundStyle(Color.brand(reachable ? Brand.inkSoft : Brand.warn))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Ändern …") { readiness.chooseFolder() }
                        .buttonStyle(BrandButtonStyle(kind: .secondary, compact: true))
                    Button("Öffnen") {
                        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(settings.saveFolder)
                        readiness.refresh()
                    }
                    .buttonStyle(BrandButtonStyle(kind: .primary, compact: true))
                }
                .padding(.vertical, 16)
            }
            BrandSection(title: "Originale", footer: "Mit dem Original lässt sich eine Zensur später ändern. Es liegt getrennt in der App-Ablage und wird nie geteilt.") {
                BrandRow(title: "Aufbewahren") {
                    BrandSelect(selection: $settings.retentionDays,
                                options: [(7, "7 Tage"), (30, "30 Tage"), (90, "90 Tage"), (365, "1 Jahr"), (0, "Unbegrenzt")], minWidth: 150)
                }
                BrandRowDivider()
                BrandRow(title: "Belegt") {
                    Text(usage).font(Brand.mono(12.5)).foregroundStyle(Color.brand(Brand.inkMuted))
                }
                BrandRowDivider()
                BrandRow(title: "Alle Originale löschen", detail: "Dateien im Ablageordner bleiben.") {
                    Button("Löschen …") { confirmPurge = true }.buttonStyle(BrandButtonStyle(kind: .secondary, compact: true))
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
}

// MARK: - Datenschutz

private struct PrivacyPane: View {
    @ObservedObject private var telemetry = Telemetry.shared
    @ObservedObject var readiness: Readiness

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            BrandSection(title: "Freigaben", detail: "macOS fragt nach, bevor Knips den Bildschirm oder das Mikrofon nutzen darf.") {
                ScreenCheckRow(granted: readiness.state.screen, readiness: readiness)
                BrandRowDivider()
                MicrophoneCheckRow(state: readiness.state, readiness: readiness)
            }
            BrandSection(title: "Nutzungsstatistik",
                         footer: telemetry.config.enabled ? nil : "Entwickler-Build: Hier wird nichts gesendet. KNIPS_TELEMETRY=1 schaltet das Senden ein.") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Anonyme Nutzungsstatistik").font(Brand.font(14, .medium)).foregroundStyle(Color.brand(Brand.ink))
                        Text("Zählt nur, welche Funktionen wie oft genutzt werden, nie Bilder, Texte oder Dateinamen.")
                            .font(Brand.font(12.5))
                            .foregroundStyle(Color.brand(Brand.inkSoft))
                            .fixedSize(horizontal: false, vertical: true)
                        BrandLink(title: "Was wird gesendet?", url: Telemetry.infoURL).padding(.top, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    BrandToggle(isOn: Binding(get: { telemetry.consent == true }, set: { telemetry.setConsent($0) }),
                                label: "Anonyme Nutzungsstatistik")
                }
                .padding(.vertical, 15)
            }
            BrandSection(title: "So arbeitet Knips") {
                InfoLine(symbol: "cpu", text: "Texterkennung läuft auf diesem Mac")
                BrandRowDivider()
                InfoLine(symbol: "network.slash", text: telemetry.consent == true
                         ? "Kein Konto. Ins Internet gehen nur die anonymen Zähler"
                         : "Kein Konto, nichts geht ins Internet")
                BrandRowDivider()
                InfoLine(symbol: "checkmark.shield", text: "Geteilte Dateien sind immer die zensierte Fassung")
                BrandRowDivider()
                InfoLine(symbol: "doc.on.clipboard", text: "„Text kopieren“ lässt Zensiertes und Weggeschnittenes weg")
                BrandRowDivider()
                InfoLine(symbol: "link", text: "Aufnahmen per knips://-Link nur nach Rückfrage")
            }
        }
        .onAppear { readiness.refresh() }
        .onReceive(readinessTimer) { _ in readiness.refresh() }
    }
}

// MARK: - Über Knips

struct AboutPane: View {
    static let sourceURL = URL(string: "https://github.com/patrickbirkholz0000/knips")!

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            BrandCard {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        BrandMark(size: 60, ink: .brand(Brand.ink), accent: .brand(Brand.accent))
                        Wordmark(size: 46, ink: .brand(Brand.ink), lamp: .brand(Brand.accent))
                    }
                    Text("Version \(AppVersion.short) · Build \(AppVersion.build)")
                        .font(Brand.mono(12))
                        .foregroundStyle(Color.brand(Brand.inkSoft))
                        .padding(.top, 14)
                    VStack(spacing: 4) {
                        Text("© 2026 Patrick Birkholz").font(Brand.font(13.5, .medium)).foregroundStyle(Color.brand(Brand.ink))
                        Text("Freie Software unter der GNU GPL v3 oder neuer, ohne jede Gewährleistung.")
                            .font(Brand.font(12.5))
                            .foregroundStyle(Color.brand(Brand.inkSoft))
                    }
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                    Button { NSWorkspace.shared.open(Self.sourceURL) } label: {
                        HStack(spacing: 5) {
                            Text("Quellcode")
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, compact: true))
                    .help(Self.sourceURL.absoluteString)
                    .padding(.top, 16)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            }
            BrandSection(title: "Schriften", detail: "Beide stehen unter der SIL Open Font License 1.1 und liegen der App bei.") {
                fontRow("Outfit", "Text und Titel", file: "OFL-Outfit")
                BrandRowDivider()
                fontRow("JetBrains Mono", "Zahlen, Zeiten und Kürzel", file: "OFL-JetBrainsMono")
            }
            BrandSection(title: "Funktionen") {
                InfoLine(symbol: "rectangle.dashed", text: "Bereich, Fenster oder Bildschirm, Auswahl auf eingefrorenem Bild")
                BrandRowDivider()
                InfoLine(symbol: "eye.slash", text: "Zensur-Balken mit Texterkennung, auch in Videos")
                BrandRowDivider()
                InfoLine(symbol: "record.circle", text: "Bildschirmvideos als MP4 oder GIF")
                BrandRowDivider()
                InfoLine(symbol: "text.viewfinder", text: "Text aus Screenshots kopieren")
            }
            BrandSection(title: "Für Raycast & Co.", footer: "Bildschirm, letzter Bereich und Videostart fragen vorher nach.") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Befehle").font(Brand.font(14, .medium)).foregroundStyle(Color.brand(Brand.ink))
                    Text("knips://area · window · fullscreen · record · text · scroll · last · pin · menu · history · settings")
                        .font(Brand.mono(12))
                        .foregroundStyle(Color.brand(Brand.inkMuted))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 16)
            }
        }
    }

    private func fontRow(_ name: String, _ use: String, file: String) -> some View {
        BrandRow(title: name, detail: use) {
            Button("Lizenz") { Self.openLicense(file) }
                .buttonStyle(BrandButtonStyle(kind: .secondary, compact: true))
                .help("\(file).txt")
        }
    }

    /// Lizenztext aus dem App-Bundle (`Resources/Fonts`), sonst im Quellcode.
    static func openLicense(_ file: String) {
        if let url = Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "Fonts") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(sourceURL.appendingPathComponent("blob/main/Resources/Fonts/\(file).txt"))
        }
    }
}
