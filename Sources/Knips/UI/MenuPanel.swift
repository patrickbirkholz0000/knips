import AppKit
import SwiftUI

/// Menüleisten-Panel: immer dunkel (Radius 16), Hauptaktion oben, Raster aus zwei Spalten, letzte Aufnahmen,
/// leise Fußzeile.
@MainActor final class MenuPanelController {
    static let shared = MenuPanelController()

    private var panel: MenuPanel?
    private var host: MenuHostingView?
    private let model = MenuPanelModel()
    private var monitors: [Any] = []

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(below button: NSStatusBarButton) {
        isOpen ? close() : show(below: button)
    }

    func show(below button: NSStatusBarButton) {
        let panel = panel ?? makePanel()
        model.hovered = nil
        model.recent = Array(CaptureStore.shared.recent.prefix(4))
        host?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? NSSize(width: 320, height: 400)
        let anchor = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } ?? .zero
        let screen = button.window?.screen ?? NSScreen.withMouse
        let vf = screen.visibleFrame
        var origin = NSPoint(x: anchor.minX - 10, y: anchor.minY - 6 - size.height)
        origin.x = max(vf.minX + 8, min(origin.x, vf.maxX - size.width - 8))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    /// Erst schließen, dann ausführen — das Panel soll nie im Screenshot landen oder darüber liegen.
    private func run(_ action: @escaping () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: action)
    }

    private func makePanel() -> MenuPanel {
        let p = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ScreenSharing.apply(to: p)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.appearance = Brand.Dark.appearance
        let view = MenuHostingView(rootView: MenuPanelView(model: model, actions: actions))
        view.model = model
        p.contentView = view
        panel = p
        host = view
        return p
    }

    private var actions: MenuActions {
        MenuActions(
            capture: { [weak self] a in self?.run { CaptureCoordinator.shared.perform(a) } },
            openImage: { [weak self] in self?.run { CaptureCoordinator.shared.openImageFile() } },
            openFolder: { [weak self] in
                self?.run {
                    let folder = AppSettings.shared.saveFolder
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
            },
            openRecent: { [weak self] item in self?.run { QuickAccessController.edit(item, tool: nil) } },
            settings: { [weak self] in self?.run { SettingsWindowController.show() } },
            history: { [weak self] in self?.run { HistoryWindowController.show() } },
            quit: { NSApp.terminate(nil) },
            update: { [weak self] in self?.run { Updates.shared.continueUpdate() } }
        )
    }

    private func installMonitors() {
        removeMonitors()
        // Klick irgendwo anders schließt das Panel (globale Maus-Monitore brauchen keine Freigabe).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            onMainActor { self?.close() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            // Klicks auf das Statussymbol schalten das Panel selbst um (StatusBarController).
            let isStatusItem = event.window.map { NSStringFromClass(type(of: $0)).contains("StatusBar") } ?? false
            if event.window !== self.panel, !isStatusItem { self.close() }
            return event
        }) { monitors.append(l) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct MenuActions {
    var capture: (HotkeyAction) -> Void
    var openImage: () -> Void
    var openFolder: () -> Void
    var openRecent: (CaptureItem) -> Void
    var settings: () -> Void
    var history: () -> Void
    var quit: () -> Void
    /// Hinweis auf ein Update: installieren („Neu starten“), laden oder ansehen.
    var update: () -> Void = {}
}

@MainActor final class MenuPanelModel: ObservableObject {
    @Published var hovered: String?
    @Published var recent: [CaptureItem] = []
    var frames: [String: CGRect] = [:]
}

/// Hover über eine eigene Tracking-Area — funktioniert auch, wenn Knips nicht die aktive App ist.
final class MenuHostingView: NSHostingView<MenuPanelView> {
    weak var model: MenuPanelModel?
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
        let p = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        onMainActor {
            guard let model else { return }
            let hit = model.frames.first { $0.value.contains(point) }?.key
            if model.hovered != hit { model.hovered = hit }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMainActor { model?.hovered = nil }
    }
}

private struct HoverFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func hoverID(_ id: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: HoverFrames.self, value: [id: g.frame(in: .named("menu"))])
        })
    }
}

// MARK: - Inhalt

/// Panel-Inhalt (docs/design.md, „Menü-Panel“): Kopf mit Zeichen, Wortmarke und Status; Hauptaktion als große
/// gehobene Zeile mit Tastenkappen; Raster der weiteren Aktionen; `ZULETZT` mit Vorschaubildern; leiser Hinweis auf ein
/// geladenes Update; leiser Fuß.
struct MenuPanelView: View {
    @ObservedObject var model: MenuPanelModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorder = RecordingController.shared
    @ObservedObject private var scroll = ScrollCaptureController.shared
    @ObservedObject private var updates = Updates.shared
    let actions: MenuActions

