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

        if UserDefaults.knips.object(forKey: "didFirstLaunch") == nil {
            UserDefaults.knips.set(true, forKey: "didFirstLaunch")
            if Bundle.main.bundlePath.hasPrefix("/Applications") { AppSettings.shared.launchAtLogin = true }
        }
        Telemetry.shared.start()
        if !ScreenCapture.hasPermission {
            // Die Statistik-Frage kommt nach dem Neustart, den die Freigabe ohnehin verlangt.
            PermissionWindowController.show()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                ShortcutTakeover.offerIfNeeded()   // modal — die Statistik-Frage folgt erst danach
                ConsentWindowController.showIfNeeded()
            }
        }
        // SwiftUI und das Einstellungsfenster vorwärmen — das erste Öffnen kostet sonst ~0,4 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SettingsWindowController.prewarm() }
        #if KNIPS_DEV
        // Test-Sandbox: Befehle per Distributed Notification (URL-Aufrufe landen sonst bei der installierten App).
        // Eigener Kanal, daher ohne Link-Rückfrage; „link:<befehl>“ verhält sich wie ein knips://-Link von außen.
        if Paths.testRoot != nil {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("de.birkgroup.knips.test"), object: nil, queue: .main) { note in
                guard let raw = note.object as? String else { return }
                let fromLink = raw.hasPrefix("link:")
                guard let url = URL(string: "knips://\(fromLink ? String(raw.dropFirst(5)) : raw)") else { return }
                onMainActor { (NSApp.delegate as? AppDelegate)?.handle(url, fromLink: fromLink) }
            }
        }
        #endif
        Log.info("Knips gestartet")
    }

    /// `knips://area|window|fullscreen|record|last|text|scroll|pin|menu|history|settings` — für Raycast,
    /// Stream Deck, Kurzbefehle. Sofort aufnehmende Befehle fragen vorher nach (`LinkCommands`) und nennen dabei
    /// den Absender des Apple Events, falls er sich bestimmen lässt.
    func application(_ application: NSApplication, open urls: [URL]) {
        let sender = LinkSender.describe(NSAppleEventManager.shared().currentAppleEvent)
        for url in urls where url.scheme == "knips" { handle(url, fromLink: true, sender: sender) }
    }

    /// `fromLink`: über einen knips://-Link von außen; nur der Test-Kanal der Sandbox übergibt `false`.
    func handle(_ url: URL, fromLink: Bool, sender: String? = nil) {
        let command = url.host ?? url.path.replacingOccurrences(of: "/", with: "")
        if LinkCommands.shared.run(command, fromLink: fromLink, sender: sender) { return }
        switch command {
        #if KNIPS_DEV
        case "debug-sample" where Paths.testRoot != nil:
            if let item = try? CaptureStore.shared.addImage(SelfTest.sampleImage(), scale: 2) {
                QuickAccessController.shared.show(item, on: NSScreen.main ?? NSScreen.withMouse)
            }
        case "debug-lastarea" where Paths.testRoot != nil:
            CaptureCoordinator.shared.debugSetLastArea(CGRect(x: 100, y: 100, width: 400, height: 300))
        case "debug-scroll" where Paths.testRoot != nil:
            Task {
                guard let screen = NSScreen.main, let content = try? await ScreenCapture.content(),
                      let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
                ScrollCaptureController.shared.begin(screen: screen, display: display, localRect: CGRect(x: 100, y: 100, width: 600, height: 400), content: content)
            }
        case "debug-scroll-done" where Paths.testRoot != nil:
            ScrollCaptureController.shared.finish(save: true)
        case "debug-snapshot" where Paths.testRoot != nil:
            Task { await Self.snapshotOwnWindows() }
        #endif
        default: Log.info("Unbekannter Befehl: \(url.absoluteString)")
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
        appMenu.addItem(NSMenuItem(title: "Über Knips", action: #selector(AppDelegate.openAbout), keyEquivalent: ""))
        appMenu.addItem(.separator())
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
    @objc func openAbout() { SettingsWindowController.show(.about) }

    #if KNIPS_DEV
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
    #endif
}

/// Bietet einmalig an, die macOS-Bildschirmfoto-Kürzel für Knips freizumachen.
@MainActor enum ShortcutTakeover {
    static func offerIfNeeded() {
        // Die Test-Sandbox hat eigene (leere) Einstellungen — sie würde sonst bei jedem Start fragen und die echten
        // macOS-Kürzel umschreiben.
        guard Paths.testRoot == nil else { return }
        let combos = Array(AppSettings.shared.activeHotkeys.values)
        let ids = SystemShortcuts.conflictingIDs(for: combos)
        guard !ids.isEmpty else { return }
        let asked = "askedShortcutTakeover"
        guard !UserDefaults.knips.bool(forKey: asked) else { return }
        UserDefaults.knips.set(true, forKey: asked)

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
