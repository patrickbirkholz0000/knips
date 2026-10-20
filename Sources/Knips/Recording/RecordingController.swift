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

    /// Rahmen in Aufnahme-Rot knapp außerhalb des Aufnahmebereichs (Knips-Fenster sind ohnehin nicht im Video).
    private func showFrame(around rect: CGRect) {
        frameWindow?.orderOut(nil)   // nie zwei Rahmen: ein alter bliebe sonst für immer stehen
        let outer = rect.insetBy(dx: -AreaFrame.outset, dy: -AreaFrame.outset)
        let panel = FloatingPanel.make(outer, ignoresMouse: true)
        panel.contentView = AreaFrame.makeView(size: outer.size, color: Brand.Dark.record)
        panel.orderFrontRegardless()
        frameWindow = panel
    }

    private func showCountdown(in rect: CGRect) {
        let host = FirstMouseHostingView(rootView: CountdownView(controller: self))
        let size = host.fittingSize
        let frame = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        let panel = FloatingPanel.make(frame, ignoresMouse: false)
        panel.contentView = host
        panel.orderFrontRegardless()
        countdownPanel = panel
    }

    private func showControls(for rect: CGRect, fullScreen: Bool) {
        let host = FirstMouseHostingView(rootView: RecordingControlsView(controller: self))
        // Die Pille ist kleiner als das Fenster: `RecordingBar.margin` rundherum für den Schatten.
        let size = host.fittingSize
        let m = RecordingBar.margin
        let vf = (screen ?? NSScreen.withMouse).visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12 + m)
        if fullScreen || origin.y < vf.minY + 4 - m {
            origin.y = rect.maxY + 12 - m
            if fullScreen || origin.y + size.height > vf.maxY - 4 + m { origin.y = max(vf.minY, rect.minY) + 16 - m }
        }
        origin.x = max(vf.minX + 8 - m, min(origin.x, vf.maxX - size.width - 8 + m))
        let panel = FloatingPanel.make(NSRect(origin: origin, size: size), ignoresMouse: false)
        panel.isMovableByWindowBackground = true
        panel.contentView = host
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

    private var number: Int {
        if case .countdown(let n) = controller.phase { return n }
        return 0
    }

    var body: some View {
        CountdownDial(number: number) { controller.stop(save: false) }
    }
}

/// Countdown vor dem Video (docs/design.md): dunkle runde Fläche, große Mono-Ziffer, roter Ring für die
/// verbleibenden Sekunden, darunter „Abbrechen“.
struct CountdownDial: View {
    /// 3, 2, 1 — 0 = noch nicht/nicht mehr im Countdown (Fläche ohne Ziffer).
    let number: Int
    var total = 3
    var cancel: () -> Void

    static let diameter: CGFloat = 132
    /// Platz rundherum für den Schatten.
    static let margin: CGFloat = 18

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().inset(by: 9).stroke(Color.brand(Brand.Dark.line), lineWidth: 3)
                Circle().inset(by: 9)
                    .trim(from: 0, to: CGFloat(max(0, min(number, total))) / CGFloat(total))
                    .stroke(Color.brand(Brand.Dark.record), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if number > 0 {
                    Text("\(number)")
                        .font(Brand.mono(58, .medium))
                        .foregroundStyle(Color.brand(Brand.Dark.ink))
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .darkSurface(Circle())
            .animation(.spring(duration: 0.35), value: number)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Aufnahme beginnt in \(number)")
            Button(action: cancel) { Text("Abbrechen") }
                .buttonStyle(DarkButtonStyle(kind: .raised, height: 28))
                .darkSurface(Capsule(), shadow: true)
        }
        .padding(Self.margin)
        .environment(\.colorScheme, .dark)
    }
}

private struct RecordingControlsView: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject private var settings = AppSettings.shared

    /// Das Mikrofon nimmt nur ab macOS 15 mit auf (`ScreenRecorder`).
    private var microphone: Bool {
        guard settings.recordingMicrophone else { return false }
        if #available(macOS 15.0, *) { return true }
        return false
    }

    var body: some View {
        RecordingBar(elapsed: controller.elapsed, microphone: microphone,
                     stop: { controller.stop(save: true) }, discard: { controller.stop(save: false) })
    }
}

/// Aufnahme-Leiste, solange ein Video läuft (docs/design.md): dunkle Pille, roter
/// pulsierender Punkt, Zeit in Mono, Mikrofon (wenn es mit aufnimmt), Verwerfen, „Stopp“ als Papier-Knopf.
struct RecordingBar: View {
    var elapsed: TimeInterval
    var microphone: Bool
    var stop: () -> Void
    var discard: () -> Void

    /// Platz rundherum für den Schatten.
    static let margin: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            RecordDot(size: 8)
            Text(Format.duration(elapsed))
                .font(Brand.mono(14, .semibold))
                .foregroundStyle(Color.brand(Brand.Dark.ink))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 42, alignment: .leading)
                .padding(.leading, 8)
                .accessibilityLabel("Aufnahme läuft, \(Format.duration(elapsed))")
            if microphone {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.brand(Brand.Dark.accent))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.brand(Brand.Dark.accentSoft)))
                    .padding(.leading, 8)
                    .help("Mikrofon nimmt mit auf")
                    .accessibilityLabel("Mikrofon nimmt mit auf")
            }
            Spacer(minLength: 16)
            Button(action: discard) { Image(systemName: "trash") }
                .buttonStyle(DarkIconButtonStyle(size: 30, symbolSize: 11.5, filled: false, tint: Brand.Dark.muted))
                .help("Aufnahme verwerfen")
                .accessibilityLabel("Aufnahme verwerfen")
            Button(action: stop) { Label("Stopp", systemImage: "stop.fill") }
                .buttonStyle(DarkButtonStyle(kind: .primary, height: 30, fontSize: 13))
                .help("Aufnahme beenden und speichern")
                .padding(.leading, 6)
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(height: 44)
        .fixedSize()
        .darkSurface(Capsule())
        .padding(Self.margin)
        .environment(\.colorScheme, .dark)
    }
}
