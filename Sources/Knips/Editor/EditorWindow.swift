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
        Telemetry.count(.editorOpen)
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
        window.applyEditorChrome()
        window.isReleasedWhenClosed = false
        window.title = item.title
        window.minSize = NSSize(width: EditorChrome.minWidth, height: 520)
        super.init(window: window)
        window.delegate = self

        canvas = CanvasView(model: model)
        let actions = EditorActions(
            save: { [weak self] in self?.save(close: false) },
            done: { [weak self] in self?.save(close: true) },
            copy: { [weak self] in self?.copyImage() },
            copyText: { [weak self] in self?.copyText() },
            pin: { [weak self] in self?.pin() },
            reveal: { [weak self] in self?.reveal() }
        )
        let root = EditorRootView(model: model, canvas: canvas, actions: actions)
        let host = NSHostingView(rootView: root)
        // Nur die Mindestgröße kommt aus SwiftUI; die Werkzeugleiste passt sich der Breite an (ViewThatFits).
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.setContentSize(Self.initialSize(for: item, base: base))
        window.center()
        window.setFrameAutosaveName("")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    private static func initialSize(for item: CaptureItem, base: CGImage) -> NSSize {
        let scale = CGFloat(max(1, item.scale))
        let vf = (NSScreen.withMouse).visibleFrame
        let chrome = EditorChrome.topBarHeight + EditorChrome.propertiesHeight + EditorChrome.statusHeight
        let w = CGFloat(base.width) / scale + 64 + 2 * EditorChrome.margin, h = CGFloat(base.height) / scale + 64 + chrome
        return NSSize(width: min(max(w, 1100), vf.width * 0.9), height: min(max(h, 560), vf.height * 0.9))
    }

    // MARK: Aktionen

    /// Speichert im Hintergrund — das Fenster reagiert (und schließt) sofort. Liegt die Aufnahme noch in der
    /// Zwischenablage, kommt dort die neue (zensierte) Fassung hinein.
    @discardableResult
    private func persist(_ output: ImagePromise? = nil) -> ImagePromise {
        let promise = output ?? model.renderPromise()
        if model.dirty {
            item = CaptureStore.shared.saveImage(output: promise, document: model.document, for: item,
                                                 size: model.outputSize, outputScale: Double(model.scale * model.outputFactor))
            model.dirty = false
            Clipboard.replace(item: item.id, with: promise, fileURL: item.fileURL)
            Telemetry.count(promise.format == .png ? .exportPNG : .exportJPEG)
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
        Clipboard.copy(output, fileURL: item.fileURL, item: item.id)
        Telemetry.count(.copyImage)
        model.showToast("In die Zwischenablage kopiert")
    }

    func copyText() {
        canvas.commitPendingEdits()
        Telemetry.count(.copyText)
        Task {
            let text = await model.renderedText()
            if text.isEmpty {
                model.showToast("Kein Text gefunden")
            } else {
                Clipboard.copy(text: text)
                let lines = text.split(separator: "\n").count
                model.showToast("Text kopiert · \(lines) Zeile\(lines == 1 ? "" : "n")")
            }
        }
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

    // Im Vollbild läge die leere Werkzeugleiste als eigenes Fenster über der oberen Leiste — dort ausblenden.
    func windowWillEnterFullScreen(_ notification: Notification) { window?.toolbar?.isVisible = false }
    func windowDidExitFullScreen(_ notification: Notification) { window?.toolbar?.isVisible = true }

    func windowWillClose(_ notification: Notification) {
        Self.open[item.id] = nil
        DockPresence.windowClosed()
    }
}

struct EditorActions {
    var save: () -> Void
    var done: () -> Void
    var copy: () -> Void
    var copyText: () -> Void
    var pin: () -> Void
    var reveal: () -> Void
}

private struct CanvasHost: NSViewRepresentable {
    let canvas: CanvasView
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

/// Bild-Editor (docs/design.md, „Editor (Bild)“): oben Werkzeuge und Aktionen, darunter die Eigenschaften des
/// Werkzeugs, in der Mitte die Bühne (`fill`) mit dem Bild, unten Zoom und Maße in Mono.
struct EditorRootView: View {
    @ObservedObject var model: EditorModel
    let canvas: CanvasView
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model, actions: actions)
            EditorPropertiesBar(model: model, actions: actions)
            ZStack(alignment: .bottom) {
                CanvasHost(canvas: canvas)
                if let busy = model.busy {
                    EditorHUD(text: busy, spinning: true).padding(.bottom, 18)
                } else if let toast = model.toast {
                    EditorHUD(text: toast, symbol: "checkmark.circle.fill")
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: model.toast)
            .padding(.horizontal, EditorChrome.margin)
            EditorStatusBar(model: model, canvas: canvas)
        }
        .background(Color.brand(Brand.canvas))
        .ignoresSafeArea()
    }
}

