import AppKit
import SwiftUI

/// Alle Aufnahmen auf einen Blick — Papier, Kopfzeile mit Titel und Anzahl, Filter als Segment-Schalter,
/// Raster aus weißen Karten (docs/design.md, „Verlauf“).
@MainActor final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: HistoryWindowController?
    static let size = NSSize(width: 980, height: 680)
    /// Bei DockPresence angemeldet (zwischen Öffnen und Schließen) — erneutes Öffnen zählt nicht doppelt.
    private var inDock = false

    static func show() {
        Telemetry.count(.historyOpen)
        if instance == nil { instance = HistoryWindowController() }
        if let instance, !instance.inDock {
            instance.inDock = true
            DockPresence.windowOpened()
        }
        instance?.showWindow(nil)
        instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `filter`/`hovered`: Ausgangszustand (Selbsttest).
    init(filter: HistoryFilter = .all, hovered: UUID? = nil) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        ScreenSharing.apply(to: window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Knips – Verlauf"
        // Keine feste Darstellung: folgt `NSApp.appearance` (Einstellung „Darstellung“).
        window.backgroundColor = Brand.canvas
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.contentView = NSHostingView(rootView: HistoryView(store: CaptureStore.shared, filter: filter, hovered: hovered))
        // Fensterposition merkt sich AppKit in der echten Domäne — Selbsttests legen das Fenster neben den Bildschirm.
        let autosave = Paths.testRoot == nil
        if autosave { window.setFrameAutosaveName("KnipsHistory") }
        super.init(window: window)
        window.delegate = self
        if !autosave || !window.setFrameUsingName("KnipsHistory") { window.center() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        if inDock {
            inDock = false
            DockPresence.windowClosed()
        }
    }
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, images, videos, gifs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Alle"
        case .images: "Screenshots"
        case .videos: "Videos"
        case .gifs: "GIFs"
        }
    }
    func matches(_ item: CaptureItem) -> Bool {
        switch self {
        case .all: true
        case .images: item.kind == .image
        case .videos: item.kind == .video
        case .gifs: item.kind == .gif
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: CaptureStore
    @State private var filter: HistoryFilter
    @State private var hovered: UUID?

    init(store: CaptureStore, filter: HistoryFilter = .all, hovered: UUID? = nil) {
        self.store = store
        _filter = State(initialValue: filter)
        _hovered = State(initialValue: hovered)
    }

    private var items: [CaptureItem] { store.items.filter { filter.matches($0) } }

    private var countLine: Text {
        let days = AppSettings.shared.retentionDays
        return Text("\(store.items.count)").font(Brand.mono(13.5, .medium))
            + Text(store.items.count == 1 ? " Aufnahme" : " Aufnahmen")
            + Text(days == 0 ? ", unbegrenzt aufbewahrt" : " der letzten ")
            + (days == 0 ? Text("") : Text("\(days)").font(Brand.mono(13.5, .medium)) + Text(" Tage"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Verlauf")
                        .font(Brand.font(28, .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.brand(Brand.ink))
                    countLine
                        .font(Brand.font(14))
                        .foregroundStyle(Color.brand(Brand.inkSoft))
                }
                Spacer(minLength: 12)
                BrandSegmented(selection: $filter, options: HistoryFilter.allCases.map { ($0, $0.title) })
            }
            .padding(.horizontal, 32)
            .padding(.top, 46)
            .padding(.bottom, 22)
            if items.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 16)], spacing: 16) {
                        ForEach(items) { item in
                            HistoryCard(item: item, hovered: hovered == item.id)
                                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.brand(Brand.canvas))
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.15), value: filter)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            BrandIconTile(symbol: "photo.on.rectangle.angled", size: 52)
            Text(store.items.isEmpty ? "Noch nichts hier" : "Keine \(filter.title) im Verlauf")
                .font(Brand.font(17, .semibold))
                .foregroundStyle(Color.brand(Brand.ink))
            if store.items.isEmpty, let combo = AppSettings.shared.activeHotkeys[.captureArea] {
                (Text("Mit ") + combo.inlineText(size: 13.5) + Text(" einen Bereich aufnehmen."))
                    .font(Brand.font(13.5))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

private struct HistoryCard: View {
    let item: CaptureItem
    let hovered: Bool

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d. MMM · HH:mm"
        // „20. Okt · 18:03“ — Monatskürzel ohne Punkt.
        f.shortMonthSymbols = f.shortMonthSymbols.map { $0.replacingOccurrences(of: ".", with: "") }
        return f
    }()

    /// Datum · Uhrzeit · Größe (die Dauer eines Videos steht im Abzeichen auf dem Bild).
    private var meta: String {
        "\(Self.date.string(from: item.createdAt)) · \(item.pixelWidth) × \(item.pixelHeight)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(Color.brand(Brand.fill))
                Thumbnail(item: item, background: .brand(Brand.fill)).padding(12)
                if item.kind != .image {
                    VStack {
                        Spacer()
                        HStack {
                            badge
                            Spacer()
                        }
                    }
                    .padding(10)
                }
                if hovered {
                    VStack {
                        HStack(spacing: 6) {
                            Spacer()
                            action("doc.on.doc", "Kopieren") { copy() }
                            action(item.kind == .image ? "eye.slash" : "scissors", item.kind == .image ? "Zensieren" : "Bearbeiten") {
                                QuickAccessController.edit(item, tool: item.kind == .image ? .redact : nil)
                            }
                            action("folder", "Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                            action("trash", "Löschen") { CaptureStore.shared.delete(item) }
                        }
                        Spacer()
                    }
                    .padding(10)
                    .transition(.opacity)
                }
            }
            .frame(height: 150)
            .clipped()
            Rectangle().fill(Color.brand(Brand.line)).frame(height: 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(Brand.font(13, .medium))
                    .foregroundStyle(Color.brand(Brand.ink))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(Brand.mono(11))
                    .foregroundStyle(Color.brand(Brand.inkSoft))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color.brand(Brand.surface))
        .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
            .strokeBorder(Color.brand(hovered ? Brand.accent : Brand.line), lineWidth: hovered ? 1.5 : 1))
        .shadow(color: .brand(Brand.Dark.fill).opacity(hovered ? 0.08 : 0.03), radius: hovered ? 8 : 1, y: hovered ? 3 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { QuickAccessController.edit(item, tool: nil) }
        .onDrag { DragProvider.make(for: item) }
    }

    /// Dauer bzw. „GIF“ als dunkle Pille (schwebt über dem Bild).
    private var badge: some View {
        HStack(spacing: 4) {
            Image(systemName: item.kind == .gif ? "photo.stack" : "play.fill").font(.system(size: 8.5, weight: .bold))
            Text(item.kind == .gif ? "GIF" : Format.duration(item.duration ?? 0)).font(Brand.mono(10.5, .medium))
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Color.brand(Brand.Dark.fill).opacity(0.85)))
        .foregroundStyle(Color.brand(Brand.Dark.ink))
    }

    private func copy() {
        if item.kind == .image { Telemetry.count(.copyImage) }
        Task {
            await CaptureStore.shared.waitUntilWritten(item.id)
            if item.kind == .image { Clipboard.copy(imageFile: item.fileURL, item: item.id) } else { Clipboard.copy(fileURL: item.fileURL) }
            HUD.show("Kopiert")
        }
    }

    /// Kleiner dunkler Knopf über dem Vorschaubild (dunkel schwebt).
    private func action(_ symbol: String, _ help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.brand(Brand.Dark.fill).opacity(0.88)))
                .overlay(Circle().strokeBorder(Color.brand(Brand.Dark.line)))
                .foregroundStyle(Color.brand(Brand.Dark.ink))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
