import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Schwebende Karten unten links nach jeder Aufnahme: Klick öffnet, außerdem kopieren, anpinnen,
/// herausziehen oder wegklicken.
@MainActor final class QuickAccessController {
    static let shared = QuickAccessController()

    static let cardSize = CGSize(width: 236, height: 148)
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 16
    static let headerHeight: CGFloat = 30
    /// Abstand des Panels zum Rand des sichtbaren Bildschirmbereichs.
    static let margin: CGFloat = 4

    let model = QuickAccessModel()
    private var panel: QuickAccessPanel?
    private var hosting: QuickAccessHostingView?
    private var screen: NSScreen?
    private var timers: [UUID: DispatchWorkItem] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        CaptureStore.shared.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in self?.sync(with: items) }
            .store(in: &cancellables)
        model.$hovered
            .removeDuplicates()
            .sink { [weak self] id in
                // Unter der Maus läuft kein Ausblende-Timer ab.
                guard let self else { return }
                if id == nil { self.model.cards.forEach { self.scheduleAutoClose($0.id) } }
            }
            .store(in: &cancellables)
        // Neue Anzeigedauer gilt sofort auch für Karten, die gerade stehen.
        let settings = AppSettings.shared
        settings.$quickAccessAutoHide.combineLatest(settings.$quickAccessSeconds)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.model.cards.forEach { self.scheduleAutoClose($0.id) }
            }
            .store(in: &cancellables)
        // Bildschirm abgesteckt oder umgestellt: Karten auf einen vorhandenen Bildschirm umziehen.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            onMainActor { self?.screensChanged() }
        }
    }

    /// Der Bildschirm der Karten, solange es ihn noch gibt — sonst der Hauptbildschirm.
    private var currentScreen: NSScreen {
        if let screen, let live = NSScreen.screens.first(where: { $0.displayID == screen.displayID }) { return live }
        return NSScreen.screens.first ?? NSScreen.withMouse
    }

    func screensChanged() {
        let screen = currentScreen
        self.screen = screen
        let grid = Self.grid(in: screen.visibleFrame)
        model.rows = grid.rows
        // Kleinerer Bildschirm: was nicht mehr passt, fällt weg (älteste zuerst).
        while model.cards.count > grid.rows * grid.columns {
            let old = model.cards.removeFirst()
            timers[old.id]?.cancel()
            timers[old.id] = nil
        }
        layout(animated: false)
    }

    var actions: QuickAccessActions {
        QuickAccessActions(
            copy: { [weak self] item in self?.copy(item) },
            open: { item in Self.edit(item, tool: nil) },
            pin: { item in
                Task {
                    await CaptureStore.shared.waitUntilWritten(item.id)
                    if let img = ImageIOHelper.load(item.fileURL) { PinWindowController.pin(img, scale: item.displayScale) }
                }
            },
            reveal: { item in NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) },
            copyText: { item in Self.copyText(of: item) },
            delete: { [weak self] item in
                self?.dismiss(item.id)
                CaptureStore.shared.delete(item)
            },
            close: { [weak self] item in self?.dismiss(item.id) },
            closeAll: { [weak self] in self?.dismissAll() }
        )
    }

    /// Texterkennung auf der gespeicherten (bereits zensierten) Datei — Zensiertes kann so nie mitkommen.
    static func copyText(of item: CaptureItem) {
        Telemetry.count(.copyText)
        Task {
            await CaptureStore.shared.waitUntilWritten(item.id)
            let url = item.fileURL
            let text = await Task.detached(priority: .userInitiated) { () -> String in
                guard let image = ImageIOHelper.load(url) else { return "" }
                return TextLayout.plainText(TextLayout.lines(in: image))
            }.value
            if text.isEmpty {
                HUD.show("Kein Text gefunden", symbol: "text.magnifyingglass")
            } else {
                Clipboard.copy(text: text)
                let lines = text.split(separator: "\n").count
                HUD.show("Text kopiert · \(lines) Zeile\(lines == 1 ? "" : "n")", symbol: "text.viewfinder")
            }
        }
    }

    static func edit(_ item: CaptureItem, tool: EditorTool?) {
        switch item.kind {
        case .image: EditorWindowController.show(item, tool: tool)
        case .video: VideoEditorWindowController.show(item)
        case .gif: NSWorkspace.shared.open(item.fileURL)
        }
    }

    func show(_ item: CaptureItem, on screen: NSScreen) {
        self.screen = screen
        let grid = Self.grid(in: screen.visibleFrame)
        model.rows = grid.rows
        model.cards.removeAll { $0.id == item.id }
        model.cards.append(item)
        // Erst wenn auch nebeneinander nichts mehr passt, fällt die älteste Karte weg.
        while model.cards.count > grid.rows * grid.columns {
            let old = model.cards.removeFirst()
            timers[old.id]?.cancel()
        }
        ensurePanel()
        layout(animated: true)
        panel?.orderFrontRegardless()
        scheduleAutoClose(item.id)
    }

    func dismiss(_ id: UUID) {
        timers[id]?.cancel()
        timers[id] = nil
        withAnimation(.spring(duration: 0.28)) { model.cards.removeAll { $0.id == id } }
        if model.hovered == id { model.hovered = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in self?.layout(animated: false) }
    }

    func dismissAll() {
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        model.cards.removeAll()
        model.hovered = nil
        panel?.orderOut(nil)
    }

    private func copy(_ item: CaptureItem) {
        model.flash(item.id)
        if item.kind == .image { Telemetry.count(.copyImage) }
        Task {
            await CaptureStore.shared.waitUntilWritten(item.id)
            switch item.kind {
            case .image: Clipboard.copy(imageFile: item.fileURL, item: item.id)
            case .video, .gif: Clipboard.copy(fileURL: item.fileURL)
            }
        }
    }

    private func scheduleAutoClose(_ id: UUID) {
        timers[id]?.cancel()
        let seconds = AppSettings.shared.quickAccessAutoClose
        guard seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.model.hovered == id { return }
            self.dismiss(id)
        }
        timers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func sync(with items: [CaptureItem]) {
        var changed = false
        for (i, card) in model.cards.enumerated() {
            if let fresh = items.first(where: { $0.id == card.id }) {
                if fresh != card { model.cards[i] = fresh; changed = true }
            }
        }
        let ids = Set(items.map(\.id))
        let before = model.cards.count
        model.cards.removeAll { !ids.contains($0.id) }
        if changed || before != model.cards.count { layout(animated: false) }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = QuickAccessPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.appearance = Brand.Dark.appearance
        let host = QuickAccessHostingView(rootView: QuickAccessRoot(model: model, actions: actions))
        host.model = model
        p.contentView = host
        panel = p
        hosting = host
    }

    /// Karten pro Spalte (bis zur Bildschirmhöhe) und Spalten nebeneinander (bis zur Bildschirmbreite).
    static func grid(in visibleFrame: CGRect) -> (rows: Int, columns: Int) {
        let height = visibleFrame.height - 2 * margin - headerHeight - 2 * padding + spacing
        let width = visibleFrame.width - 2 * margin - 2 * padding + spacing
        return (max(1, Int(height / (cardSize.height + spacing))), max(1, Int(width / (cardSize.width + spacing))))
    }

    static func panelSize(cards n: Int, rows: Int = .max) -> CGSize {
        guard n > 0 else { return .zero }
        let rows = max(1, rows)
        let tall = min(n, rows)
        let columns = (n - 1) / rows + 1
        let header = n > 1 ? headerHeight : 0
        return CGSize(width: CGFloat(columns) * cardSize.width + CGFloat(columns - 1) * spacing + 2 * padding,
                      height: CGFloat(tall) * cardSize.height + CGFloat(tall - 1) * spacing + header + 2 * padding)
    }

    /// Lage der Karte `index` im Panel, Ursprung unten links. Ist eine Spalte voll, stapeln sich
    /// neue Karten rechts daneben weiter; in jeder Spalte sitzt die neueste unten.
    static func cardOrigin(_ index: Int, of n: Int, rows: Int) -> CGPoint {
        let rows = max(1, rows)
        let column = index / rows
        let inColumn = min(rows, n - column * rows)
        let fromBottom = inColumn - 1 - index % rows
        return CGPoint(x: padding + CGFloat(column) * (cardSize.width + spacing),
                       y: padding + CGFloat(fromBottom) * (cardSize.height + spacing))
    }

    /// Karte unter einem Punkt im Panel (Ursprung unten links).
    static func cardIndex(at point: CGPoint, of n: Int, rows: Int) -> Int? {
        (0..<n).first { CGRect(origin: cardOrigin($0, of: n, rows: rows), size: cardSize).contains(point) }
    }

    private func layout(animated: Bool) {
        guard let panel else { return }
        let n = model.cards.count
        if n == 0 { panel.orderOut(nil); return }
        let screen = currentScreen
        let size = Self.panelSize(cards: n, rows: model.rows)
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.minX + Self.margin, y: vf.minY + Self.margin, width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

struct QuickAccessActions {
    var copy: (CaptureItem) -> Void
    var open: (CaptureItem) -> Void
    var pin: (CaptureItem) -> Void
    var reveal: (CaptureItem) -> Void
    var copyText: (CaptureItem) -> Void
    var delete: (CaptureItem) -> Void
    var close: (CaptureItem) -> Void
    var closeAll: () -> Void
}

@MainActor final class QuickAccessModel: ObservableObject {
    /// Älteste zuerst — die neueste Karte sitzt unten, am nächsten an der Ecke.
    @Published var cards: [CaptureItem] = []
    /// Karten pro Spalte, aus der Höhe des Bildschirms (`QuickAccessController.grid`).
    @Published var rows = Int.max
    @Published var hovered: UUID?
    @Published var headerHovered = false
    @Published var flashed: UUID?

    func flash(_ id: UUID) {
        flashed = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            if self?.flashed == id { self?.flashed = nil }
        }
    }
}