/// Obere Leiste: Werkzeuge als eine Gruppe, rechts Widerrufen, „Text kopieren“, „Kopieren“, „Fertig“.
/// Wird das Fenster schmal, fallen erst die Beschriftungen der Aktionen, dann die der Werkzeuge weg.
struct EditorToolbar: View {
    static let height = EditorChrome.topBarHeight
    @ObservedObject var model: EditorModel
    @ObservedObject private var settings = AppSettings.shared
    let actions: EditorActions

    /// Zeichenwerkzeuge zwischen Zensur (vorne, beschriftet) und Zuschneiden (hinten).
    private static let drawingTools = EditorTool.allCases.filter { $0 != .redact && $0 != .crop }

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: EditorChrome.trafficLights)
            if model.tool == .crop {
                cropBar
            } else {
                ViewThatFits(in: .horizontal) {
                    row(toolLabels: true, actionLabels: true)
                    row(toolLabels: true, actionLabels: false)
                    row(toolLabels: false, actionLabels: false)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background { shortcuts }
    }

    /// ⌘⏎ außerhalb von ViewThatFits, damit das Kürzel genau einmal gilt (nicht je Fassung der Leiste).
    /// Beim Zuschneiden gibt es „Fertig“ nicht — wie bisher.
    @ViewBuilder private var shortcuts: some View {
        if model.tool != .crop {
            Button("Fertig") { actions.done() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func row(toolLabels: Bool, actionLabels: Bool) -> some View {
        HStack(spacing: 10) {
            tools(labels: toolLabels)
            Spacer(minLength: 12)
            rightActions(labels: actionLabels)
        }
    }

    private func tools(labels: Bool) -> some View {
        HStack(spacing: 2) {
            toolButton(.redact, title: labels ? EditorTool.redact.title : nil)
            if settings.showAutoRedact {
                ChromeToolButton(symbol: "wand.and.stars", title: labels ? "Auto-Zensur" : nil, enabled: model.busy == nil,
                                 help: "Auto-Zensur: findet E-Mails, IBANs, Telefonnummern, Kartennummern und API-Schlüssel und zensiert sie — lokal, ohne Cloud.") {
                    model.autoRedact()
                }
            }
            ChromeDivider()
            ForEach(Self.drawingTools) { toolButton($0) }
            ChromeDivider()
            toolButton(.crop)
        }
        .chromeGroup()
    }

    private func toolButton(_ tool: EditorTool, title: String? = nil) -> some View {
        ChromeToolButton(symbol: tool.symbol, title: title, active: model.tool == tool,
                         help: "\(tool.title) (\(String(tool.key).uppercased()))") {
            if tool == .crop { model.startCrop() } else { model.tool = tool }
        }
    }

    private func rightActions(labels: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ChromeToolButton(symbol: "arrow.uturn.backward", enabled: model.canUndo, help: "Widerrufen (⌘Z)") { model.undo() }
                ChromeToolButton(symbol: "arrow.uturn.forward", enabled: model.canRedo, help: "Wiederholen (⇧⌘Z)") { model.redo() }
            }
            Button(action: actions.copyText) {
                if labels {
                    Label("Text kopieren", systemImage: "text.viewfinder")
                } else {
                    Image(systemName: "text.viewfinder").font(.system(size: 13.5, weight: .medium))
                }
            }
            .buttonStyle(BrandButtonStyle(kind: .secondary))
            .help("Text kopieren — ohne Zensiertes und Weggeschnittenes")
            .accessibilityLabel("Text kopieren")
            Button { actions.copy() } label: { Label("Kopieren", systemImage: "doc.on.doc") }
                .buttonStyle(BrandButtonStyle(kind: .secondary))
                .help("Kopieren (⌘C)")
            Button("Fertig") { actions.done() }
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .help("Speichern und schließen (⌘⏎)")
        }
    }

    private var cropBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "crop").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.brand(Brand.accent))
                Text("Zuschneiden").font(Brand.font(13, .semibold)).foregroundStyle(Color.brand(Brand.ink))
            }
            .padding(.horizontal, 10)
            .frame(height: EditorChrome.toolSize)
            .chromeGroup()
            Spacer(minLength: 12)
            Button("Zurücksetzen") { model.resetCrop() }.buttonStyle(BrandButtonStyle(kind: .quiet))
            Button("Abbrechen") { model.cancelCrop() }.buttonStyle(BrandButtonStyle(kind: .secondary))
            Button("Übernehmen") { model.applyCrop() }.buttonStyle(BrandButtonStyle(kind: .primary))
        }
    }
}

