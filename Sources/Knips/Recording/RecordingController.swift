import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    enum Phase: Equatable { case idle, countdown(Int), recording, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase != .idle }

    private var recorder: ScreenRecorder?
    private var startDate: Date?
    private var ticker: Timer?
    private var countdownTask: Task<Void, Never>?
    private var frameWindow: NSWindow?
    private var controlPanel: NSPanel?
    private var countdownPanel: NSPanel?
    private var screen: NSScreen?
    private var scale: CGFloat = 2

    /// localRect: Punkte relativ zum Bildschirm, Ursprung unten links.
    func begin(screen: NSScreen, display: SCDisplay, localRect: CGRect, content: SCShareableContent) {
        guard phase == .idle, localRect.width >= 16, localRect.height >= 16 else { return }
        self.screen = screen
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
        recorder.onStreamError = { [weak self] error in
            DispatchQueue.main.async {
                onMainActor {
                    Log.error("Aufnahme-Stream beendet: \(error.localizedDescription)")
                    if self?.phase == .recording { self?.stop(save: true) }
                }
            }
        }
        self.recorder = recorder
        let options = ScreenRecorder.Options(display: display, sourceRect: sourceRect, pixelSize: pixelSize,
                                             excludedApps: ScreenCapture.ownApp(in: content).map { [$0] } ?? [],
                                             fps: settings.recordingFPS, showsCursor: settings.recordingShowCursor,
                                             microphone: settings.recordingMicrophone, hevc: settings.recordingHEVC,
                                             showsClicks: settings.recordingShowClicks)
        if !isFull { showFrame(around: global) }
        StatusBarController.shared?.refreshRecordingState()

        countdownTask = Task { [weak self] in
            guard let self else { return }
            if settings.recordingCountdown {
                self.showCountdown(in: global)
                for n in stride(from: 3, through: 1, by: -1) {
                    self.phase = .countdown(n)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                self.countdownPanel?.orderOut(nil)
                self.countdownPanel = nil
            }
            if Task.isCancelled { return }
            do {
                try await recorder.start(options)
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
                self.showControls(for: global, fullScreen: isFull)
                StatusBarController.shared?.refreshRecordingState()
            } catch {
                self.teardown()
                Alerts.error("Aufnahme konnte nicht starten", error)
            }
        }
    }

    func stop(save: Bool) {
        switch phase {
        case .idle, .finishing:
            return
        case .countdown:
            countdownTask?.cancel()
            teardown()
            return
        case .recording:
            break
        }
        phase = .finishing
        ticker?.invalidate()
        ticker = nil
        frameWindow?.orderOut(nil)
        controlPanel?.orderOut(nil)
        StatusBarController.shared?.refreshRecordingState()
        guard let recorder else { teardown(); return }
        let screen = self.screen ?? NSScreen.withMouse
        let scale = self.scale
        Task {
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
                Alerts.error("Aufnahme konnte nicht gespeichert werden", error)
            }
        }
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
