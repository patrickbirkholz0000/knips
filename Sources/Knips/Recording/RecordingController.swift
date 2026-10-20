import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    /// `starting`: Bereich gewählt, Recorder startet (vor und nach dem Countdown) — gilt schon als belegt.
    enum Phase: Equatable { case idle, starting, countdown(Int), recording, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase != .idle }

    /// Meldung an den Nutzer (Titel, Fehler, Text). Selbsttests sammeln sie, statt einen Dialog zu zeigen.
    var onError: (String, Error?, String?) -> Void = { title, error, info in Alerts.error(title, error, info: info) }

    private var recorder: RecordingSession?
    private var startDate: Date?
    private var ticker: Timer?
    private var countdownTask: Task<Void, Never>?
    /// Stoppen und Speichern — Beenden der App wartet darauf.
    private var finishTask: Task<Void, Never>?
    private var frameWindow: NSWindow?
    private var controlPanel: NSPanel?
    private var countdownPanel: NSPanel?
    private var screen: NSScreen?
    private var scale: CGFloat = 2
    private var showsWindows = true

    /// localRect: Punkte relativ zum Bildschirm, Ursprung unten links.
    func begin(screen: NSScreen, display: SCDisplay, localRect: CGRect, content: SCShareableContent) {
        guard phase == .idle, localRect.width >= 16, localRect.height >= 16 else { return }
        let settings = AppSettings.shared
        let global = localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let isFull = localRect.size == screen.frame.size

        var pxScale = settings.recordingAtScreenSize ? 1 : screen.backingScaleFactor
        let longest = max(localRect.width, localRect.height) * pxScale
        if longest > 4096 { pxScale *= 4096 / longest }
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }
        let pixelSize = CGSize(width: even(localRect.width * pxScale), height: even(localRect.height * pxScale))
        scale = pxScale
        let sourceRect = CGRect(x: localRect.minX, y: screen.frame.height - localRect.maxY, width: localRect.width, height: localRect.height)

        let url = Paths.temp.appendingPathComponent("aufnahme-\(UUID().uuidString).mp4")
        let recorder = ScreenRecorder(url: url)
        let options = ScreenRecorder.Options(display: display, sourceRect: sourceRect, pixelSize: pixelSize,
                                             excludedApps: ScreenCapture.ownApp(in: content).map { [$0] } ?? [],
                                             fps: settings.recordingFPS, showsCursor: settings.recordingShowCursor,
                                             microphone: settings.recordingMicrophone, hevc: settings.recordingHEVC,
                                             showsClicks: settings.recordingShowClicks)
        let session = ScreenRecordingSession(recorder: recorder, options: options)
        recorder.onStreamError = { [weak self, weak session] error in
            DispatchQueue.main.async {
                onMainActor { self?.streamFailed(error, from: session) }
            }
        }
        recorder.onWriterError = { [weak self, weak session] error in
            DispatchQueue.main.async {
                onMainActor { self?.writerFailed(error, from: session) }
            }
        }
        run(session, screen: screen, global: global, isFull: isFull, countdown: settings.recordingCountdown)
    }

    /// Countdown → Start → Aufnahme. `showsWindows: false` nur im Selbsttest (Attrappe ohne Bildschirm).
    func run(_ session: RecordingSession, screen: NSScreen?, global: CGRect, isFull: Bool, countdown: Bool, showsWindows: Bool = true) {
        guard phase == .idle else { return }
        self.screen = screen
        self.showsWindows = showsWindows
        recorder = session
        // Ab hier belegt: Ein zweites ⌘⇧5 während des Starts legt keinen zweiten Recorder an.
        phase = .starting
        if showsWindows, !isFull { showFrame(around: global) }
        StatusBarController.shared?.refreshRecordingState()

        countdownTask = Task { [weak self] in
            guard let self else { return }
            if countdown {
                if showsWindows { self.showCountdown(in: global) }
                for n in stride(from: 3, through: 1, by: -1) {
                    self.phase = .countdown(n)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                self.countdownPanel?.orderOut(nil)
                self.countdownPanel = nil
                self.phase = .starting
            }
            if Task.isCancelled { return }
            do {
                try await session.start()
            } catch {
                // Halb gestarteten Stream und angelegte Datei aufräumen.
                await session.cancel()
                guard !Task.isCancelled, self.recorder === session else { return }
                self.teardown()
                self.onError("Aufnahme konnte nicht starten", error, nil)
                return
            }
            // Während des Starts abgebrochen (Esc, zweites ⌘⇧5, Beenden): Stream gleich wieder schließen,
            // sonst liefe eine Aufnahme ohne Rahmen und ohne Stopp-Knopf weiter.
            guard !Task.isCancelled, self.recorder === session else {
                await session.cancel()
                return
            }
            self.phase = .recording
            Telemetry.count(.recordingStart)
            self.startDate = Date()
            self.elapsed = 0
            self.ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                onMainActor {
                    guard let start = RecordingController.shared.startDate else { return }
                    RecordingController.shared.elapsed = Date().timeIntervalSince(start)
                }
            }
            if showsWindows { self.showControls(for: global, fullScreen: isFull) }
            StatusBarController.shared?.refreshRecordingState()
        }
    }

    func stop(save: Bool) {
        switch phase {
        case .idle, .finishing:
            return
        case .starting, .countdown:
            // Noch nichts aufgenommen: abbrechen. Ein Start, der noch läuft, räumt seinen Recorder selbst ab.
            countdownTask?.cancel()
            teardown()
            return
        case .recording:
            break
        }
        phase = .finishing
        hideWindows()
        guard let recorder else { teardown(); return }
        let screen = self.screen ?? NSScreen.withMouse
        let scale = self.scale
        finishTask = Task {
            if !save {
                await recorder.cancel()
                teardown()
                HUD.show("Aufnahme verworfen", symbol: "trash.fill")
                return
            }
            do {
                _ = try await recorder.stop()
                let item = try await CaptureStore.shared.addVideo(from: recorder.url, scale: scale)
                Telemetry.count(.recordingSaved)
                teardown()
                let settings = AppSettings.shared
                if settings.copyToClipboard { Clipboard.copy(fileURL: item.fileURL) }
                if settings.showQuickAccess { QuickAccessController.shared.show(item, on: screen) }
            } catch {
                teardown()
                // Unvollständige Datei (kein Bild, Writer-Fehler) ist unbrauchbar und bleibt nicht liegen.
                if error is ScreenRecorder.RecorderError { try? FileManager.default.removeItem(at: recorder.url) }
                onError("Aufnahme konnte nicht gespeichert werden", error, nil)
            }
        }
    }

    /// Beenden der App: laufende Aufnahme speichern (Countdown/Start verwerfen) und warten, bis sie angelegt ist.
    func finishForQuit() async {
        switch phase {
        case .recording: stop(save: true)
        case .starting, .countdown: stop(save: false)
        case .idle, .finishing: break
        }
        await finishTask?.value
    }

    /// Stream beendet (Bildschirm abgesteckt, Freigabe entzogen): speichern, was da ist.
    private func streamFailed(_ error: Error, from session: RecordingSession?) {
        guard let session, recorder === session else { return }
        Log.error("Aufnahme-Stream beendet: \(error.localizedDescription)")
        if phase == .recording { stop(save: true) }
    }

    /// Writer nimmt nichts mehr an (z. B. Platte voll): sofort beenden, Teildatei löschen, Bescheid geben.
    private func writerFailed(_ error: Error, from session: RecordingSession?) {
        guard let session, recorder === session, phase == .recording else { return }
        Log.error("Aufnahme abgebrochen, Writer-Fehler: \(error.localizedDescription)")
        phase = .finishing
        hideWindows()
        finishTask = Task {
            await session.cancel()
            teardown()
            onError("Aufnahme abgebrochen", error,
                    "Das Video konnte nicht weiter geschrieben werden (\(error.localizedDescription)). Ist der Speicherplatz voll? "
                        + "Die unvollständige Datei wurde gelöscht.")
        }
    }

    #if KNIPS_DEV
    /// Nur Selbsttest: Writer-Fehler der laufenden Attrappe auslösen.
    func debugWriterFailed(_ error: Error) { writerFailed(error, from: recorder) }
    #endif

    private func hideWindows() {
        ticker?.invalidate()
        ticker = nil
        frameWindow?.orderOut(nil)
        controlPanel?.orderOut(nil)
        StatusBarController.shared?.refreshRecordingState()
    }

    private func teardown() {
        countdownTask = nil
        ticker?.invalidate()
        ticker = nil
        recorder = nil
        startDate = nil
        elapsed = 0
        frameWindow?.orderOut(nil)
        frameWindow = nil
        controlPanel?.orderOut(nil)
        controlPanel = nil
        countdownPanel?.orderOut(nil)
        countdownPanel = nil
        phase = .idle
        StatusBarController.shared?.refreshRecordingState()
    }

    // MARK: Fenster

    private func makePanel(_ rect: NSRect, ignoresMouse: Bool) -> NSPanel {
        let p = ClickablePanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = ignoresMouse
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.setFrame(rect, display: false)
        return p
    }

    /// Gestrichelter Rahmen knapp außerhalb des Aufnahmebereichs (Knips-Fenster sind ohnehin nicht im Video).
    private func showFrame(around rect: CGRect) {
        frameWindow?.orderOut(nil)   // nie zwei Rahmen: ein alter bliebe sonst für immer stehen
        let outer = rect.insetBy(dx: -3, dy: -3)
        let panel = makePanel(outer, ignoresMouse: true)
        let view = NSView(frame: NSRect(origin: .zero, size: outer.size))
        view.wantsLayer = true
        let shape = CAShapeLayer()
        shape.path = CGPath(rect: CGRect(origin: .zero, size: outer.size).insetBy(dx: 1, dy: 1), transform: nil)
        shape.fillColor = nil
        shape.strokeColor = NSColor.systemRed.cgColor
        shape.lineWidth = 2
        shape.lineDashPattern = [6, 4]
        view.layer?.addSublayer(shape)
        panel.contentView = view
        panel.orderFrontRegardless()
        frameWindow = panel
    }

    private func showCountdown(in rect: CGRect) {
        let size = CGSize(width: 150, height: 176)
        let frame = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        let panel = makePanel(frame, ignoresMouse: false)
        panel.contentView = FirstMouseHostingView(rootView: CountdownView(controller: self))
        panel.orderFrontRegardless()
        countdownPanel = panel
    }

    private func showControls(for rect: CGRect, fullScreen: Bool) {
        let size = CGSize(width: 246, height: 44)
        let vf = (screen ?? NSScreen.withMouse).visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if fullScreen || origin.y < vf.minY + 4 {
            origin.y = rect.maxY + 12
            if fullScreen || origin.y + size.height > vf.maxY - 4 { origin.y = max(vf.minY, rect.minY) + 16 }
        }
        origin.x = max(vf.minX + 8, min(origin.x, vf.maxX - size.width - 8))
        let panel = makePanel(NSRect(origin: origin, size: size), ignoresMouse: false)
        panel.isMovableByWindowBackground = true
        panel.contentView = FirstMouseHostingView(rootView: RecordingControlsView(controller: self))
        panel.orderFrontRegardless()
        controlPanel = panel
    }
}

final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CountdownView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.black.opacity(0.72))
                Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                if case .countdown(let n) = controller.phase {
                    Text("\(n)")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.spring(duration: 0.3), value: n)
                }
            }
            .frame(width: 128, height: 128)
            Button { controller.stop(save: false) } label: {
                Text("Abbrechen")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordingControlsView: View {
    @ObservedObject var controller: RecordingController
    @State private var blink = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(blink ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: blink)
                .onAppear { blink = true }
            Text(Format.duration(controller.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 44, alignment: .leading)
            Button { controller.stop(save: true) } label: {
                Label("Stopp", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.red))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Aufnahme beenden und speichern")
            Button { controller.stop(save: false) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Aufnahme verwerfen")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color(white: 0.09).opacity(0.92)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
    }
}
