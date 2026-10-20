import AppKit
import SwiftUI

/// Alle Aufnahmen auf einen Blick — gleiche Gestaltung wie die Einstellungen (helle Fläche, weiße Karten).
@MainActor final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: HistoryWindowController?
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

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Knips – Verlauf"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(Theme.page)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.contentView = NSHostingView(rootView: HistoryView(store: CaptureStore.shared))
        window.setFrameAutosaveName("KnipsHistory")
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("KnipsHistory") { window.center() }
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
    @State private var filter: HistoryFilter = .all
    @State private var hovered: UUID?

    private var items: [CaptureItem] { store.items.filter { filter.matches($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Verlauf").font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundStyle(Theme.ink)
                    Text("\(store.items.count) Aufnahmen der letzten \(AppSettings.shared.retentionDays == 0 ? "Zeit" : "\(AppSettings.shared.retentionDays) Tage")")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(HistoryFilter.allCases) { f in
                        Button(f.title) { filter = f }
                            .buttonStyle(ChipStyle(selected: filter == f))
                    }
                }
            }
            .padding(.top, 30)
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(Theme.muted)
                    Text("Noch nichts hier").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Mit ⇧⌘4 einen Bereich aufnehmen.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 16)], spacing: 16) {
                        ForEach(items) { item in
                            HistoryCard(item: item, hovered: hovered == item.id)
                                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.page)
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.15), value: filter)
    }
}

private struct ChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Capsule().fill(selected ? Theme.ink : Color.white))
            .overlay(Capsule().strokeBorder(selected ? .clear : Theme.border))
            .foregroundStyle(selected ? .white : Theme.ink)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct HistoryCard: View {
    let item: CaptureItem
    let hovered: Bool

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d. MMM, HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(Theme.soft)
                Thumbnail(item: item, background: Theme.soft).padding(10)
                if item.kind != .image {
                    VStack {
                        Spacer()
                        HStack {
                            Label(item.kind == .gif ? "GIF" : Format.duration(item.duration ?? 0),
                                  systemImage: item.kind == .gif ? "photo.stack" : "play.fill")
                                .font(.system(size: 10.5, weight: .bold))
                                .padding(.horizontal, 7).frame(height: 20)
                                .background(Capsule().fill(Color.black.opacity(0.65)))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                    }
                    .padding(8)
                }
                if hovered {
                    Color.black.opacity(0.35)
                    HStack(spacing: 8) {
                        action("doc.on.doc", "Kopieren") { copy() }
                        action(item.kind == .image ? "eye.slash" : "scissors", item.kind == .image ? "Zensieren" : "Bearbeiten") {
                            QuickAccessController.edit(item, tool: item.kind == .image ? .redact : nil)
                        }
                        action("folder", "Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                        action("trash", "Löschen") { CaptureStore.shared.delete(item) }
                    }
                }
            }
            .frame(height: 150)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(Self.date.string(from: item.createdAt)) · \(item.pixelWidth)×\(item.pixelHeight)")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(hovered ? 0.1 : 0), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { QuickAccessController.edit(item, tool: nil) }
        .onDrag { DragProvider.make(for: item) }
    }

    private func copy() {
        if item.kind == .image { Telemetry.count(.copyImage) }
        Task {
            await CaptureStore.shared.waitUntilWritten(item.id)
            if item.kind == .image { Clipboard.copy(imageFile: item.fileURL) } else { Clipboard.copy(fileURL: item.fileURL) }
            HUD.show("Kopiert")
        }
    }

    private func action(_ symbol: String, _ help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white))
                .foregroundStyle(Theme.ink)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
