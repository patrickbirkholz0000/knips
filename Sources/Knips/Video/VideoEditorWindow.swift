import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [UUID: VideoEditorWindowController] = [:]
    private static var loading: Set<UUID> = []

    let model: VideoEditorModel
    private var allowClose = false

    static func show(_ item: CaptureItem) {
        if let existing = open[item.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard !loading.contains(item.id) else { return }
        loading.insert(item.id)
        Task {
            defer { loading.remove(item.id) }
            do {
                let model = try await VideoEditorModel.load(item)
                let controller = VideoEditorWindowController(model: model)
                open[item.id] = controller
                Telemetry.count(.videoEditorOpen)
                DockPresence.windowOpened()
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
            } catch {
                Alerts.error("Video konnte nicht geöffnet werden", error)
            }
        }
    }

    init(model: VideoEditorModel) {
        self.model = model
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.applyEditorChrome()
        window.isReleasedWhenClosed = false
        window.title = model.item.title
        window.minSize = NSSize(width: EditorChrome.minWidth, height: 600)
        super.init(window: window)
        window.delegate = self
        let canvas = VideoCanvasView(model: model)
        let host = NSHostingView(rootView: VideoEditorRoot(model: model, canvas: canvas, actions: VideoEditorActions(
            save: { [weak self] in self?.save(close: false) },
            done: { [weak self] in self?.save(close: true) },
            copy: { [weak self] in self?.copyFile() },
            reveal: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([self.model.item.fileURL])
            }
        )))
        // Nur die Mindestgröße kommt aus SwiftUI; die Leisten passen sich der Breite an (ViewThatFits).
        host.sizingOptions = [.minSize]
        window.contentView = host
        let vf = NSScreen.withMouse.visibleFrame
        let scale = CGFloat(max(1, model.item.scale))
        let w = min(max(model.videoSize.width / scale + 96, 980), vf.width * 0.9)
        let h = min(max(model.videoSize.height / scale + 300, 600), vf.height * 0.9)
        window.setContentSize(NSSize(width: w, height: h))
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    private func save(close: Bool) {
        Task {
            let ok = await model.save()
            if ok && close {
                allowClose = true
                window?.close()
            }
        }
    }

    private func copyFile() {
        Task {
            if model.dirty { _ = await model.save() }
            Clipboard.copy(fileURL: model.item.fileURL)
            model.showToast("Datei kopiert — in Slack, Mail usw. einfügen")
        }
    }

    @objc func saveDocument(_ sender: Any?) { save(close: false) }
    @objc func undo(_ sender: Any?) { model.undo() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose || !model.dirty { return true }
        let alert = NSAlert()
        alert.messageText = "Änderungen am Video speichern?"
        alert.informativeText = "Zensur und Kürzung werden erst beim Speichern ins Video geschrieben."
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Verwerfen")
        alert.addButton(withTitle: "Abbrechen")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save(close: true)
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // Im Vollbild läge die leere Werkzeugleiste als eigenes Fenster über der oberen Leiste — dort ausblenden.
    func windowWillEnterFullScreen(_ notification: Notification) { window?.toolbar?.isVisible = false }
    func windowDidExitFullScreen(_ notification: Notification) { window?.toolbar?.isVisible = true }

    func windowWillClose(_ notification: Notification) {
        model.shutdown()
        Self.open[model.item.id] = nil
        DockPresence.windowClosed()
    }
}

struct VideoEditorActions {
    var save: () -> Void
    var done: () -> Void
    var copy: () -> Void
    var reveal: () -> Void
}

// MARK: - Video-Fläche

/// Zeigt das Video (mit Live-Zensur über die Komposition) und nimmt Rechtecke entgegen.
final class VideoCanvasView: NSView {
    let model: VideoEditorModel
    private let playerLayer = AVPlayerLayer()
    /// Leichter Schatten unter dem Video (wie unter dem Bild im Bild-Editor).
    private let shadowLayer = CALayer()
    private let overlayView = VideoOverlayView()
    private var cancellables: Set<AnyCancellable> = []
    private var draft: CGRect?

    private enum Drag { case none, draw(CGPoint), move(UUID, CGPoint, Bool), resize(UUID, anchor: CGPoint) }
    private var drag: Drag = .none

    init(model: VideoEditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        applyColors()
        shadowLayer.shadowOffset = CGSize(width: 0, height: -3)
        layer?.addSublayer(shadowLayer)
        playerLayer.player = model.player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        overlayView.canvas = self
        addSubview(overlayView)
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.overlayView.needsDisplay = true } }
            .store(in: &cancellables)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        overlayView.needsDisplay = true
    }

    /// Bühne `fill` mit Linie und Radius wie im Bild-Editor; Schatten im Dunkeln kräftiger.
    private func applyColors() {
        applyStageLayerStyle()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Brand.fill.cgColor
            shadowLayer.backgroundColor = Brand.surface.cgColor
        }
        shadowLayer.shadowOpacity = dark ? 0.45 : 0.12
        shadowLayer.shadowRadius = dark ? 9 : 7
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Gleicher Rand wie `videoRect`, sonst sitzen die Rahmen neben der Zensur.
        playerLayer.frame = bounds.insetBy(dx: 16, dy: 16)
        shadowLayer.frame = videoRect
        CATransaction.commit()
        overlayView.frame = bounds
        overlayView.needsDisplay = true
    }

    var videoRect: CGRect { AVMakeRect(aspectRatio: model.videoSize, insideRect: bounds.insetBy(dx: 16, dy: 16)) }
    private var factor: CGFloat { videoRect.width / max(1, model.videoSize.width) }

    private func toVideo(_ p: CGPoint) -> CGPoint {
        let r = videoRect, f = factor
        return CGPoint(x: max(0, min((p.x - r.minX) / f, model.videoSize.width)), y: max(0, min((p.y - r.minY) / f, model.videoSize.height)))
    }

    func toView(_ r: CGRect) -> CGRect {
        let v = videoRect, f = factor
        return CGRect(x: v.minX + r.minX * f, y: v.minY + r.minY * f, width: r.width * f, height: r.height * f)
    }

    /// Zeichnet Rahmen der aktiven Felder, die Auswahl mit Griffen und das Feld, das gerade gezogen wird.
    /// Alles in Königsblau — Rot heißt bei Knips nur „es nimmt auf“.
    func drawOverlay(_ ctx: CGContext) {
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(Brand.accent.withAlphaComponent(0.85).cgColor)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        for r in model.redactions where r.id != model.selectedID && model.isActive(r) {
            ctx.stroke(toView(r.rect(at: model.currentTime)))
        }
        ctx.setLineDash(phase: 0, lengths: [])
        if let sel = model.selected {
            let vr = toView(sel.rect(at: model.currentTime))
            let alpha: CGFloat = model.isActive(sel) ? 1 : 0.45
            ctx.setStrokeColor(Brand.accent.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(vr)
            for c in [CGPoint(x: vr.minX, y: vr.minY), CGPoint(x: vr.maxX, y: vr.minY), CGPoint(x: vr.minX, y: vr.maxY), CGPoint(x: vr.maxX, y: vr.maxY)] {
                let h = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
                ctx.setFillColor(Brand.Dark.ink.cgColor)
                ctx.fillEllipse(in: h)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: h)
            }
        }
        if let draft {
            let v = toView(draft)
            ctx.setFillColor(Brand.accent.withAlphaComponent(0.2).cgColor)
            ctx.fill(v)
            ctx.setStrokeColor(Brand.accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(v)
        }
    }

    private func handleHit(_ p: CGPoint) -> (UUID, CGPoint)? {
        guard let sel = model.selected else { return nil }
        let current = sel.rect(at: model.currentTime)
        let r = toView(current)
        let corners: [(CGPoint, CGPoint)] = [
            (CGPoint(x: r.minX, y: r.minY), CGPoint(x: current.maxX, y: current.maxY)),
            (CGPoint(x: r.maxX, y: r.minY), CGPoint(x: current.minX, y: current.maxY)),
            (CGPoint(x: r.minX, y: r.maxY), CGPoint(x: current.maxX, y: current.minY)),
            (CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: current.minX, y: current.minY)),
        ]
        for (corner, anchor) in corners where hypot(corner.x - p.x, corner.y - p.y) <= 9 { return (sel.id, anchor) }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let (id, anchor) = handleHit(p) {
            model.checkpoint()
            drag = .resize(id, anchor: anchor)
            return
        }
        let vp = toVideo(p)
        let candidates = model.redactions.filter { $0.id == model.selectedID || model.isActive($0) }
        if let hit = candidates.reversed().first(where: { $0.rect(at: model.currentTime).contains(vp) }) {
            model.selectedID = hit.id
            drag = .move(hit.id, vp, false)
            return
        }
        model.selectedID = nil
        guard videoRect.contains(p) else { drag = .none; return }
        drag = .draw(vp)
    }

    override func mouseDragged(with event: NSEvent) {
        let vp = toVideo(convert(event.locationInWindow, from: nil))
        switch drag {
        case .none: break
        case .draw(let start):
            draft = CGRect(x: min(start.x, vp.x), y: min(start.y, vp.y), width: abs(vp.x - start.x), height: abs(vp.y - start.y))
            overlayView.needsDisplay = true
        case .move(let id, let last, let moved):
            if !moved { model.checkpoint() }
            let dx = vp.x - last.x, dy = vp.y - last.y
            let size = model.videoSize
            model.updateRedaction(id, refresh: false) { r in
                // Mitlaufende Balken verschieben sich als Ganzes.
                let x = max(0, min(r.rect.origin.x + dx, size.width - r.rect.width)) - r.rect.origin.x
                let y = max(0, min(r.rect.origin.y + dy, size.height - r.rect.height)) - r.rect.origin.y
                r.offset(dx: x, dy: y)
            }
            drag = .move(id, vp, true)
        case .resize(let id, let anchor):
            model.updateRedaction(id, refresh: false) { r in
                r.rect = CGRect(x: min(anchor.x, vp.x), y: min(anchor.y, vp.y), width: abs(vp.x - anchor.x), height: abs(vp.y - anchor.y))
                r.track = nil   // neue Größe: Verfolgung neu starten
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .draw:
            if let r = draft, r.width * factor >= 6, r.height * factor >= 6 {
                model.addRedaction(rect: r)
                Telemetry.count(.censorManual)
            }
            draft = nil
            overlayView.needsDisplay = true
        case .move(_, _, true), .resize:
            model.refreshFrame()
        default:
            break
        }
        drag = .none
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: model.togglePlay()
        case 51, 117: model.deleteSelected()
        case 53: model.selectedID = nil
        case 123: model.seek(to: model.currentTime - (event.modifierFlags.contains(.shift) ? 1 : 1.0 / 30))
        case 124: model.seek(to: model.currentTime + (event.modifierFlags.contains(.shift) ? 1 : 1.0 / 30))
        default: super.keyDown(with: event)
        }
    }
}

