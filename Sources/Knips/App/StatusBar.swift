import AppKit
import Combine

@MainActor final class StatusBarController: NSObject, NSMenuDelegate {
    static var shared: StatusBarController?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        super.init()
        menu.delegate = self
        item.button?.image = Self.icon
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        RecordingController.shared.$elapsed
            .combineLatest(RecordingController.shared.$phase)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRecordingState() }
            .store(in: &cancellables)
        AppSettings.shared.$hotkeys
            .combineLatest(AppSettings.shared.$disabledHotkeys)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenu() }
            .store(in: &cancellables)
    }

    static let icon: NSImage = {
        let img = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Knips") ?? NSImage()
        let configured = img.withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) ?? img
        configured.isTemplate = true
        return configured
    }()

    @objc private func statusClicked() {
        // Während einer Aufnahme stoppt ein Klick auf das Symbol sofort.
        if RecordingController.shared.isRecording {
            RecordingController.shared.stop(save: true)
            return
        }
        refreshMenu()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    func menuDidClose(_ menu: NSMenu) { item.menu = nil }

    func refreshRecordingState() {
        let rc = RecordingController.shared
        switch rc.phase {
        case .recording:
            item.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Aufnahme stoppen")?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            item.button?.attributedTitle = NSAttributedString(string: " " + Format.duration(rc.elapsed), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            ])
        case .countdown(let n):
            item.button?.image = Self.icon
            item.button?.title = " \(n)"
        default:
            item.button?.image = Self.icon
            item.button?.title = ""
        }
    }

    func refreshMenu() {
        menu.removeAllItems()
        let keys = AppSettings.shared.activeHotkeys
        func add(_ title: String, _ symbol: String, action: Selector, combo: KeyCombo? = nil) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: combo?.menuKeyEquivalent ?? "")
            if let combo { mi.keyEquivalentModifierMask = combo.cocoaModifiers }
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            mi.target = self
            menu.addItem(mi)
        }
        add("Bereich aufnehmen", "rectangle.dashed", action: #selector(area), combo: keys[.captureArea])
        add("Fenster aufnehmen", "macwindow", action: #selector(window), combo: keys[.captureWindow])
        add("Ganzen Bildschirm aufnehmen", "display", action: #selector(fullscreen), combo: keys[.captureFullscreen])
        menu.addItem(.separator())
        if RecordingController.shared.isRecording {
            add("Bildschirmaufnahme stoppen", "stop.circle", action: #selector(record), combo: keys[.toggleRecording])
        } else {
            add("Bildschirmaufnahme starten", "record.circle", action: #selector(record), combo: keys[.toggleRecording])
        }
        menu.addItem(.separator())
        add("Bild aus Zwischenablage anpinnen", "pin", action: #selector(pinClipboard), combo: keys[.pinClipboard])
        add("Bild öffnen und bearbeiten …", "photo.badge.plus", action: #selector(openImage))

        let recent = CaptureStore.shared.recent
        let recentItem = NSMenuItem(title: "Letzte Aufnahmen", action: nil, keyEquivalent: "")
        recentItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        let sub = NSMenu()
        if recent.isEmpty {
            sub.addItem(NSMenuItem(title: "Noch keine Aufnahmen", action: nil, keyEquivalent: ""))
        }
        for capture in recent {
            let mi = NSMenuItem(title: capture.title, action: #selector(openRecent(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = capture.id.uuidString
            if let thumb = ThumbnailCache.shared.image(for: capture) {
                let small = NSImage(size: NSSize(width: 36, height: 22), flipped: false) { rect in
                    let s = thumb.size
                    let f = min(rect.width / s.width, rect.height / s.height)
                    let r = NSRect(x: (rect.width - s.width * f) / 2, y: (rect.height - s.height * f) / 2, width: s.width * f, height: s.height * f)
                    thumb.draw(in: r)
                    return true
                }
                mi.image = small
            }
            sub.addItem(mi)
        }
        recentItem.submenu = sub
        menu.addItem(recentItem)
        add("Ablageordner öffnen", "folder", action: #selector(openFolder))
        menu.addItem(.separator())
        add("Einstellungen …", "gearshape", action: #selector(settings))
        if !ScreenCapture.hasPermission {
            add("Berechtigung einrichten …", "exclamationmark.triangle", action: #selector(permission))
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Knips beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func area() { CaptureCoordinator.shared.perform(.captureArea) }
    @objc private func window() { CaptureCoordinator.shared.perform(.captureWindow) }
    @objc private func fullscreen() { CaptureCoordinator.shared.perform(.captureFullscreen) }
    @objc private func record() { CaptureCoordinator.shared.perform(.toggleRecording) }
    @objc private func pinClipboard() { CaptureCoordinator.shared.perform(.pinClipboard) }
    @objc private func openImage() { CaptureCoordinator.shared.openImageFile() }
    @objc private func settings() { SettingsWindowController.show() }
    @objc private func permission() { PermissionWindowController.show() }

    @objc private func openFolder() {
        let folder = AppSettings.shared.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw),
              let capture = CaptureStore.shared.item(with: id) else { return }
        QuickAccessController.edit(capture, tool: nil)
    }
}
