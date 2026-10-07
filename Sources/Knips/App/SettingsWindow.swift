import AppKit
import SwiftUI

@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: SettingsWindowController?

    static func show() {
        if instance == nil { instance = SettingsWindowController() }
        DockPresence.windowOpened()
        instance?.showWindow(nil)
        instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Knips – Einstellungen"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(settings: AppSettings.shared))
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        HotkeyRecorderState.shared.cancel()
        DockPresence.windowClosed()
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            general.tabItem { Label("Allgemein", systemImage: "gearshape") }
            shortcuts.tabItem { Label("Kürzel", systemImage: "keyboard") }
            recording.tabItem { Label("Aufnahme", systemImage: "record.circle") }
        }
        .padding(18)
        .frame(width: 560, height: 470)
    }

    private var general: some View {
        Form {
            Section("Nach einer Aufnahme") {
                Toggle("In die Zwischenablage kopieren", isOn: $settings.copyToClipboard)
                Toggle("Karte unten links anzeigen", isOn: $settings.showQuickAccess)
                Picker("Karte ausblenden", selection: $settings.quickAccessAutoClose) {
                    Text("Nie").tag(0)
                    Text("nach 5 s").tag(5)
                    Text("nach 10 s").tag(10)
                    Text("nach 30 s").tag(30)
                    Text("nach 1 min").tag(60)
                }
                .disabled(!settings.showQuickAccess)
                Toggle("Editor sofort öffnen", isOn: $settings.openEditorAfterCapture)
                Toggle("Auslöser-Ton", isOn: $settings.playSound)
            }
            Section("Ablage") {
                HStack {
                    Text(settings.saveFolderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Ändern …") { chooseFolder() }
                    Button("Öffnen") { NSWorkspace.shared.open(settings.saveFolder) }
                }
                Text("Im Ordner liegt immer die bearbeitete Fassung — zensierte Stellen sind darin endgültig unkenntlich.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System") {
                Toggle("Beim Anmelden starten", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                HStack {
                    Text("Bildschirmaufnahme-Berechtigung")
                    Spacer()
                    if ScreenCapture.hasPermission {
                        Label("erteilt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Einrichten …") { PermissionWindowController.show() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRow(action: action, settings: settings)
                }
            } footer: {
                Text("Kürzel antippen und neue Kombination drücken. ⌘⇧3/4/5 lassen sich übernehmen, wenn sie in den Systemeinstellungen unter Tastatur → Tastaturkurzbefehle → Bildschirmfotos ausgeschaltet sind.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Standard wiederherstellen") {
                    var keys: [HotkeyAction: KeyCombo] = [:]
                    for a in HotkeyAction.allCases { if let c = a.defaultCombo { keys[a] = c } }
                    settings.hotkeys = keys
                    HotkeyManager.shared.apply(keys)
                }
                Button("Tastaturkurzbefehle des Systems öffnen") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var recording: some View {
        Form {
            Section("Video") {
                Picker("Bildrate", selection: $settings.recordingFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                Toggle("Mauszeiger aufnehmen", isOn: $settings.recordingShowCursor)
                Toggle("3-2-1-Countdown vor dem Start", isOn: $settings.recordingCountdown)
                Toggle("Mikrofon aufnehmen", isOn: $settings.recordingMicrophone)
                    .disabled(ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15)
            }
            Section("GIF-Export") {
                Picker("Bildrate", selection: $settings.gifFPS) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("20 fps").tag(20)
                    Text("25 fps").tag(25)
                }
                Picker("Maximale Breite", selection: $settings.gifWidth) {
                    Text("640 px").tag(640)
                    Text("800 px").tag(800)
                    Text("960 px").tag(960)
                    Text("1280 px").tag(1280)
                }
            }
            Section("Zensur") {
                Picker("Standardstil", selection: $settings.redactStyle) {
                    ForEach(RedactStyle.allCases) { Text($0.title).tag($0) }
                }
                Text("„Schwärzen“ ist die sicherste Variante. Verpixeln und Unschärfe sind bei normaler Schrift unlesbar, verraten aber Länge und grobe Form des Inhalts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

// MARK: - Kürzel aufnehmen

@MainActor final class HotkeyRecorderState: ObservableObject {
    static let shared = HotkeyRecorderState()
    @Published var recording: HotkeyAction?
    private var monitor: Any?

    func start(_ action: HotkeyAction, onCombo: @escaping (KeyCombo?) -> Void) {
        cancel()
        recording = action
        HotkeyManager.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.finish(); onCombo(nil); return nil }
            if event.keyCode == 51 || event.keyCode == 117 {
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
        HotkeyManager.shared.apply(AppSettings.shared.hotkeys)
    }
}

private struct HotkeyRow: View {
    let action: HotkeyAction
    @ObservedObject var settings: AppSettings
    @ObservedObject private var recorder = HotkeyRecorderState.shared

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            if let combo = settings.hotkeys[action], let conflict = SystemShortcuts.conflict(for: combo) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Kollidiert mit dem macOS-Kürzel „\(conflict)“ — dort ausschalten oder anderes Kürzel wählen.")
            }
            if HotkeyManager.shared.failures.contains(action) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("Kürzel ist bereits von einer anderen App belegt.")
            }
            Button {
                recorder.start(action) { combo in
                    guard let combo else { return }
                    var keys = settings.hotkeys
                    if combo.keyCode == UInt32.max {
                        keys[action] = nil
                    } else {
                        for (other, c) in keys where c == combo && other != action { keys[other] = nil }
                        keys[action] = combo
                    }
                    settings.hotkeys = keys
                    HotkeyManager.shared.apply(keys)
                }
            } label: {
                Text(recorder.recording == action ? "Tasten drücken …" : (settings.hotkeys[action]?.display ?? "—"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .frame(minWidth: 110)
            }
            .help("Klicken und neue Kombination drücken · ⌫ entfernt · Esc bricht ab")
        }
    }
}

// MARK: - Berechtigung

@MainActor final class PermissionWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: PermissionWindowController?

    static func show() {
        if instance == nil { instance = PermissionWindowController() }
        DockPresence.windowOpened()
        instance?.showWindow(nil)
        instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Knips einrichten"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: PermissionView())
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { DockPresence.windowClosed() }
}

private struct PermissionView: View {
    @State private var granted = ScreenCapture.hasPermission
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bildschirmaufnahme erlauben").font(.system(size: 17, weight: .semibold))
                    Text("Knips braucht die macOS-Freigabe, um Screenshots und Videos zu machen. Alles bleibt auf deinem Mac.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Auf „Freigabe anfragen“ klicken.")
                step(2, "In den Systemeinstellungen bei „Bildschirm- & Systemaudioaufnahme“ Knips einschalten.")
                step(3, "Knips neu starten — macOS übernimmt die Freigabe erst danach.")
            }
            Spacer()
            HStack {
                if granted {
                    Label("Freigabe erteilt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Systemeinstellungen") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Button("Freigabe anfragen") { _ = CGRequestScreenCaptureAccess() }
                Button("Knips neu starten") { relaunch() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460, height: 330)
        .onReceive(timer) { _ in granted = ScreenCapture.hasPermission }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text).font(.system(size: 13))
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
