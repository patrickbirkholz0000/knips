import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Schwebende Karten unten links nach jeder Aufnahme: kopieren, bearbeiten, anpinnen,
/// herausziehen oder wegklicken.
@MainActor final class QuickAccessController {
    static let shared = QuickAccessController()

    static let cardSize = CGSize(width: 236, height: 148)
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 16
    static let headerHeight: CGFloat = 30
    static let maxCards = 5

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
    }

    var actions: QuickAccessActions {
        QuickAccessActions(
            copy: { [weak self] item in self?.copy(item) },
            edit: { item in Self.edit(item, tool: nil) },
            redact: { item in Self.edit(item, tool: .redact) },
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
        model.cards.removeAll { $0.id == item.id }
        model.cards.append(item)
        while model.cards.count > Self.maxCards {
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
        Task {
            await CaptureStore.shared.waitUntilWritten(item.id)
            switch item.kind {
            case .image: Clipboard.copy(imageFile: item.fileURL)
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
        let host = QuickAccessHostingView(rootView: QuickAccessRoot(model: model, actions: actions))
        host.model = model
        p.contentView = host
        panel = p
        hosting = host
    }

    static func panelSize(cards n: Int) -> CGSize {
        guard n > 0 else { return .zero }
        let header = n > 1 ? headerHeight : 0
        return CGSize(width: cardSize.width + 2 * padding,
                      height: CGFloat(n) * cardSize.height + CGFloat(n - 1) * spacing + header + 2 * padding)
    }

    private func layout(animated: Bool) {
        guard let panel else { return }
        let n = model.cards.count
        if n == 0 { panel.orderOut(nil); return }
        let screen = screen ?? NSScreen.withMouse
        let size = Self.panelSize(cards: n)
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.minX + 4, y: vf.minY + 4, width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

struct QuickAccessActions {
    var copy: (CaptureItem) -> Void
    var edit: (CaptureItem) -> Void
    var redact: (CaptureItem) -> Void
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
        MainActor.assumeIsolated {
            model?.hovered = nil
            model?.headerHovered = false
        }
    }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let yFromTop = isFlipped ? p.y : bounds.height - p.y
        MainActor.assumeIsolated {
            guard let model else { return }
            let n = model.cards.count
            let header = n > 1 ? QuickAccessController.headerHeight : 0
            var y = yFromTop - QuickAccessController.padding - header
            model.headerHovered = n > 1 && yFromTop < QuickAccessController.padding + header
            let x = p.x - QuickAccessController.padding
            guard x >= 0, x <= QuickAccessController.cardSize.width, y >= 0 else { model.hovered = nil; return }
            let stride = QuickAccessController.cardSize.height + QuickAccessController.spacing
            let index = Int(y / stride)
            y -= CGFloat(index) * stride
            if index < n, y <= QuickAccessController.cardSize.height {
                model.hovered = model.cards[index].id
            } else {
                model.hovered = nil
            }
        }
    }
}

struct QuickAccessRoot: View {
    @ObservedObject var model: QuickAccessModel
    let actions: QuickAccessActions

    var body: some View {
        VStack(spacing: QuickAccessController.spacing) {
            if model.cards.count > 1 {
                HStack {
                    Spacer()
                    Button { actions.closeAll() } label: {
                        Label("Alle schließen", systemImage: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(Capsule().fill(Color.black.opacity(0.72)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .opacity(model.headerHovered || model.hovered != nil ? 1 : 0.0)
                }
                .frame(height: QuickAccessController.headerHeight - QuickAccessController.spacing)
            }
            ForEach(model.cards) { item in
                QuickAccessCard(item: item, hovered: model.hovered == item.id, flashed: model.flashed == item.id, actions: actions)
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .padding(QuickAccessController.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: model.cards)
        .animation(.easeOut(duration: 0.12), value: model.hovered)
    }
}

struct QuickAccessCard: View {
    let item: CaptureItem
    let hovered: Bool
    let flashed: Bool
    let actions: QuickAccessActions

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.1))
            Thumbnail(item: item)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if item.kind != .image && !hovered {
                VStack {
                    Spacer()
                    HStack {
                        Label(item.kind == .gif ? "GIF" : Format.duration(item.duration ?? 0),
                              systemImage: item.kind == .gif ? "photo.stack" : "play.fill")
                            .font(.system(size: 10.5, weight: .bold))
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Capsule().fill(Color.black.opacity(0.7)))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                }
                .padding(8)
            }
            if hovered { hoverOverlay.transition(.opacity) }
            if flashed {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.6))
                Label("Kopiert", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: QuickAccessController.cardSize.width, height: QuickAccessController.cardSize.height)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) { actions.edit(item) }
        .onDrag { DragProvider.make(for: item) }
    }

    private var hoverOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.5))
            VStack(spacing: 7) {
                cardButton("Kopieren", symbol: "doc.on.doc") { actions.copy(item) }
                switch item.kind {
                case .image: cardButton("Zensieren", symbol: "eye.slash") { actions.redact(item) }
                case .video: cardButton("Bearbeiten", symbol: "scissors") { actions.edit(item) }
                case .gif: cardButton("Öffnen", symbol: "eye") { actions.edit(item) }
                }
            }
            VStack {
                HStack {
                    corner("xmark", help: "Schließen") { actions.close(item) }
                    Spacer()
                    if item.kind == .image {
                        corner("pencil", help: "Bearbeiten (Pfeile, Text, Zuschneiden …)") { actions.edit(item) }
                        corner("pin", help: "Anpinnen") { actions.pin(item) }
                    }
                }
                Spacer()
                HStack {
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

    private func cardButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 122, height: 30)
                .background(Capsule().fill(Color.white.opacity(0.94)))
                .foregroundStyle(Color.black.opacity(0.85))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func corner(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
                .foregroundStyle(.white)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct Thumbnail: View {
    let item: CaptureItem

    var body: some View {
        if let image = ThumbnailCache.shared.image(for: item) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.1))
        } else {
            Image(systemName: item.kind == .image ? "photo" : "film")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.4))
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
