import AppKit
import SwiftUI

@MainActor final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [UUID: EditorWindowController] = [:]

    let model: EditorModel
    private(set) var canvas: CanvasView!
    private var item: CaptureItem

    static func show(_ item: CaptureItem, tool: EditorTool? = nil) {
        if let existing = open[item.id] {
            if let tool { existing.model.tool = tool }
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let store = CaptureStore.shared
        // Frisch aufgenommen: Original liegt noch im Speicher, kein Warten auf die Platte.
        if let base = store.memoryImage(for: item.id) {
            present(item, base: base, tool: tool)
            return
        }
        Task {
            await store.waitUntilWritten(item.id)
            guard let base = ImageIOHelper.load(store.originalURL(for: item)) ?? ImageIOHelper.load(item.fileURL) else {
                Alerts.error("Bild nicht gefunden", info: "Das Original zu „\(item.title)“ ist nicht mehr vorhanden.")
                return
            }
            present(item, base: base, tool: tool)
        }
    }

    private static func present(_ item: CaptureItem, base: CGImage, tool: EditorTool?) {
        guard open[item.id] == nil else { return }
        let controller = EditorWindowController(item: item, base: base, document: CaptureStore.shared.loadImageDocument(for: item), tool: tool)
        open[item.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.canvas)
        DockPresence.windowOpened()
    }

    init(item: CaptureItem, base: CGImage, document: ImageDocument, tool: EditorTool?) {
        self.item = item
        self.model = EditorModel(item: item, base: base, document: document, initialTool: tool)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = CanvasView.background
        window.isReleasedWhenClosed = false
        window.title = item.title
        window.minSize = NSSize(width: 1140, height: 520)
        super.init(window: window)
        window.delegate = self

        canvas = CanvasView(model: model)
        let actions = EditorActions(
            save: { [weak self] in self?.save(close: false) },
            done: { [weak self] in self?.save(close: true) },
            copy: { [weak self] in self?.copyImage() },
            pin: { [weak self] in self?.pin() },
            reveal: { [weak self] in self?.reveal() }
        )
        let root = EditorRootView(model: model, canvas: canvas, actions: actions)
        window.contentView = NSHostingView(rootView: root)
        window.setContentSize(Self.initialSize(for: item, base: base))
        window.center()
        window.setFrameAutosaveName("")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func initialSize(for item: CaptureItem, base: CGImage) -> NSSize {
        let scale = CGFloat(max(1, item.scale))
        let vf = (NSScreen.withMouse).visibleFrame
        let w = CGFloat(base.width) / scale + 64, h = CGFloat(base.height) / scale + 64 + EditorToolbar.height
        return NSSize(width: min(max(w, 1140), vf.width * 0.9), height: min(max(h, 560), vf.height * 0.9))
    }

    // MARK: Aktionen

    /// Speichert im Hintergrund — das Fenster reagiert (und schließt) sofort.
    @discardableResult
    private func persist(_ output: ImagePromise? = nil) -> ImagePromise {
        let promise = output ?? model.renderPromise()
        if model.dirty {
            item = CaptureStore.shared.saveImage(output: promise, document: model.document, for: item,
                                                 size: model.outputSize, outputScale: Double(model.scale * model.outputFactor))
            model.dirty = false
        }
        return promise
    }

    func save(close: Bool) {
        canvas.commitPendingEdits()
        let wasDirty = model.dirty
        if wasDirty { persist() }
        if close {
            window?.close()
        } else if wasDirty {
            model.showToast("Gespeichert")
        }
    }

    func copyImage() {
        canvas.commitPendingEdits()
        let output = persist()
        Clipboard.copy(output, fileURL: item.fileURL)
        model.showToast("In die Zwischenablage kopiert")
    }

    func pin() {
        canvas.commitPendingEdits()
        let full = model.fullResolutionPromise()
        let scale = model.scale
        Task {
            if let image = await full.imageValue() { PinWindowController.pin(image, scale: scale) }
        }
    }

    func reveal() {
        save(close: false)
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }

    @objc func copy(_ sender: Any?) { copyImage() }
    @objc func saveDocument(_ sender: Any?) { save(close: false) }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitPendingEdits()
        if model.dirty { persist() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[item.id] = nil
        DockPresence.windowClosed()
    }
}

struct EditorActions {
    var save: () -> Void
    var done: () -> Void
    var copy: () -> Void
    var pin: () -> Void
    var reveal: () -> Void
}

private struct CanvasHost: NSViewRepresentable {
    let canvas: CanvasView
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

struct EditorRootView: View {
    @ObservedObject var model: EditorModel
    let canvas: CanvasView
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model, actions: actions)
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            ZStack(alignment: .bottom) {
                CanvasHost(canvas: canvas)
                if let busy = model.busy {
                    Pill(text: busy, symbol: nil, spinning: true).padding(.bottom, 20)
                } else if let toast = model.toast {
                    Pill(text: toast, symbol: "checkmark.circle.fill", spinning: false)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: model.toast)
            .overlay(alignment: .bottomTrailing) { ZoomControl(model: model, canvas: canvas).padding(14) }
        }
        .background(Color(nsColor: CanvasView.background))
        .ignoresSafeArea()
    }
}

