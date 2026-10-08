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
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = CanvasView.background
        window.isReleasedWhenClosed = false
        window.title = model.item.title
        window.minSize = NSSize(width: 900, height: 600)
        super.init(window: window)
        window.delegate = self
        let canvas = VideoCanvasView(model: model)
        window.contentView = NSHostingView(rootView: VideoEditorRoot(model: model, canvas: canvas, actions: VideoEditorActions(
            save: { [weak self] in self?.save(close: false) },
            done: { [weak self] in self?.save(close: true) },
            copy: { [weak self] in self?.copyFile() },
            reveal: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([self.model.item.fileURL])
            }
        )))
        let vf = NSScreen.withMouse.visibleFrame
        let scale = CGFloat(max(1, model.item.scale))
        let w = min(max(model.videoSize.width / scale + 80, 900), vf.width * 0.9)
        let h = min(max(model.videoSize.height / scale + 260, 600), vf.height * 0.9)
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
        layer?.backgroundColor = CanvasView.background.cgColor
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

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Gleicher Rand wie `videoRect`, sonst sitzen die Rahmen neben der Zensur.
        playerLayer.frame = bounds.insetBy(dx: 16, dy: 16)
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
    func drawOverlay(_ ctx: CGContext) {
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.85).cgColor)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        for r in model.redactions where r.id != model.selectedID && model.isActive(r) {
            ctx.stroke(toView(r.rect(at: model.currentTime)))
        }
        ctx.setLineDash(phase: 0, lengths: [])
        if let sel = model.selected {
            let vr = toView(sel.rect(at: model.currentTime))
            let alpha: CGFloat = model.isActive(sel) ? 1 : 0.45
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(vr)
            for c in [CGPoint(x: vr.minX, y: vr.minY), CGPoint(x: vr.maxX, y: vr.minY), CGPoint(x: vr.minX, y: vr.maxY), CGPoint(x: vr.maxX, y: vr.maxY)] {
                let h = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: h)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: h)
            }
        }
        if let draft {
            let v = toView(draft)
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.25).cgColor)
            ctx.fill(v)
            ctx.setStrokeColor(NSColor.white.cgColor)
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
            if let r = draft, r.width * factor >= 6, r.height * factor >= 6 { model.addRedaction(rect: r) }
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