    static let width: CGFloat = 344
    private static let inset: CGFloat = 14
    private static var contentWidth: CGFloat { width - 2 * inset }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)
            primary
                .padding(.bottom, 8)
            grid
            if !model.recent.isEmpty {
                divider.padding(.vertical, 14)
                recentRow
            }
            divider.padding(.top, 14).padding(.bottom, 6)
            if let notice = updateNotice {
                updateRow(notice).padding(.top, 4).padding(.bottom, 6)
            }
            footer
        }
        .padding(Self.inset)
        .frame(width: Self.width)
        // Schatten kommt vom Fenster (folgt der runden Form), deshalb hier keiner.
        .darkSurface(shape, shadow: false)
        .clipShape(shape)
        .coordinateSpace(name: "menu")
        .onPreferenceChange(HoverFrames.self) { frames in
            onMainActor { model.frames = frames }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.1), value: model.hovered)
    }

    private var divider: some View {
        Rectangle().fill(Color.brand(Brand.Dark.line)).frame(height: 1)
    }

    // MARK: Kopf

    private var header: some View {
        let recording = recorder.isRecording
        return HStack(spacing: 8) {
            BrandMark(size: 22, recording: recording)
            Wordmark(size: 19, recording: recording)
            Spacer(minLength: 8)
            status
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .frame(height: 26)
    }

    @ViewBuilder private var status: some View {
        switch recorder.phase {
        case .recording:
            HStack(spacing: 6) {
                RecordDot(size: 7)
                Text(Format.duration(recorder.elapsed))
                    .font(Brand.mono(12, .medium))
                    .foregroundStyle(Color.brand(Brand.Dark.record))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Aufnahme läuft, \(Format.duration(recorder.elapsed))")
        case .starting, .countdown, .finishing:
            statusLabel(Brand.Dark.muted, "Einen Moment")
        case .idle:
            if ScreenCapture.hasPermission {
                statusLabel(Brand.Dark.success, "Bereit")
            } else {
                statusLabel(Brand.Dark.record, "Freigabe fehlt")
            }
        }
    }

    private func statusLabel(_ color: NSColor, _ text: String) -> some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: 6)
            Text(text)
                .font(Brand.font(12, .medium))
                .foregroundStyle(Color.brand(Brand.Dark.muted))
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: Hauptaktion

    private var primary: some View {
        let id = "primary"
        let hovered = model.hovered == id
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { actions.capture(.captureArea) } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.brand(Brand.Dark.accent))
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.brand(Brand.Dark.accentSoft)))
                Text("Bereich aufnehmen")
                    .font(Brand.font(15, .medium))
                    .foregroundStyle(Color.brand(Brand.Dark.ink))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let combo = settings.activeHotkeys[.captureArea] { KeyCaps(combo: combo, size: 11.5) }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 54)
            .background(shape.fill(Color.brand(hovered ? Brand.Dark.hover : Brand.Dark.raised)))
            .overlay(shape.strokeBorder(Color.brand(hovered ? Brand.Dark.accent.withAlphaComponent(0.45) : Brand.Dark.line)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .hoverID(id)
    }

    // MARK: Raster

    private var grid: some View {
        let recording = recorder.isRecording
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            tile("window", "Fenster", "macwindow", .captureWindow) { actions.capture(.captureWindow) }
            tile("full", "Bildschirm", "display", .captureFullscreen) { actions.capture(.captureFullscreen) }
            tile("record", recording ? "Stoppen" : "Video", recording ? "stop.circle.fill" : "record.circle",
                 .toggleRecording, tint: recording ? Brand.Dark.record : nil) { actions.capture(.toggleRecording) }
            tile("last", "Letzter Bereich", "arrow.counterclockwise", .captureLastArea) { actions.capture(.captureLastArea) }
            tile("scroll", "Scrollen", "arrow.down.doc", .captureScrolling) { actions.capture(.captureScrolling) }
            tile("text", "Text erfassen", "text.viewfinder", .captureText) { actions.capture(.captureText) }
            tile("pin", "Anpinnen", "pin", .pinClipboard) { actions.capture(.pinClipboard) }
            tile("open", "Bild öffnen", "photo.on.rectangle", nil, action: actions.openImage)
        }
    }

    private func tile(_ id: String, _ title: String, _ symbol: String, _ hotkey: HotkeyAction?, tint: NSColor? = nil,
                      action: @escaping () -> Void) -> some View {
        let hovered = model.hovered == id
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.button, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.brand(tint ?? (hovered ? Brand.Dark.ink : Brand.Dark.muted)))
                    .frame(width: 18)
                Text(title)
                    .font(Brand.font(13, .medium))
                    .foregroundStyle(Color.brand(tint ?? Brand.Dark.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                if let hotkey, let combo = settings.activeHotkeys[hotkey] {
                    KeySymbols.text(combo, size: 10.5)
                        .foregroundStyle(Color.brand(Brand.Dark.muted).opacity(0.85))
                        .accessibilityLabel(combo.display)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .frame(height: 40)
            .background(shape.fill(Color.brand(hovered ? Brand.Dark.hover : Brand.Dark.raised.withAlphaComponent(0.55))))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .hoverID(id)
    }

    // MARK: Zuletzt

    private var recentRow: some View {
        let spacing: CGFloat = 8
        let thumbWidth = ((Self.contentWidth - 3 * spacing) / 4).rounded(.down)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Overline(text: "Zuletzt")
                Spacer()
                Button { actions.history() } label: {
                    Text("Alle anzeigen →")
                        .font(Brand.font(12, .medium))
                        .foregroundStyle(Color.brand(model.hovered == "history" ? Brand.Dark.ink : Brand.Dark.muted))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverID("history")
            }
            .padding(.horizontal, 2)
            HStack(spacing: spacing) {
                ForEach(model.recent) { item in
                    recentThumb(item, width: thumbWidth)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func recentThumb(_ item: CaptureItem, width: CGFloat) -> some View {
        let id = "recent-\(item.id)"
        let hovered = model.hovered == id
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { actions.openRecent(item) } label: {
            Thumbnail(item: item, background: .brand(Brand.Dark.raised))
                .frame(width: width, height: (width * 0.66).rounded())
                .background(Color.brand(Brand.Dark.raised))
                .clipShape(shape)
                .overlay(alignment: .bottomLeading) {
                    if item.kind != .image {
                        MediaBadge(item: item, compact: true).padding(4)
                    }
                }
                .overlay(shape.strokeBorder(Color.brand(hovered ? Brand.Dark.accent : Brand.Dark.line), lineWidth: hovered ? 1.5 : 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .hoverID(id)
        .onDrag { DragProvider.make(for: item) }
        .help(item.title)
    }

    // MARK: Update

    private struct UpdateNotice {
        let symbol: String
        let title: String
        let detail: String
        let button: String
        let help: String
        var enabled = true
    }

    /// Nur, wenn es etwas zu tun gibt: geladenes Update, gefundenes Update oder Hinweis auf eine neue Version.
    private var updateNotice: UpdateNotice? {
        switch updates.state {
        case let .ready(version):
            let busy = recorder.isBusy || scroll.active
            return UpdateNotice(symbol: "arrow.down.circle", title: "Knips \(version) ist bereit",
                                detail: busy ? "Nach der Aufnahme möglich" : "Installiert beim Beenden",
                                button: "Neu starten", help: "Neu starten und aktualisieren", enabled: !busy)
        case let .available(version):
            return UpdateNotice(symbol: "arrow.down.circle", title: "Knips \(version) ist verfügbar", detail: "Noch nicht geladen",
                                button: "Laden", help: "Laden und installieren")
        case let .info(version, _):
            return UpdateNotice(symbol: "info.circle", title: "Knips \(version) ist verfügbar", detail: "Mehr dazu auf GitHub",
                                button: "Ansehen", help: "Release-Seite öffnen")
        default:
            return nil
        }
    }

    private func updateRow(_ notice: UpdateNotice) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 10) {
            Image(systemName: notice.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brand(Brand.Dark.accent))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.brand(Brand.Dark.accentSoft)))
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(Brand.font(13, .medium))
                    .foregroundStyle(Color.brand(Brand.Dark.ink))
                    .lineLimit(1)
                Text(notice.detail)
                    .font(Brand.font(11.5))
                    .foregroundStyle(Color.brand(Brand.Dark.muted))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(notice.button, action: actions.update)
                .buttonStyle(DarkButtonStyle(kind: .primary, height: 26, fontSize: 12))
                .disabled(!notice.enabled)
                .opacity(notice.enabled ? 1 : 0.45)
                .help(notice.help)
                .accessibilityLabel(notice.help)
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background(shape.fill(Color.brand(Brand.Dark.raised.withAlphaComponent(0.55))))
        .overlay(shape.strokeBorder(Color.brand(Brand.Dark.line)))
    }

    // MARK: Fuß

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton("settings", "Einstellungen", "gearshape", action: actions.settings)
            footerButton("folder", "Ordner", "folder", action: actions.openFolder)
            Spacer()
            footerButton("quit", "Beenden", "power", action: actions.quit)
        }
        .padding(.horizontal, -6)
    }

    private func footerButton(_ id: String, _ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        let hovered = model.hovered == id
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                Text(title).font(Brand.font(12.5, .medium))
            }
            .foregroundStyle(Color.brand(hovered ? Brand.Dark.ink : Brand.Dark.muted))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? Color.brand(Brand.Dark.hover) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverID(id)
    }
}

