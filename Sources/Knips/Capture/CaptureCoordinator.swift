import AppKit
import ScreenCaptureKit

@MainActor final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: SelectionOverlay?
    private var busy = false

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureArea: captureInteractive(windowMode: false)
        case .captureWindow: captureInteractive(windowMode: true)
        case .captureFullscreen: captureFullscreen()
        case .toggleRecording: toggleRecording()
        case .pinClipboard: pinClipboard()
        }
    }

    // MARK: Screenshot

    func captureInteractive(windowMode: Bool) {
        guard !busy, overlay == nil, !RecordingController.shared.isBusy else { return }
        guard ensurePermission() else { return }
        busy = true
        Task {
            do {
                let content = try await ScreenCapture.content()
                let frozen = try await ScreenCapture.freeze(NSScreen.screens, content: content)
                let windows = ScreenCapture.windows()
                let overlay = SelectionOverlay(frozen: frozen, windows: windows, purpose: .screenshot, windowMode: windowMode) { [weak self] result in
                    self?.overlay = nil
                    self?.busy = false
                    self?.handleScreenshot(result, content: content)
                }
                self.overlay = overlay
                overlay.present()
            } catch {
                busy = false
                report(error)
            }
        }
    }

    func captureFullscreen() {
        guard !busy, overlay == nil else { return }
        guard ensurePermission() else { return }
        busy = true
        let screen = NSScreen.withMouse
        Task {
            defer { busy = false }
            do {
                let content = try await ScreenCapture.content()
                guard let frozen = try await ScreenCapture.freeze([screen], content: content).first else { return }
                finish(image: frozen.image, scale: frozen.scale, screen: screen)
            } catch {
                report(error)
            }
        }
    }

    private func handleScreenshot(_ result: SelectionResult, content: SCShareableContent) {
        switch result {
        case .cancelled:
            return
        case .fullScreen(let f):
            finish(image: f.image, scale: f.scale, screen: f.screen)
        case .area(let f, let rect):
            guard let image = ScreenCapture.crop(f, localRect: rect) else { return }
            finish(image: image, scale: f.scale, screen: f.screen)
        case .window(let w, let f):
            Task {
                do {
                    let image = try await ScreenCapture.captureWindow(w, content: content, scale: f.scale)
                    finish(image: image, scale: f.scale, screen: f.screen)
                } catch {
                    // Fallback: Ausschnitt aus dem Standbild
                    let local = w.frame.offsetBy(dx: -f.screen.frame.minX, dy: -f.screen.frame.minY)
                        .intersection(CGRect(origin: .zero, size: f.screen.frame.size))
                    if let image = ScreenCapture.crop(f, localRect: local) { finish(image: image, scale: f.scale, screen: f.screen) }
                }
            }
        }
    }

    func finish(image: CGImage, scale: CGFloat, screen: NSScreen) {
        Sounds.playShutter()
        let settings = AppSettings.shared
        do {
            let item = try CaptureStore.shared.addImage(image, scale: scale)
            if settings.copyToClipboard { Clipboard.copy(image: image, fileURL: item.fileURL) }
            if settings.showQuickAccess { QuickAccessController.shared.show(item, on: screen) }
            if settings.openEditorAfterCapture { EditorWindowController.show(item) }
            StatusBarController.shared?.refreshMenu()
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
        guard !busy, overlay == nil, !recorder.isBusy else { return }
        guard ensurePermission() else { return }
        busy = true
        Task {
            do {
                let content = try await ScreenCapture.content()
                let frozen = try await ScreenCapture.freeze(NSScreen.screens, content: content)
                let windows = ScreenCapture.windows()
                let overlay = SelectionOverlay(frozen: frozen, windows: windows, purpose: .recording, windowMode: false) { [weak self] result in
                    self?.overlay = nil
                    self?.busy = false
                    let area: (NSScreen, SCDisplay?, CGRect)?
                    switch result {
                    case .cancelled: area = nil
                    case .fullScreen(let f): area = (f.screen, f.display, CGRect(origin: .zero, size: f.screen.frame.size))
                    case .area(let f, let r): area = (f.screen, f.display, r)
                    case .window(let w, let f):
                        let local = w.frame.offsetBy(dx: -f.screen.frame.minX, dy: -f.screen.frame.minY)
                            .intersection(CGRect(origin: .zero, size: f.screen.frame.size)).integral
                        area = (f.screen, f.display, local)
                    }
                    guard let area, let display = area.1 else { return }
                    RecordingController.shared.begin(screen: area.0, display: display, localRect: area.2, content: content)
                }
                self.overlay = overlay
                overlay.present()
            } catch {
                busy = false
                report(error)
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