/// Transparente Zeichenebene über dem Video; Klicks gehen an die Canvas darunter.
final class VideoOverlayView: NSView {
    weak var canvas: VideoCanvasView?
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        canvas?.drawOverlay(ctx)
    }
}

private struct VideoCanvasHost: NSViewRepresentable {
    let canvas: VideoCanvasView
    func makeNSView(context: Context) -> VideoCanvasView { canvas }
    func updateNSView(_ nsView: VideoCanvasView, context: Context) {}
}

// MARK: - SwiftUI

/// Video-Editor (docs/design.md, „Video-Editor“): wie der Bild-Editor — oben Zensur-Stil und Aktionen
/// (Export rechts oben), in der Mitte die Bühne, unten die Zeitleiste als weiße Karte.
struct VideoEditorRoot: View {
    @ObservedObject var model: VideoEditorModel
    let canvas: VideoCanvasView
    let actions: VideoEditorActions

    var body: some View {
        VStack(spacing: 0) {
            VideoEditorToolbar(model: model, actions: actions)
            ZStack(alignment: .bottom) {
                VideoCanvasHost(canvas: canvas)
                if let busy = model.busy {
                    EditorHUD(text: busy, progress: model.progress ?? 0).padding(.bottom, 16)
                } else if let toast = model.toast {
                    EditorHUD(text: toast, symbol: "checkmark.circle.fill").padding(.bottom, 16)
                }
            }
            .padding(.horizontal, EditorChrome.margin)
            VideoTimelineCard(model: model)
                .padding(EditorChrome.margin)
        }
        .background(Color.brand(Brand.canvas))
        .ignoresSafeArea()
    }
}