final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hover über eigene Tracking-Area (`.activeAlways`): Die Karten müssen auch reagieren, wenn
/// Knips nicht die aktive App ist — und das ist sie praktisch nie.
final class QuickAccessHostingView: NSHostingView<QuickAccessRoot> {
    weak var model: QuickAccessModel?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMainActor {
            model?.hovered = nil
            model?.headerHovered = false
        }
    }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: p.x, y: isFlipped ? bounds.height - p.y : p.y)
        let yFromTop = bounds.height - point.y
        onMainActor {
            guard let model else { return }
            let n = model.cards.count
            let pad = QuickAccessController.padding
            // „Alle schließen“ steht über der ersten Spalte.
            model.headerHovered = n > 1 && yFromTop < pad + QuickAccessController.headerHeight
                && point.x >= pad && point.x <= pad + QuickAccessController.cardSize.width
            model.hovered = QuickAccessController.cardIndex(at: point, of: n, rows: model.rows).map { model.cards[$0].id }
        }
    }
}

struct QuickAccessRoot: View {
    @ObservedObject var model: QuickAccessModel
    let actions: QuickAccessActions

    var body: some View {
        let n = model.cards.count
        // Von unten links aus angeordnet wie das Panel selbst: Wächst es, bleiben die Karten stehen.
        ZStack(alignment: .bottomLeading) {
            Color.clear
            ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, item in
                let origin = QuickAccessController.cardOrigin(index, of: n, rows: model.rows)
                QuickAccessCard(item: item, hovered: model.hovered == item.id, flashed: model.flashed == item.id, actions: actions)
                    .offset(x: origin.x, y: -origin.y)
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .overlay(alignment: .topLeading) {
            if n > 1 {
                HStack {
                    Spacer()
                    Button { actions.closeAll() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            Text("Alle schließen").font(Brand.font(11.5, .medium))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .foregroundStyle(Color.brand(Brand.Dark.ink))
                        .darkSurface(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(model.headerHovered || model.hovered != nil ? 1 : 0.0)
                }
                .frame(width: QuickAccessController.cardSize.width,
                       height: QuickAccessController.headerHeight - QuickAccessController.spacing)
                .padding([.top, .leading], QuickAccessController.padding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: model.cards)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: model.rows)
        .animation(.easeOut(duration: 0.12), value: model.hovered)
    }
}

/// Karte nach der Aufnahme (docs/design.md, „Karten“): Vorschau mit Radius 12 und dunklem Rand; beim Darüberfahren
/// dunkler Schleier, „Kopieren“ als Papier-Pille (primär), „Bearbeiten“/„Öffnen“ dunkel gehoben, kleine runde dunkle
/// Knöpfe in den Ecken. Lage der Knöpfe ist fest (Selbsttest `cards` klickt genau dorthin).
struct QuickAccessCard: View {
    let item: CaptureItem
    let hovered: Bool
    let flashed: Bool
    let actions: QuickAccessActions

    static let radius: CGFloat = 12
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    var body: some View {
        ZStack {
            shape.fill(Color.brand(Brand.Dark.fill))
            Thumbnail(item: item, background: .brand(Brand.Dark.fill))
                .clipShape(shape)
            if item.kind != .image && !hovered {
                MediaBadge(item: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(8)
            }
            if hovered { hoverOverlay.transition(.opacity) }
            if flashed { copiedOverlay.transition(.opacity) }
        }
        .frame(width: QuickAccessController.cardSize.width, height: QuickAccessController.cardSize.height)
        // Dunkler Rand: hält helle Screenshots auf hellem Grund zusammen; die feine helle Linie innen trägt auf dunklem.
        .overlay(shape.strokeBorder(Color.brand(Brand.Dark.fill), lineWidth: 1))
        .overlay(shape.inset(by: 1).strokeBorder(Color.brand(Brand.Dark.line), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .contentShape(shape)
        // Klick irgendwo auf die Karte öffnet sie; die Knöpfe darauf haben Vorrang.
        .onTapGesture { actions.open(item) }
        .onDrag { DragProvider.make(for: item) }
    }

    private var hoverOverlay: some View {
        ZStack {
            shape.fill(Color.brand(Brand.Dark.fill).opacity(0.58))
            VStack(spacing: 7) {
                Button { actions.copy(item) } label: {
                    Label("Kopieren", systemImage: "doc.on.doc")
                }
                .buttonStyle(DarkButtonStyle(kind: .primary, height: 30, width: 122, fontSize: 13))
                Button { actions.open(item) } label: {
                    Label(item.kind == .gif ? "Öffnen" : "Bearbeiten", systemImage: item.kind == .gif ? "arrow.up.forward.app" : "pencil")
                }
                .buttonStyle(DarkButtonStyle(kind: .raised, height: 30, width: 122, fontSize: 13))
            }
            VStack {
                HStack {
                    corner("xmark", help: "Schließen") { actions.close(item) }
                    Spacer()
                    if item.kind == .image {
                        corner("pin", help: "Anpinnen") { actions.pin(item) }
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    corner("folder", help: "Im Finder zeigen") { actions.reveal(item) }
                    if item.kind == .image {
                        corner("text.viewfinder", help: "Text kopieren (ohne zensierte Stellen)") { actions.copyText(item) }
                    }
                    Spacer()
                    corner("trash", help: "Löschen") { actions.delete(item) }
                }
            }
            .padding(7)
        }
    }

    /// Kurze grüne Bestätigung nach „Kopieren“.
    private var copiedOverlay: some View {
        ZStack {
            shape.fill(Color.brand(Brand.Dark.fill).opacity(0.62))
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold))
                Text("Kopiert").font(Brand.font(13, .semibold))
            }
            .foregroundStyle(Color.brand(Brand.Dark.success))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(Color.brand(Brand.Dark.fill)))
            .overlay(Capsule().strokeBorder(Color.brand(Brand.Dark.success).opacity(0.35)))
        }
        .allowsHitTesting(false)
    }

    private func corner(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(DarkIconButtonStyle(size: 24, symbolSize: 11))
            .help(help)
    }
}

/// Kleine dunkle Pille unten links auf Video/GIF-Vorschauen: Symbol und Dauer in Mono.
struct MediaBadge: View {
    let item: CaptureItem
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            Image(systemName: item.kind == .gif ? "photo.stack" : "play.fill")
                .font(.system(size: compact ? 6.5 : 8.5, weight: .bold))
            Text(item.kind == .gif ? "GIF" : Format.duration(item.duration ?? 0))
                .font(Brand.mono(compact ? 9 : 10.5, .medium))
        }
        .foregroundStyle(Color.brand(Brand.Dark.ink))
        .padding(.horizontal, compact ? 5 : 7)
        .frame(height: compact ? 15 : 20)
        .background(Capsule().fill(Color.brand(Brand.Dark.fill).opacity(0.88)))
        .overlay(Capsule().strokeBorder(Color.brand(Brand.Dark.line)))
        .fixedSize()
    }
}

struct Thumbnail: View {
    let item: CaptureItem
    var background = Color.brand(Brand.Dark.fill)

    var body: some View {
        if let image = ThumbnailCache.shared.image(for: item) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background)
        } else {
            Image(systemName: item.kind == .image ? "photo" : "film")
                .font(.system(size: 28))
                .foregroundStyle(Color.brand(Brand.Dark.muted))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background)
        }
    }
}