/// Zweite Leiste: Eigenschaften des Werkzeugs bzw. der Auswahl (Zensur-Stil oder Farbe, Stärke, Füllung),
/// rechts Rahmen und Anpinnen. Beim Zuschneiden steht hier, wie es geht.
struct EditorPropertiesBar: View {
    @ObservedObject var model: EditorModel
    let actions: EditorActions

    private var activeKind: AnnotationKind? { model.selected?.kind ?? model.tool.annotationKind }

    var body: some View {
        HStack(spacing: 10) {
            if model.tool == .crop {
                HStack(spacing: 6) {
                    Text("Rahmen ziehen ·")
                    KeyCap(symbol: "return")
                    Text("übernimmt ·")
                    KeyCap(key: "Esc")
                    Text("bricht ab")
                }
                .font(Brand.font(12.5))
                .foregroundStyle(Color.brand(Brand.inkSoft))
                .fixedSize()
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 8) { properties }
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .chromeGroup()
                Spacer(minLength: 10)
                HStack(spacing: 2) {
                    FrameButton(model: model)
                    ChromeToolButton(symbol: "pin", size: 28, help: "Anpinnen (schwebt über allen Fenstern)", action: actions.pin)
                }
                .chromeGroup()
            }
        }
        .frame(height: 36)
        .padding(.horizontal, EditorChrome.margin)
        .padding(.bottom, EditorChrome.propertiesHeight - 36)
    }

    @ViewBuilder private var properties: some View {
        if activeKind == .redact {
            ChromeOverline(text: "Zensur")
            BrandSegment(items: RedactStyle.allCases.map { .init(value: $0, title: $0.title, symbol: $0.symbol) },
                         selection: model.selected?.kind == .redact ? model.selected?.redactStyle : model.redactStyle,
                         height: 24) { model.setRedactStyle($0) }
        } else {
            ChromeOverline(text: "Farbe")
            HStack(spacing: 0) {
                ForEach(RGBA.palette, id: \.self) { swatch($0) }
            }
            if activeKind != .highlight {
                ChromeDivider()
                ChromeOverline(text: "Stärke")
                BrandSegment(items: StrokeSize.allCases.map { .init(value: $0, title: $0.title, mono: true) },
                             selection: model.selected?.size ?? model.size, height: 24) { model.setSize($0) }
            }
            if activeKind == .rectangle || activeKind == .ellipse {
                ChromeDivider()
                let on = model.selected?.filled ?? model.filled
                ChromeToolButton(symbol: on ? "square.fill" : "square", title: "Gefüllt", active: on, size: 28, help: "Gefüllt") {
                    model.setFilled(!on)
                }
            }
        }
    }

    /// Farbe für Anmerkungen — bleibt bunt (Inhalt, nicht Oberfläche).
    private func swatch(_ c: RGBA) -> some View {
        let on = (model.selected?.color ?? model.color) == c
        return Button { model.setColor(c) } label: {
            Circle()
                .fill(Color(nsColor: c.nsColor))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.brand(Brand.inkSoft).opacity(0.5), lineWidth: c == .white || c == .black ? 1 : 0))
                .padding(3)
                .overlay(Circle().strokeBorder(Color.brand(Brand.ink), lineWidth: on ? 2 : 0))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Untere Leiste: Zoom und Maße der gespeicherten Datei in Mono, rechts ein Hinweis zum Werkzeug.
struct EditorStatusBar: View {
    @ObservedObject var model: EditorModel
    let canvas: CanvasView

    var body: some View {
        HStack(spacing: 12) {
            ZoomControl(model: model, canvas: canvas)
            let size = model.outputSize
            Text("\(Int(size.width)) × \(Int(size.height)) px")
                .font(Brand.mono(11.5))
                .foregroundStyle(Color.brand(Brand.inkSoft))
                .fixedSize()
                .help("Größe der gespeicherten Datei in Pixeln")
            Spacer(minLength: 12)
            if model.tool != .crop, (model.selected?.kind ?? model.tool.annotationKind) == .redact {
                Text("Klick auf Text = Zeile · ⌥ = Wort")
                    .font(Brand.font(12.5))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
                    .fixedSize()
                    .help("Klick auf eine Textzeile legt einen Balken darüber, ⌥-Klick nur über ein Wort. Beim Ziehen wird der Balken bis zum Wortende erweitert — ⌥ beim Ziehen schaltet das ab.")
            }
        }
        .padding(.horizontal, EditorChrome.margin)
        .frame(height: EditorChrome.statusHeight)
    }
}