struct VideoEditorRoot: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject private var settings = AppSettings.shared
    let canvas: VideoCanvasView
    let actions: VideoEditorActions

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            ZStack(alignment: .bottom) {
                VideoCanvasHost(canvas: canvas)
                if let busy = model.busy {
                    HStack(spacing: 10) {
                        ProgressView(value: model.progress ?? 0).frame(width: 120)
                        Text(busy).font(.system(size: 12.5, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .foregroundStyle(.white)
                    .padding(.bottom, 16)
                } else if let toast = model.toast {
                    Pill(text: toast, symbol: "checkmark.circle.fill", spinning: false).padding(.bottom, 16)
                }
            }
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    Text("\(Format.preciseDuration(model.currentTime)) / \(Format.preciseDuration(model.duration))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 128, alignment: .leading)
                    TimelineBar(model: model)
                }
                selectionBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(white: 0.13))
        }
        .background(Color(nsColor: CanvasView.background))
        .ignoresSafeArea()
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64)
            Image(systemName: "eye.slash").foregroundStyle(.white.opacity(0.8))
            Text("Rechteck ziehen = zensieren")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .layoutPriority(-1)
            HStack(spacing: 2) {
                ForEach(RedactStyle.allCases) { s in
                    let on = (model.selected?.style ?? model.style) == s
                    Button { model.setStyle(s) } label: {
                        Label(s.title, systemImage: s.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .fixedSize()
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white.opacity(0.18) : .clear))
                            .foregroundStyle(.white.opacity(on ? 1 : 0.75))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
            Spacer(minLength: 8)
            if settings.showAutoRedact {
                Button { model.autoRedact() } label: { Label("Auto-Zensur", systemImage: "wand.and.stars") }
                    .buttonStyle(ToolbarButtonStyle(prominent: false))
                    .disabled(model.busy != nil)
                    .help("Erkennt E-Mails, IBANs, Telefonnummern, Schlüssel usw. in Einzelbildern (alle 0,5 s) und legt Zensurfelder an.")
            }
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(ToolbarButtonStyle(prominent: false))
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button { model.exportGIF() } label: { Label("GIF", systemImage: "photo.stack") }
                .buttonStyle(ToolbarButtonStyle(prominent: false))
                .disabled(model.busy != nil)
                .help("Als GIF exportieren (\(AppSettings.shared.gifFPS) fps, max. \(AppSettings.shared.gifWidth) px breit)")
            Button { actions.reveal() } label: { Image(systemName: "folder") }
                .buttonStyle(ToolbarButtonStyle(prominent: false))
            Button { actions.copy() } label: { Label("Kopieren", systemImage: "doc.on.doc") }
                .buttonStyle(ToolbarButtonStyle(prominent: false))
                .disabled(model.busy != nil)
            Button("Fertig") { actions.done() }
                .buttonStyle(ToolbarButtonStyle(prominent: true))
                .disabled(model.busy != nil)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .frame(height: EditorToolbar.height)
        .background(Color(white: 0.13))
    }

    @ViewBuilder private var selectionBar: some View {
        HStack(spacing: 8) {
            if let sel = model.selected, let index = model.redactions.firstIndex(where: { $0.id == sel.id }) {
                Text("Zensur \(index + 1)\(sel.auto ? " (auto)" : "")\(sel.track != nil ? " · folgt" : "")")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text("\(Format.preciseDuration(sel.start)) – \(Format.preciseDuration(sel.end))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                Button("Ab hier") { model.selectedStartHere() }.buttonStyle(ToolbarButtonStyle(prominent: false))
                    .help("Zensur beginnt an der aktuellen Abspielposition")
                Button("Bis hier") { model.selectedEndHere() }.buttonStyle(ToolbarButtonStyle(prominent: false))
                    .help("Zensur endet an der aktuellen Abspielposition")
                Button("Ganze Länge") { model.selectedWholeClip() }.buttonStyle(ToolbarButtonStyle(prominent: false))
                if sel.track == nil {
                    Button { model.followSelected() } label: { Label("Folgen", systemImage: "scope") }
                        .buttonStyle(ToolbarButtonStyle(prominent: false))
                        .disabled(model.busy != nil)
                        .help("Balken folgt dem Inhalt darunter, z. B. beim Scrollen — ab der aktuellen Position vor und zurück.")
                } else {
                    Button { model.unfollowSelected() } label: { Label("Fest", systemImage: "pin") }
                        .buttonStyle(ToolbarButtonStyle(prominent: false))
                        .help("Balken bleibt an der aktuellen Stelle stehen")
                }
                Button { model.deleteSelected() } label: { Label("Löschen", systemImage: "trash") }
                    .buttonStyle(ToolbarButtonStyle(prominent: false))
            } else {
                Text(model.redactions.isEmpty
                     ? "Gelbe Griffe kürzen das Video. Leertaste spielt ab, ← → springen einzelne Bilder."
                     : "\(model.redactions.count) Zensurfeld\(model.redactions.count == 1 ? "" : "er") — anklicken, um Zeitraum oder Stil zu ändern.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if model.trimStart > 0.001 || model.trimEnd < model.duration - 0.001 {
                Text("Gekürzt auf \(Format.preciseDuration(model.trimEnd - model.trimStart))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.yellow.opacity(0.85))
            }
        }
        .frame(height: 28)
    }
}

/// Zeitleiste mit Vorschaubildern, gelben Kürzungs-Griffen, Abspielkopf und Zensur-Spuren.
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
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        model.seek(to: Double(max(0, min(v.location.x, w)) / w) * d)
                    })
                    // Außerhalb der Kürzung abdunkeln
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: max(0, x(model.trimStart)), height: 40).allowsHitTesting(false)
                    Rectangle().fill(Color.black.opacity(0.6)).frame(width: max(0, w - x(model.trimEnd)), height: 40)
                        .offset(x: x(model.trimEnd)).allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.yellow, lineWidth: 2)
                        .frame(width: max(4, x(model.trimEnd) - x(model.trimStart)), height: 40)
                        .offset(x: x(model.trimStart))
                        .allowsHitTesting(false)
                    trimHandle(left: true).offset(x: x(model.trimStart) - 6)
                        .gesture(DragGesture().onChanged { v in
                            if trimDragStart == nil { trimDragStart = (model.trimStart, model.trimEnd); model.checkpoint() }
                            model.setTrim(start: (trimDragStart?.0 ?? 0) + Double(v.translation.width / w) * d)
                            model.seek(to: model.trimStart)
                        }.onEnded { _ in trimDragStart = nil })
                    trimHandle(left: false).offset(x: x(model.trimEnd) - 6)
                        .gesture(DragGesture().onChanged { v in
                            if trimDragStart == nil { trimDragStart = (model.trimStart, model.trimEnd); model.checkpoint() }
                            model.setTrim(end: (trimDragStart?.1 ?? d) + Double(v.translation.width / w) * d)
                            model.seek(to: model.trimEnd)
                        }.onEnded { _ in trimDragStart = nil })
                    Rectangle().fill(Color.white).frame(width: 2, height: 48)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .offset(x: x(model.currentTime) - 1)
                        .allowsHitTesting(false)
                }
                .frame(height: 48)
                // Zensur-Spuren
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.05)).frame(width: w, height: 8)
                    ForEach(model.redactions) { r in
                        let selected = r.id == model.selectedID
                        RoundedRectangle(cornerRadius: 3)
                            .fill(selected ? Color.accentColor : Color.red.opacity(0.75))
                            .frame(width: max(4, x(r.end) - x(r.start)), height: 8)
                            .offset(x: x(r.start))
                            .onTapGesture { model.selectedID = r.id; model.seek(to: max(r.start, min(model.currentTime, r.end))) }
                    }
                }
                .frame(height: 8)
            }
        }
        .frame(height: 60)
    }

    private func trimHandle(left: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: 12, height: 44)
            .overlay(Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 10, weight: .heavy)).foregroundStyle(.black.opacity(0.7)))
            .contentShape(Rectangle())
    }
}
