import AppKit
import ScreenCaptureKit

@MainActor final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: SelectionOverlay?

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureArea: captureInteractive(windowMode: false)
        case .captureWindow: captureInteractive(windowMode: true)
        case .captureFullscreen: captureFullscreen()
        case .toggleRecording: toggleRecording()
        case .pinClipboard: pinClipboard()
        }
    }

    /// Standbild aller Bildschirme im Hintergrund — Knips-Fenster (also auch das Overlay) sind ausgeschlossen.
    private typealias Frozen = (content: SCShareableContent, screens: [FrozenScreen])

    private func startFreeze(_ screens: [NSScreen]) -> Task<Frozen, Error> {
        Task {
            let content = try await ScreenCapture.content()
            let frozen = try await ScreenCapture.freeze(screens, content: content)
            return (content, frozen)
        }
    }

    /// Overlay erscheint sofort; das Standbild wird darunter aufgenommen und nachgereicht.
    private func presentOverlay(purpose: SelectionPurpose, windowMode: Bool,
                                onResult: @escaping (SelectionResult, Task<Frozen, Error>) -> Void) {
        guard overlay == nil, !RecordingController.shared.isBusy else { return }
        guard ensurePermission() else { return }
        let screens = NSScreen.screens
        let freeze = startFreeze(screens)
        let overlay = SelectionOverlay(screens: screens, windows: ScreenCapture.windows(), purpose: purpose,
                                       windowMode: windowMode) { [weak self] result in
            self?.overlay = nil
            onResult(result, freeze)
        }
        self.overlay = overlay
        overlay.present()
        Task {
            do {
                let frozen = try await freeze.value
                if overlay.isActive { overlay.setFrozen(frozen.screens) }
            } catch {
                if overlay.isActive { overlay.finish(.cancelled) }
                report(error)
            }
        }
    }

    // MARK: Screenshot

    func captureInteractive(windowMode: Bool) {
        presentOverlay(purpose: .screenshot, windowMode: windowMode) { [weak self] result, freeze in
            self?.handleScreenshot(result, freeze: freeze)
        }
    }

    func captureFullscreen() {
        guard overlay == nil else { return }
        guard ensurePermission() else { return }
        let screen = NSScreen.withMouse
        Task {
            do {
                let content = try await ScreenCapture.content()
                guard let frozen = try await ScreenCapture.freeze([screen], content: content).first else { return }
                Sounds.playShutter()
                finish(image: frozen.image, scale: frozen.scale, screen: screen)
            } catch {
                report(error)
            }
        }
    }

    private func handleScreenshot(_ result: SelectionResult, freeze: Task<Frozen, Error>) {
        if case .cancelled = result { return }
        // Auslöser sofort beim Loslassen — die Arbeit danach läuft im Hintergrund weiter.
        Sounds.playShutter()
        Task {
            guard let frozen = try? await freeze.value else { return }
            func still(for screen: NSScreen) -> FrozenScreen? { frozen.screens.first { $0.screen == screen } }
            switch result {
            case .cancelled:
                return
            case .fullScreen(let screen):
                guard let f = still(for: screen) else { return }
                finish(image: f.image, scale: f.scale, screen: screen)
            case .area(let screen, let rect):
                guard let f = still(for: screen), let image = ScreenCapture.crop(f, localRect: rect) else { return }
                finish(image: image, scale: f.scale, screen: screen)
            case .window(let w, let screen):
                guard let f = still(for: screen) else { return }
                if let image = try? await ScreenCapture.captureWindow(w, content: frozen.content, scale: f.scale) {
                    finish(image: image, scale: f.scale, screen: screen)
                } else {
                    // Fallback: Ausschnitt aus dem Standbild
                    let local = w.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                        .intersection(CGRect(origin: .zero, size: screen.frame.size))
                    if let image = ScreenCapture.crop(f, localRect: local) { finish(image: image, scale: f.scale, screen: screen) }
                }
            }
        }
    }

    /// Legt die Aufnahme an. Kodieren und Schreiben laufen im Hintergrund; die Zwischenablage
    /// liefert die PNG-Daten erst, wenn eine App sie anfragt.
    func finish(image: CGImage, scale: CGFloat, screen: NSScreen) {
        let settings = AppSettings.shared
        let png = PNGPromise(image)
        do {
            let item = try CaptureStore.shared.addImage(image, scale: scale, png: png)
            if settings.copyToClipboard { Clipboard.copy(png: png, fileURL: item.fileURL) }
            if settings.showQuickAccess { QuickAccessController.shared.show(item, on: screen) }
            if settings.openEditorAfterCapture { EditorWindowController.show(item) }
        } catch {
            report(error)
        }
    }

    // MARK: Bildschirmaufnahme

    func toggleRecording() {
        let recorder = RecordingController.shared
        if recorder.isBusy {
            // Läuft: speichern. Countdown: abbrechen.
            recorder.stop(save: true)
            return
        }
        presentOverlay(purpose: .recording, windowMode: false) { result, freeze in
            Task {
                guard let frozen = try? await freeze.value else { return }
                let area: (NSScreen, CGRect)?
                switch result {
                case .cancelled: area = nil
                case .fullScreen(let s): area = (s, CGRect(origin: .zero, size: s.frame.size))
                case .area(let s, let r): area = (s, r)
                case .window(let w, let s):
                    let local = w.frame.offsetBy(dx: -s.frame.minX, dy: -s.frame.minY)
                        .intersection(CGRect(origin: .zero, size: s.frame.size)).integral
                    area = (s, local)
                }
                guard let area, let display = frozen.content.displays.first(where: { $0.displayID == area.0.displayID }) else { return }
                RecordingController.shared.begin(screen: area.0, display: display, localRect: area.1, content: frozen.content)
            }
        }
    }

    // MARK: Sonstiges

    func pinClipboard() {
        guard let image = Clipboard.image() else {
            HUD.show("Kein Bild in der Zwischenablage", symbol: "exclamationmark.circle.fill")
            return
        }
        PinWindowController.pin(image, scale: NSScreen.withMouse.backingScaleFactor)
    }

    func openImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Bild zum Bearbeiten öffnen"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let item = try CaptureStore.shared.importImage(at: url)
            EditorWindowController.show(item)
        } catch {
            report(error)
        }
    }

    private func ensurePermission() -> Bool {
        if ScreenCapture.hasPermission { return true }
        PermissionWindowController.show()
        return false
    }

    private func report(_ error: Error) {
        if case CaptureError.noPermission = error {
            PermissionWindowController.show()
            return
        }
        Log.error("Aufnahme fehlgeschlagen: \(error.localizedDescription)")
        Alerts.error("Aufnahme fehlgeschlagen", error)
    }
}