/// Obere Leiste: Zensur (Hinweis + Stil) als Gruppe, rechts Widerrufen, Ordner, GIF, Kopieren, Fertig.
private struct VideoEditorToolbar: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject private var settings = AppSettings.shared
    let actions: VideoEditorActions

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: EditorChrome.trafficLights)
            ViewThatFits(in: .horizontal) {
                row(hint: true, labels: true)
                row(hint: false, labels: true)
                row(hint: false, labels: false)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: EditorChrome.topBarHeight)
        .background { shortcuts }
    }

    /// ⌘Z und ⌘⏎ außerhalb von ViewThatFits, damit jedes Kürzel genau einmal gilt (nicht je Fassung der Leiste).
    private var shortcuts: some View {
        ZStack {
            Button("Widerrufen") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
            Button("Fertig") { actions.done() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.busy != nil)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(hint: Bool, labels: Bool) -> some View {
        HStack(spacing: 10) {
            redactGroup(hint: hint, labels: labels)
            if settings.showAutoRedact {
                Button { model.autoRedact() } label: {
                    if labels { Label("Auto-Zensur", systemImage: "wand.and.stars") } else { Image(systemName: "wand.and.stars") }
                }
                .buttonStyle(BrandButtonStyle(kind: .secondary))
                .disabled(model.busy != nil)
                .help("Erkennt E-Mails, IBANs, Telefonnummern, Schlüssel usw. in Einzelbildern (alle 0,5 s) und legt Zensurfelder an.")
                .accessibilityLabel("Auto-Zensur")
            }
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                ChromeToolButton(symbol: "arrow.uturn.backward", enabled: model.canUndo, help: "Widerrufen (⌘Z)") { model.undo() }
                ChromeToolButton(symbol: "folder", help: "Im Finder zeigen", action: actions.reveal)
            }
            Button { model.exportGIF() } label: { Label("GIF", systemImage: "photo.stack") }
                .buttonStyle(BrandButtonStyle(kind: .secondary))
                .disabled(model.busy != nil)
                .help("Als GIF exportieren (\(settings.gifFPS) fps, max. \(settings.gifWidth) px breit)")
            Button { actions.copy() } label: { Label("Kopieren", systemImage: "doc.on.doc") }
                .buttonStyle(BrandButtonStyle(kind: .secondary))
                .disabled(model.busy != nil)
                .help("Videodatei kopieren")
            Button("Fertig") { actions.done() }
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .disabled(model.busy != nil)
                .help("Als MP4 speichern und schließen (⌘⏎)")
        }
    }

    private func redactGroup(hint: Bool, labels: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "eye.slash").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.brand(Brand.accent))
                Text(hint ? "Rechteck ziehen = zensieren" : "Zensieren")
                    .font(Brand.font(13, .medium))
                    .foregroundStyle(Color.brand(Brand.ink))
                    .fixedSize()
            }
            .padding(.leading, 8)
            ChromeDivider()
            BrandSegment(items: RedactStyle.allCases.map { .init(value: $0, title: labels ? $0.title : nil, symbol: $0.symbol, help: $0.title) },
                         selection: model.selected?.style ?? model.style, height: 28) { model.setStyle($0) }
        }
        .frame(height: EditorChrome.toolSize)
        .chromeGroup()
    }
}

