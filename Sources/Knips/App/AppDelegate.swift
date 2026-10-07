import AppKit
import ScreenCaptureKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        Paths.ensure(Paths.items)
        _ = CaptureStore.shared
        StatusBarController.shared = StatusBarController()
        _ = QuickAccessController.shared

        HotkeyManager.shared.onAction = { action in CaptureCoordinator.shared.perform(action) }
        HotkeyManager.shared.apply(AppSettings.shared.activeHotkeys)

        if UserDefaults.standard.object(forKey: "didFirstLaunch") == nil {
            UserDefaults.standard.set(true, forKey: "didFirstLaunch")
            if Bundle.main.bundlePath.hasPrefix("/Applications") { AppSettings.shared.launchAtLogin = true }
        }
        if !ScreenCapture.hasPermission {
            PermissionWindowController.show()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ShortcutTakeover.offerIfNeeded() }
        }
        // SwiftUI und das Einstellungsfenster vorwärmen — das erste Öffnen kostet sonst ~0,4 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SettingsWindowController.prewarm() }
        // Test-Sandbox: Befehle per Distributed Notification (URL-Aufrufe landen sonst bei der installierten App).
        if Paths.testRoot != nil {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("de.birkgroup.knips.test"), object: nil, queue: .main) { note in
                guard let command = note.object as? String, let url = URL(string: "knips://\(command)") else { return }
                MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [url]) }
            }
        }
        Log.info("Knips gestartet")
    }

    /// `knips://area`, `knips://window`, `knips://fullscreen`, `knips://record`, `knips://pin`
    /// — für Raycast, Stream Deck, Kurzbefehle.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "knips" {
            let command = url.host ?? url.path.replacingOccurrences(of: "/", with: "")
            switch command {
            case "area": CaptureCoordinator.shared.perform(.captureArea)
            case "window": CaptureCoordinator.shared.perform(.captureWindow)
            case "fullscreen": CaptureCoordinator.shared.perform(.captureFullscreen)
            case "record": CaptureCoordinator.shared.perform(.toggleRecording)
            case "pin": CaptureCoordinator.shared.perform(.pinClipboard)
            case "last": CaptureCoordinator.shared.perform(.captureLastArea)
            case "text": CaptureCoordinator.shared.perform(.captureText)
            case "settings": SettingsWindowController.show()
            case "menu": StatusBarController.shared?.togglePanel()
            case "debug-sample" where Paths.testRoot != nil:
                if let item = try? CaptureStore.shared.addImage(SelfTest.sampleImage(), scale: 2) {
                    QuickAccessController.shared.show(item, on: NSScreen.main ?? NSScreen.withMouse)
                }
            case "debug-lastarea" where Paths.testRoot != nil:
                CaptureCoordinator.shared.debugSetLastArea(CGRect(x: 100, y: 100, width: 400, height: 300))
            case "debug-snapshot" where Paths.testRoot != nil:
                Task { await Self.snapshotOwnWindows() }
            default: Log.info("Unbekannter Befehl: \(url.absoluteString)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.show() }
        return true
    }

    /// Unsichtbares Hauptmenü — nötig, damit ⌘Z, ⌘C, ⌘V, ⌘W usw. in Editor und Textfeldern funktionieren.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Einstellungen …", action: #selector(AppDelegate.openSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Knips ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Knips beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Ablage")
        fileMenu.addItem(NSMenuItem(title: "Sichern", action: Selector(("saveDocument:")), keyEquivalent: "s"))
        fileMenu.addItem(NSMenuItem(title: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(NSMenuItem(title: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    @objc func openSettings() { SettingsWindowController.show() }

    /// Nur in der Test-Sandbox: fotografiert die eigenen sichtbaren Fenster einzeln (nie den Bildschirm).
    private static func snapshotOwnWindows() async {
        guard let root = Paths.testRoot,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        for (i, w) in content.windows.enumerated() where w.owningApplication?.processID == pid && w.frame.width > 40 {
            let config = SCStreamConfiguration()
            config.width = Int(w.frame.width * 2)
            config.height = Int(w.frame.height * 2)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config) else { continue }
            let url = root.appendingPathComponent("fenster-\(i)-\(Int(w.frame.minX))x\(Int(w.frame.minY)).png")
            try? image.pngData()?.write(to: url)
            Log.info("Snapshot \(url.lastPathComponent) frame=\(w.frame)")
        }
    }
}

/// Bietet einmalig an, die macOS-Bildschirmfoto-Kürzel für Knips freizumachen.
@MainActor enum ShortcutTakeover {
    static func offerIfNeeded() {
        let combos = Array(AppSettings.shared.activeHotkeys.values)
        let ids = SystemShortcuts.conflictingIDs(for: combos)
        guard !ids.isEmpty else { return }
        let asked = "askedShortcutTakeover"
        guard !UserDefaults.standard.bool(forKey: asked) else { return }
        UserDefaults.standard.set(true, forKey: asked)

        let list = combos.filter { SystemShortcuts.conflict(for: $0) != nil }.map(\.display).sorted().joined(separator: ", ")
        var info: [String] = []
        if !ids.isEmpty {
            info.append("macOS belegt \(list) noch für eigene Bildschirmfotos. Knips schaltet diese macOS-Kürzel ab — in den Knips-Einstellungen unter „Tastaturkurzbefehle“ jederzeit wiederherstellbar.")
        }
        let alert = NSAlert()
        alert.messageText = "⇧⌘3, ⇧⌘4 und ⇧⌘5 für Knips übernehmen?"
        alert.informativeText = info.joined(separator: "\n\n")
        alert.addButton(withTitle: "Übernehmen")
        alert.addButton(withTitle: "Nicht jetzt")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SystemShortcuts.takeOver(ids)
        HotkeyManager.shared.apply(AppSettings.shared.activeHotkeys)
        HUD.show("Kürzel übernommen")
    }
}