struct Pill: View {
    let text: String
    let symbol: String?
    let spinning: Bool

    var body: some View {
        HStack(spacing: 8) {
            if spinning { ProgressView().controlSize(.small) }
            if let symbol { Image(systemName: symbol).foregroundStyle(.green) }
            Text(text).font(.system(size: 12.5, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .foregroundStyle(.white)
    }
}

struct EditorToolbar: View {
    static let height: CGFloat = 52
    @ObservedObject var model: EditorModel
    @ObservedObject private var settings = AppSettings.shared
    let actions: EditorActions

    private var activeKind: AnnotationKind? { model.selected?.kind ?? model.tool.annotationKind }

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64) // Ampel-Knöpfe
            if model.tool == .crop {
                cropControls
            } else {
                tools
                divider
                styleControls
            }
            Spacer(minLength: 8)
            if model.tool != .crop { rightActions }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(Color(white: 0.13))
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 22)
    }

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    if tool == .crop { model.startCrop() } else { model.tool = tool }
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 13.5, weight: .medium))
                        .frame(width: 30, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(model.tool == tool ? Color.accentColor : .clear))
                        .foregroundStyle(model.tool == tool ? .white : Color.white.opacity(0.82))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(String(tool.key).uppercased()))")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder private var styleControls: some View {
        if activeKind == .redact {
            Text("Klick auf Text = Zeile · ⌥ = Wort")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize()
                .help("Klick auf eine Textzeile legt einen Balken darüber, ⌥-Klick nur über ein Wort. Beim Ziehen wird der Balken bis zum Wortende erweitert — ⌥ beim Ziehen schaltet das ab.")
            HStack(spacing: 2) {
                ForEach(RedactStyle.allCases) { style in
                    let on = (model.selected?.kind == .redact ? model.selected?.redactStyle : model.redactStyle) == style
                    Button { model.setRedactStyle(style) } label: {
                        Label(style.title, systemImage: style.symbol)
                            .font(.system(size: 11.5, weight: .medium))
                            .fixedSize()
                            .padding(.horizontal, 7)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white.opacity(0.18) : .clear))
                            .foregroundStyle(.white.opacity(on ? 1 : 0.75))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
        } else {
            HStack(spacing: 5) {
                ForEach(RGBA.palette, id: \.self) { c in
                    let on = (model.selected?.color ?? model.color) == c
                    Button { model.setColor(c) } label: {
                        Circle()
                            .fill(Color(nsColor: c.nsColor))
                            .frame(width: 17, height: 17)
                            .overlay(Circle().strokeBorder(Color.white.opacity(c == .black ? 0.35 : 0.15), lineWidth: 1))
                            .padding(3)
                            .overlay(Circle().strokeBorder(Color.white.opacity(on ? 0.95 : 0), lineWidth: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if activeKind != .highlight {
                divider
                HStack(spacing: 2) {
                    ForEach(StrokeSize.allCases) { s in
                        let on = (model.selected?.size ?? model.size) == s
                        Button { model.setSize(s) } label: {
                            Text(s.title)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .frame(width: 26, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.white.opacity(0.18) : .clear))
                                .foregroundStyle(.white.opacity(on ? 1 : 0.7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            }
            if activeKind == .rectangle || activeKind == .ellipse {
                let on = model.selected?.filled ?? model.filled
                Button { model.setFilled(!on) } label: {
                    Image(systemName: on ? "square.fill" : "square")
                        .frame(width: 28, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white.opacity(0.18) : .clear))
                        .foregroundStyle(.white.opacity(0.85))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Gefüllt")
            }
        }
    }

    private var cropControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "crop").foregroundStyle(.white.opacity(0.8))
            Text("Zuschneiden — Rahmen ziehen, ⏎ übernimmt, Esc bricht ab")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Button("Zurücksetzen") { model.resetCrop() }.buttonStyle(ToolbarButtonStyle(prominent: false))
            Button("Abbrechen") { model.cancelCrop() }.buttonStyle(ToolbarButtonStyle(prominent: false))
            Button("Übernehmen") { model.applyCrop() }.buttonStyle(ToolbarButtonStyle(prominent: true))
        }
    }

    private var rightActions: some View {
        HStack(spacing: 6) {
            if settings.showAutoRedact {
                Button { model.autoRedact() } label: {
                    Label("Auto-Zensur", systemImage: "wand.and.stars")
                }
                .buttonStyle(ToolbarButtonStyle(prominent: false))
                .help("Findet E-Mails, IBANs, Telefonnummern, Kartennummern und API-Schlüssel und zensiert sie — lokal, ohne Cloud.")
                .disabled(model.busy != nil)
            }

            HStack(spacing: 0) {
                iconButton("arrow.uturn.backward", help: "Widerrufen (⌘Z)", enabled: model.canUndo) { model.undo() }
                iconButton("arrow.uturn.forward", help: "Wiederholen (⇧⌘Z)", enabled: model.canRedo) { model.redo() }
            }
            iconButton("pin", help: "Anpinnen (schwebt über allen Fenstern)", enabled: true, action: actions.pin)
            Button { actions.copy() } label: { Label("Kopieren", systemImage: "doc.on.doc") }
                .buttonStyle(ToolbarButtonStyle(prominent: false))
                .help("Kopieren (⌘C)")
            Button("Fertig") { actions.done() }
                .buttonStyle(ToolbarButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

struct ToolbarButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? Color.accentColor : Color.white.opacity(configuration.isPressed ? 0.2 : 0.1))
            )
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.4))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Zoom unten rechts: −, Prozent (Klick: Einpassen ↔ 100 %), +.
private struct ZoomControl: View {
    @ObservedObject var model: EditorModel
    let canvas: CanvasView

    var body: some View {
        HStack(spacing: 0) {
            button("minus", help: "Verkleinern (⌘−)") { canvas.zoomOut() }
            Button {
                if model.zoom == nil { canvas.zoomActualSize() } else { canvas.zoomToFit() }
            } label: {
                Text(model.zoom == nil ? "Einpassen · \(model.zoomPercent) %" : "\(model.zoomPercent) %")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 52)
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.zoom == nil ? "Originalgröße (⌘1)" : "Einpassen (⌘0) · Leertaste + Ziehen verschiebt")
            button("plus", help: "Vergrößern (⌘+) · auch Trackpad-Zoom oder ⌘ + Scrollen") { canvas.zoomIn() }
        }
        .foregroundStyle(.white.opacity(0.9))
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