/// Zeitleiste als weiße Karte: Abspielen, Zeit in Mono, Vorschaubilder mit Kürzen-Griffen (Tinte) und
/// Zensurbereichen (Königsblau), darunter die Auswahl.
private struct VideoTimelineCard: View {
    @ObservedObject var model: VideoEditorModel

    private var trimmed: Bool { model.trimStart > 0.001 || model.trimEnd < model.duration - 0.001 }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.brand(Brand.buttonFill)))
                        .foregroundStyle(Color.brand(Brand.buttonInk))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? "Anhalten (Leertaste)" : "Abspielen (Leertaste)")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text(Format.preciseDuration(model.currentTime)).foregroundStyle(Color.brand(Brand.ink))
                        Text(" / \(Format.preciseDuration(model.duration))").foregroundStyle(Color.brand(Brand.inkSoft))
                    }
                    .font(Brand.mono(12, .medium))
                    if trimmed {
                        Text("gekürzt auf \(Format.preciseDuration(model.trimEnd - model.trimStart))")
                            .font(Brand.mono(11))
                            .foregroundStyle(Color.brand(Brand.inkSoft))
                    }
                }
                .fixedSize()
                .frame(minWidth: 128, alignment: .leading)
                TimelineBar(model: model)
            }
            Rectangle().fill(Color.brand(Brand.line)).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                selectionBar(compact: false)
                selectionBar(compact: true)
            }
            .frame(height: 28)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous).fill(Color.brand(Brand.surface)))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous).strokeBorder(Color.brand(Brand.line)))
    }

    @ViewBuilder private func selectionBar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let sel = model.selected, let index = model.redactions.firstIndex(where: { $0.id == sel.id }) {
                Text("Zensur \(index + 1)\(sel.auto ? " (auto)" : "")\(sel.track != nil ? " · folgt" : "")")
                    .font(Brand.font(13, .semibold))
                    .foregroundStyle(Color.brand(Brand.ink))
                    .fixedSize()
                Text("\(Format.preciseDuration(sel.start)) – \(Format.preciseDuration(sel.end))")
                    .font(Brand.mono(11.5))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
                    .fixedSize()
                    .padding(.trailing, 4)
                Button("Ab hier") { model.selectedStartHere() }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, height: 28))
                    .help("Zensur beginnt an der aktuellen Abspielposition")
                Button("Bis hier") { model.selectedEndHere() }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, height: 28))
                    .help("Zensur endet an der aktuellen Abspielposition")
                Button("Ganze Länge") { model.selectedWholeClip() }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, height: 28))
                if sel.track == nil {
                    Button { model.followSelected() } label: { label("Folgen", "scope", compact: compact) }
                        .buttonStyle(BrandButtonStyle(kind: .secondary, height: 28))
                        .disabled(model.busy != nil)
                        .help("Balken folgt dem Inhalt darunter, z. B. beim Scrollen — ab der aktuellen Position vor und zurück.")
                        .accessibilityLabel("Folgen")
                } else {
                    Button { model.unfollowSelected() } label: { label("Fest", "pin", compact: compact) }
                        .buttonStyle(BrandButtonStyle(kind: .secondary, height: 28))
                        .help("Balken bleibt an der aktuellen Stelle stehen")
                        .accessibilityLabel("Fest")
                }
                Spacer(minLength: 8)
                Button { model.deleteSelected() } label: { label("Löschen", "trash", compact: compact) }
                    .buttonStyle(BrandButtonStyle(kind: .quiet, height: 28))
                    .help("Zensur löschen (⌫)")
                    .accessibilityLabel("Löschen")
            } else {
                Text(model.redactions.isEmpty
                     ? "Die Griffe an der Zeitleiste kürzen das Video. Leertaste spielt ab, ← → springen einzelne Bilder."
                     : "\(model.redactions.count) Zensurfeld\(model.redactions.count == 1 ? "" : "er") — anklicken, um Zeitraum oder Stil zu ändern.")
                    .font(Brand.font(12.5))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
                    .lineLimit(compact ? 2 : 1)
                    .fixedSize(horizontal: !compact, vertical: false)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func label(_ title: String, _ symbol: String, compact: Bool) -> some View {
        if compact { Image(systemName: symbol) } else { Label(title, systemImage: symbol) }
    }
}