/// Zoom: −, Prozent in Mono (Klick: Einpassen ↔ 100 %), +.
private struct ZoomControl: View {
    @ObservedObject var model: EditorModel
    let canvas: CanvasView

    var body: some View {
        HStack(spacing: 0) {
            ChromeToolButton(symbol: "minus", size: 24, help: "Verkleinern (⌘−)") { canvas.zoomOut() }
            Button {
                if model.zoom == nil { canvas.zoomActualSize() } else { canvas.zoomToFit() }
            } label: {
                HStack(spacing: 5) {
                    if model.zoom == nil {
                        Text("Einpassen").font(Brand.font(12, .medium)).foregroundStyle(Color.brand(Brand.inkSoft))
                    }
                    Text("\(model.zoomPercent) %").font(Brand.mono(11.5, .medium)).foregroundStyle(Color.brand(Brand.ink))
                }
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(minWidth: 56, minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.zoom == nil ? "Originalgröße (⌘1)" : "Einpassen (⌘0) · Leertaste + Ziehen verschiebt")
            ChromeToolButton(symbol: "plus", size: 24, help: "Vergrößern (⌘+) · auch Trackpad-Zoom oder ⌘ + Scrollen") { canvas.zoomIn() }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.brand(Brand.surface)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.brand(Brand.line)))
    }
}

/// Hintergrund und Rahmen: Farbverlauf, Abstand, Ecken, Schatten.
private struct FrameButton: View {
    @ObservedObject var model: EditorModel
    @State private var open = false

    var body: some View {
        ChromeToolButton(symbol: model.frame == nil ? "square.on.square.dashed" : "square.on.square.fill", title: "Rahmen",
                         active: model.frame != nil, size: 28, help: "Hintergrund und Rahmen") { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) { FramePanel(model: model) }
    }
}

/// Inhalt des Rahmen-Popovers (auch im Selbsttest `live` fotografiert).
struct FramePanel: View {
    @ObservedObject var model: EditorModel

    private var style: FrameStyle { model.frame ?? EditorModel.lastFrameStyle }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    ChromeOverline(text: "Rahmen")
                    Text("Hintergrund und Rahmen").font(Brand.font(15, .semibold)).foregroundStyle(Color.brand(Brand.ink))
                }
                Spacer(minLength: 0)
                Toggle("Hintergrund und Rahmen", isOn: Binding(get: { model.frame != nil }, set: { model.setFrame($0 ? style : nil) }))
                    .toggleStyle(BrandSwitchStyle())
                    .labelsHidden()
            }
            HStack(spacing: 6) {
                ForEach(FrameStyle.gradients.indices, id: \.self) { i in
                    let colors = FrameStyle.gradients[i].colors.map { Color(nsColor: $0.nsColor) }
                    let on = model.frame?.gradient == i
                    Button { update { $0.gradient = i } } label: {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.brand(Brand.line)))
                            .frame(width: 28, height: 28)
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.brand(Brand.ink), lineWidth: on ? 2 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(FrameStyle.gradients[i].name)
                    .accessibilityLabel(FrameStyle.gradients[i].name)
                }
            }
            row("Abstand") {
                BrandSegment(items: [.init(value: 24.0, title: "Klein"), .init(value: 48.0, title: "Mittel"), .init(value: 80.0, title: "Groß")],
                             selection: style.padding) { v in update { $0.padding = v } }
            }
            row("Ecken") {
                BrandSegment(items: [.init(value: 0.0, title: "Eckig"), .init(value: 12.0, title: "Rund"), .init(value: 24.0, title: "Sehr rund")],
                             selection: style.cornerRadius) { v in update { $0.cornerRadius = v } }
            }
            row("Schatten") {
                Toggle("Schatten", isOn: Binding(get: { style.shadow }, set: { v in update { $0.shadow = v } }))
                    .toggleStyle(BrandSwitchStyle())
                    .labelsHidden()
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(title).font(Brand.font(13, .medium)).foregroundStyle(Color.brand(Brand.ink)).fixedSize()
            Spacer(minLength: 0)
            control()
        }
    }

    /// Jede Änderung schaltet den Rahmen ein.
    private func update(_ change: (inout FrameStyle) -> Void) {
        var s = style
        change(&s)
        model.setFrame(s)
    }
}
