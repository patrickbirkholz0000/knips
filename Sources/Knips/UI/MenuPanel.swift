import AppKit
import SwiftUI

/// Menüleisten-Panel: dunkel, abgerundet, Hauptaktion oben, Raster aus zwei Spalten, letzte Aufnahmen,
/// schlichte Fußzeile.
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
        let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
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
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
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
            quit: { NSApp.terminate(nil) }
        )
    }

    private func installMonitors() {
        removeMonitors()
        // Klick irgendwo anders schließt das Panel (globale Maus-Monitore brauchen keine Freigabe).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
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
    var quit: () -> Void
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
        MainActor.assumeIsolated {
            guard let model else { return }
            let hit = model.frames.first { $0.value.contains(point) }?.key
            if model.hovered != hit { model.hovered = hit }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        MainActor.assumeIsolated { model?.hovered = nil }
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

struct MenuPanelView: View {
    @ObservedObject var model: MenuPanelModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorder = RecordingController.shared
    let actions: MenuActions

    private static let panelColor = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            primary
            grid
            if !model.recent.isEmpty {
                divider
                recentRow
            }
            divider
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Self.panelColor))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .coordinateSpace(name: "menu")
        .onPreferenceChange(HoverFrames.self) { frames in
            MainActor.assumeIsolated { model.frames = frames }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.1), value: model.hovered)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "viewfinder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Knips")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if recorder.isRecording {
                Text("Aufnahme läuft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Hauptaktion als großes, ruhiges Feld mit Kürzel rechts.
    private var primary: some View {
        let id = "primary"
        let hovered = model.hovered == id
        return Button { actions.capture(.captureArea) } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 14, weight: .medium))
                Text("Bereich aufnehmen")
                    .font(.system(size: 13.5, weight: .medium))
                Spacer()
                shortcut(.captureArea)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(hovered ? 0.11 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverID(id)
    }

    private var grid: some View {
        let recording = recorder.isRecording
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            tile("window", "Fenster", "macwindow", .captureWindow) { actions.capture(.captureWindow) }
            tile("full", "Bildschirm", "display", .captureFullscreen) { actions.capture(.captureFullscreen) }
            tile("record", recording ? "Stoppen" : "Video", recording ? "stop.circle.fill" : "record.circle",
                 .toggleRecording, tint: recording ? .red : nil) { actions.capture(.toggleRecording) }
            tile("last", "Letzter Bereich", "arrow.counterclockwise", .captureLastArea) { actions.capture(.captureLastArea) }
            tile("text", "Text erfassen", "text.viewfinder", .captureText) { actions.capture(.captureText) }
            tile("pin", "Anpinnen", "pin", .pinClipboard) { actions.capture(.pinClipboard) }
            tile("open", "Bild öffnen", "photo.on.rectangle", nil, action: actions.openImage)
            tile("folder", "Ordner", "folder", nil, action: actions.openFolder)
        }
    }

    private func tile(_ id: String, _ title: String, _ symbol: String, _ hotkey: HotkeyAction?, tint: Color? = nil,
                      action: @escaping () -> Void) -> some View {
        let hovered = model.hovered == id
        return Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint ?? .white.opacity(0.75))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tint ?? .white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                if let hotkey { shortcut(hotkey) }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovered ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverID(id)
    }

    @ViewBuilder private func shortcut(_ action: HotkeyAction) -> some View {
        if let combo = settings.activeHotkeys[action] {
            Text(combo.display)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zuletzt")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 4)
            HStack(spacing: 8) {
                ForEach(model.recent) { item in
                    let id = "recent-\(item.id)"
                    Button { actions.openRecent(item) } label: {
                        ZStack(alignment: .bottomLeading) {
                            Thumbnail(item: item)
                                .frame(width: 70, height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            if item.kind != .image {
                                Image(systemName: item.kind == .gif ? "photo.stack" : "play.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(3)
                                    .background(Circle().fill(Color.black.opacity(0.6)))
                                    .foregroundStyle(.white)
                                    .padding(4)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(model.hovered == id ? 0.5 : 0.12), lineWidth: model.hovered == id ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverID(id)
                    .onDrag { DragProvider.make(for: item) }
                    .help(item.title)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            footerButton("settings", "Einstellungen", "gearshape", action: actions.settings)
            Spacer()
            footerButton("quit", "Beenden", "power", action: actions.quit)
        }
    }

    private func footerButton(_ id: String, _ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        let hovered = model.hovered == id
        return Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hovered ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverID(id)
    }
}
