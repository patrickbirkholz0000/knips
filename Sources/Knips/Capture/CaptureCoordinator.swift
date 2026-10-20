import AppKit
import ScreenCaptureKit

@MainActor final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: SelectionOverlay?
    /// Zuletzt aufgenommener Bereich (Bildschirm + Rechteck in Punkten) für „Letzten Bereich wiederholen“.
    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)?
    /// Quelle des laufenden Scroll-Screenshots — `ScrollCaptureController` meldet sein Ergebnis ohne Quelle.
    private var scrollSource: CaptureSource = .user

    /// `source`: `.link` für knips://-Links (`LinkCommands`) — dann nimmt das Overlay ⏎ und Klicks erst nach der
    /// Schutzzeit an, und die Aufnahme landet nicht von selbst in der Zwischenablage.
    func perform(_ action: HotkeyAction, source: CaptureSource = .user) {
        switch action {
        case .captureArea: captureInteractive(windowMode: false, source: source)
        case .captureWindow: captureInteractive(windowMode: true, source: source)
        case .captureFullscreen: captureFullscreen(source: source)
        case .captureLastArea: captureLastArea(source: source)
        case .captureText: captureText(source: source)
        case .captureScrolling: captureScrolling(source: source)
        case .toggleRecording: toggleRecording(source: source)
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
    private func presentOverlay(purpose: SelectionPurpose, windowMode: Bool, source: CaptureSource,
                                onResult: @escaping (SelectionResult, Task<Frozen, Error>) -> Void) {
        guard overlay == nil, !RecordingController.shared.isBusy else { return }
        guard ensurePermission() else { return }
        let screens = NSScreen.screens
        let freeze = startFreeze(screens)
        let overlay = SelectionOverlay(screens: screens, windows: ScreenCapture.windows(), purpose: purpose, windowMode: windowMode,
                                       armDelay: source == .link ? LinkConfirmWindowController.armDelay : 0) { [weak self] result in
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

    func captureInteractive(windowMode: Bool, source: CaptureSource = .user) {
        presentOverlay(purpose: .screenshot, windowMode: windowMode, source: source) { [weak self] result, freeze in
            self?.handleScreenshot(result, freeze: freeze, source: source)
        }
    }

    func captureFullscreen(source: CaptureSource = .user) {
        guard overlay == nil else { return }
        guard ensurePermission() else { return }
        let screen = NSScreen.withMouse
        Task {
            do {
                let content = try await ScreenCapture.content()
                guard let frozen = try await ScreenCapture.freeze([screen], content: content).first else { return }
                Sounds.playShutter()
                Telemetry.count(.captureFullscreen)
                finish(image: frozen.image, scale: frozen.scale, screen: screen, source: source)
            } catch {
                report(error)
            }
        }
    }

    private func handleScreenshot(_ result: SelectionResult, freeze: Task<Frozen, Error>, source: CaptureSource) {
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
                Telemetry.count(.captureFullscreen)
                finish(image: f.image, scale: f.scale, screen: screen, source: source)
            case .area(let screen, let rect):
                guard let f = still(for: screen), let image = ScreenCapture.crop(f, localRect: rect) else { return }
                lastArea = (screen.displayID, rect)
                Telemetry.count(.captureArea)
                finish(image: image, scale: f.scale, screen: screen, source: source)
            case .window(let w, let screen):
                guard let f = still(for: screen) else { return }
                Telemetry.count(.captureWindow)
                if let image = try? await ScreenCapture.captureWindow(w, content: frozen.content, scale: f.scale) {
                    finish(image: image, scale: f.scale, screen: screen, source: source)
                } else {
                    // Fallback: Ausschnitt aus dem Standbild
                    let local = w.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                        .intersection(CGRect(origin: .zero, size: screen.frame.size))
                    if let image = ScreenCapture.crop(f, localRect: local) { finish(image: image, scale: f.scale, screen: screen, source: source) }
                }
            }
        }
    }

    #if KNIPS_DEV
    /// Nur Test-Sandbox: letzten Bereich setzen, ohne Maus.
    func debugSetLastArea(_ rect: CGRect) {
        guard Paths.testRoot != nil, let screen = NSScreen.main else { return }
        lastArea = (screen.displayID, rect)
    }
    #endif

    /// Gleicher Ausschnitt wie beim letzten Mal — ohne Overlay.
    func captureLastArea(source: CaptureSource = .user) {
        guard overlay == nil, ensurePermission() else { return }
        guard let last = lastArea, let screen = NSScreen.screens.first(where: { $0.displayID == last.displayID }) else {
            HUD.show("Noch kein Bereich aufgenommen", symbol: "rectangle.dashed")
            captureInteractive(windowMode: false, source: source)
            return
        }
        Task {
            do {
                let content = try await ScreenCapture.content()
                guard let frozen = try await ScreenCapture.freeze([screen], content: content).first,
                      let image = ScreenCapture.crop(frozen, localRect: last.rect) else { return }
                Sounds.playShutter()
                Telemetry.count(.captureLastArea)
                finish(image: image, scale: frozen.scale, screen: screen, source: source)
            } catch {
                report(error)
            }
        }
    }

    /// Bereich wählen, dann scrollen — Knips setzt die Abschnitte zu einem langen Bild zusammen.
    func captureScrolling(source: CaptureSource = .user) {
        let scroll = ScrollCaptureController.shared
        if scroll.active {
            scroll.finish(save: true)
            return
        }
        presentOverlay(purpose: .scroll, windowMode: false, source: source) { [weak self] result, freeze in
            self?.scrollSource = source
            Task {
                guard let frozen = try? await freeze.value else { return }
                let area: (NSScreen, CGRect)?
                switch result {
                case .cancelled: area = nil
                case .area(let s, let r): area = (s, r)
                case .fullScreen(let s): area = (s, CGRect(origin: .zero, size: s.frame.size))
                case .window(let w, let s):
                    area = (s, w.frame.offsetBy(dx: -s.frame.minX, dy: -s.frame.minY).intersection(CGRect(origin: .zero, size: s.frame.size)).integral)
                }
                guard let area, let display = frozen.content.displays.first(where: { $0.displayID == area.0.displayID }) else { return }
                scroll.begin(screen: area.0, display: display, localRect: area.1, content: frozen.content)
            }
        }
    }

    /// Bereich ziehen → erkannter Text in die Zwischenablage, keine Datei. Per Link erst nach Rückfrage mit Vorschau.
    func captureText(source: CaptureSource = .user) {
        presentOverlay(purpose: .text, windowMode: false, source: source) { [weak self] result, freeze in
            Task {
                guard let frozen = try? await freeze.value else { return }
                let image: CGImage?
                switch result {
                case .cancelled: return
                case .area(let s, let r): image = frozen.screens.first { $0.screen == s }.flatMap { ScreenCapture.crop($0, localRect: r) }
                case .fullScreen(let s): image = frozen.screens.first { $0.screen == s }?.image
                case .window(let w, let s):
                    let local = w.frame.offsetBy(dx: -s.frame.minX, dy: -s.frame.minY).intersection(CGRect(origin: .zero, size: s.frame.size))
                    image = frozen.screens.first { $0.screen == s }.flatMap { ScreenCapture.crop($0, localRect: local) }
                }
                guard let image else { return }
                Telemetry.count(.captureText)
                let text = await Task.detached(priority: .userInitiated) { TextLayout.plainText(TextLayout.lines(in: image)) }.value
                if text.isEmpty {
                    HUD.show("Kein Text gefunden", symbol: "text.magnifyingglass")
                } else if source == .link {
                    LinkCommands.shared.confirmTextCopy(text) { self?.copyRecognized(text) }
                } else {
                    self?.copyRecognized(text)
                }
            }
        }
    }

    private func copyRecognized(_ text: String) {
        Clipboard.copy(text: text)
        let lines = text.split(separator: "\n").count
        HUD.show("Text kopiert · \(lines) Zeile\(lines == 1 ? "" : "n")", symbol: "text.viewfinder")
    }

    /// Ergebnis eines Scroll-Screenshots (`ScrollCaptureController`) — mit der Quelle, mit der er begonnen wurde.
    func finish(image: CGImage, scale: CGFloat, screen: NSScreen) {
        finish(image: image, scale: scale, screen: screen, source: scrollSource)
    }

    /// Legt die Aufnahme an. Kodieren und Schreiben laufen im Hintergrund; die Zwischenablage
    /// liefert die PNG-Daten erst, wenn eine App sie anfragt. Per Link ausgelöst (`source == .link`) kommt
    /// nichts von selbst in die Zwischenablage — kopieren geht dann über Karte oder Editor.
    @discardableResult
    func finish(image: CGImage, scale: CGFloat, screen: NSScreen, source: CaptureSource) -> CaptureItem? {
        let settings = AppSettings.shared
        let output = settings.outputPromise(sourceScale: scale) { image }
        do {
            let item = try CaptureStore.shared.addImage(image, scale: scale, output: output)
            if settings.copyToClipboard, source == .user { Clipboard.copy(output, fileURL: item.fileURL, item: item.id) }
            if settings.showQuickAccess { QuickAccessController.shared.show(item, on: screen) }
            if settings.openEditorAfterCapture { EditorWindowController.show(item) }
            return item
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: Bildschirmaufnahme

    func toggleRecording(source: CaptureSource = .user) {
        let recorder = RecordingController.shared
        if recorder.isBusy {
            // Läuft: speichern. Countdown: abbrechen.
            recorder.stop(save: true)
            return
        }
        presentOverlay(purpose: .recording, windowMode: false, source: source) { result, freeze in
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

    /// Bildschirm ab- oder angesteckt: Das Overlay passt nicht mehr zu den Bildschirmen — abbrechen.
    func screensChanged() {
        overlay?.finish(.cancelled)
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