@MainActor final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: NSImage] = [:]
    /// Vorschau direkt aus dem Speicher, solange die Datei noch geschrieben wird.
    private var seeded: [String: NSImage] = [:]

    func seed(_ item: CaptureItem, image: CGImage) {
        let key = "\(item.id)-\(item.revision)"
        cache[key] = nil
        if seeded.count > 12 { seeded.removeAll() }
        seeded[key] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func image(for item: CaptureItem) -> NSImage? {
        let key = "\(item.id)-\(item.revision)"
        if let hit = cache[key] { return hit }
        if let seeded = seeded[key] { return seeded }
        let url = CaptureStore.shared.thumbnailURL(for: item)
        guard let cg = ImageIOHelper.load(url) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if cache.count > 60 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// Datei zum Herausziehen — wartet notfalls, bis sie fertig geschrieben ist.
@MainActor enum DragProvider {
    static func make(for item: CaptureItem) -> NSItemProvider {
        Telemetry.count(.dragOut)
        let url = item.fileURL
        // Fertige Datei: normaler Datei-Drag (funktioniert überall, auch im Finder).
        if !CaptureStore.shared.isWriting(item.id), let ready = NSItemProvider(contentsOf: url) { return ready }
        let type: UTType = switch item.kind {
        case .image: ImageFormat(fileExtension: url.pathExtension)?.utType ?? .png
        case .video: .mpeg4Movie
        case .gif: .gif
        }
        let provider = NSItemProvider()
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                await CaptureStore.shared.waitUntilWritten(item.id)
                completion(url, false, nil)
            }
            return nil
        }
        return provider
    }
}