/// Zeitleiste mit Vorschaubildern, Kürzen-Griffen in Tinte, Abspielkopf in Tinte und Zensur-Spuren in Königsblau.
struct TimelineBar: View {
    @ObservedObject var model: VideoEditorModel
    @State private var trimDragStart: (Double, Double)?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(model.duration, 0.001)
            let x = { (t: Double) -> CGFloat in CGFloat(t / d) * w }
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, img in
                            Image(decorative: img, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: w / CGFloat(max(1, model.thumbnails.count)), height: 40)
                                .clipped()
                        }
                    }
                    .frame(width: w, height: 40, alignment: .leading)
                    .background(Color.brand(Brand.fill))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        model.seek(to: Double(max(0, min(v.location.x, w)) / w) * d)
                    })
                    // Außerhalb der Kürzung: Papier-Schleier (wird nicht gespeichert)
                    Rectangle().fill(Color.brand(Brand.surface).opacity(0.72))
                        .frame(width: max(0, x(model.trimStart)), height: 40)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8, style: .continuous))
                        .allowsHitTesting(false)
                    Rectangle().fill(Color.brand(Brand.surface).opacity(0.72))
                        .frame(width: max(0, w - x(model.trimEnd)), height: 40)
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 8, style: .continuous))
                        .offset(x: x(model.trimEnd)).allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.brand(Brand.ink), lineWidth: 2)
                        .frame(width: max(4, x(model.trimEnd) - x(model.trimStart)), height: 40)
                        .offset(x: x(model.trimStart))
                        .allowsHitTesting(false)
                    trimHandle(left: true).offset(x: x(model.trimStart) - 6)
                        .gesture(DragGesture().onChanged { v in
                            if trimDragStart == nil { trimDragStart = (model.trimStart, model.trimEnd); model.checkpoint() }
                            model.setTrim(start: (trimDragStart?.0 ?? 0) + Double(v.translation.width / w) * d)
                            model.seek(to: model.trimStart)
                        }.onEnded { _ in trimDragStart = nil })
                        .help("Anfang kürzen")
                    trimHandle(left: false).offset(x: x(model.trimEnd) - 6)
                        .gesture(DragGesture().onChanged { v in
                            if trimDragStart == nil { trimDragStart = (model.trimStart, model.trimEnd); model.checkpoint() }
                            model.setTrim(end: (trimDragStart?.1 ?? d) + Double(v.translation.width / w) * d)
                            model.seek(to: model.trimEnd)
                        }.onEnded { _ in trimDragStart = nil })
                        .help("Ende kürzen")
                    playhead.offset(x: x(model.currentTime) - 5).allowsHitTesting(false)
                }
                .frame(height: 48)
                // Zensur-Spuren
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.brand(Brand.fill)).frame(width: w, height: 8)
                    ForEach(model.redactions) { r in
                        let selected = r.id == model.selectedID
                        Capsule()
                            .fill(Color.brand(Brand.accent).opacity(selected ? 1 : 0.4))
                            .frame(width: max(6, x(r.end) - x(r.start)), height: 8)
                            .offset(x: x(r.start))
                            .onTapGesture { model.selectedID = r.id; model.seek(to: max(r.start, min(model.currentTime, r.end))) }
                            .help("Zensur — anklicken zum Auswählen")
                    }
                }
                .frame(height: 8)
            }
        }
        .frame(height: 60)
    }

    /// Abspielkopf: Tinte mit Papier-Saum, damit er auf hellen und dunklen Vorschaubildern sichtbar bleibt.
    private var playhead: some View {
        VStack(spacing: 0) {
            Circle().fill(Color.brand(Brand.ink)).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color.brand(Brand.surface), lineWidth: 1.5))
            Rectangle().fill(Color.brand(Brand.ink)).frame(width: 2, height: 41)
                .background(Rectangle().fill(Color.brand(Brand.surface)).frame(width: 4))
                .padding(.top, -1)
        }
        .frame(width: 10, height: 48, alignment: .top)
    }

    private func trimHandle(left: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.brand(Brand.ink))
            .frame(width: 12, height: 44)
            .overlay(Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.brand(Brand.surface)))
            .contentShape(Rectangle())
    }
}
