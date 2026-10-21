import AppKit
import SwiftUI

/// Schwebendes Bild über allen Fenstern. Ziehen verschiebt, Scrollen ändert die Größe,
/// Doppelklick oder Esc schließt, ⌘C kopiert. Randlos mit Radius 10 und Schatten; beim Darüberfahren
/// erscheint oben rechts eine kleine dunkle Pille (Größe in Mono, Kopieren, Schließen).
@MainActor final class PinWindowController: NSWindowController, NSWindowDelegate {
    private static var pins: [PinWindowController] = []
    private let image: CGImage

    static func pin(_ image: CGImage, scale: CGFloat) {
        Telemetry.count(.pin)
        let controller = PinWindowController(image: image, scale: scale)
        pins.append(controller)
        controller.window?.orderFrontRegardless()
        controller.window?.makeKey()
    }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        let natural = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        var size = natural
        let vf = NSScreen.withMouse.visibleFrame
        let f = min(1, vf.width * 0.6 / size.width, vf.height * 0.6 / size.height)
        size = NSSize(width: size.width * f, height: size.height * f)
        let panel = PinPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        ScreenSharing.apply(to: panel)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = Brand.Dark.appearance
        panel.contentAspectRatio = size
        panel.minSize = NSSize(width: 60, height: 60 * size.height / max(size.width, 1))
        super.init(window: panel)
        panel.delegate = self
        let view = PinView(image: image, naturalWidth: natural.width)
        view.onClose = { [weak self] in self?.close() }
        panel.contentView = view
        panel.makeFirstResponder(view)
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: min(max(vf.minX, mouse.x - size.width / 2), vf.maxX - size.width),
                                     y: min(max(vf.minY, mouse.y - size.height / 2), vf.maxY - size.height)))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Self.pins.removeAll { $0 === self }
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Zustand der Pin-Steuerung (Größe in Prozent der Originalgröße).
@MainActor final class PinControlsModel: ObservableObject {
    @Published var percent = 100
}

/// Kleine dunkle Pille oben rechts auf einem angepinnten Bild.
struct PinControls: View {
    @ObservedObject var model: PinControlsModel
    var copy: () -> Void
    var close: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text("\(model.percent) %")
                .font(Brand.mono(11, .medium))
                .foregroundStyle(Color.brand(Brand.Dark.muted))
                .fixedSize()
                .padding(.leading, 9)
                .padding(.trailing, 3)
            Button(action: copy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(DarkIconButtonStyle(size: 24, symbolSize: 10.5, filled: false))
                .help("Kopieren (⌘C)")
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(DarkIconButtonStyle(size: 24, symbolSize: 10.5, filled: false))
                .help("Schließen (Esc)")
        }
        .padding(3)
        .darkSurface(Capsule())
        .environment(\.colorScheme, .dark)
    }
}

final class PinView: NSView {
    let image: CGImage
    var onClose: (() -> Void)?
    private let naturalWidth: CGFloat
    private let controlsModel = PinControlsModel()
    private var controls: NSView!
    private var tracking: NSTrackingArea?
    static let radius: CGFloat = 10
    /// Abstand der Pille zum Bildrand (Platz für ihren Schatten bleibt im Bild).
    private static let controlsInset: CGFloat = 8

    init(image: CGImage, naturalWidth: CGFloat) {
        self.image = image
        self.naturalWidth = max(1, naturalWidth)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let model = controlsModel
        let host = FirstMouseHostingView(rootView: PinControls(model: model, copy: { [weak self] in self?.copyImage() },
                                                               close: { [weak self] in self?.onClose?() }))
        host.appearance = Brand.Dark.appearance
        host.alphaValue = 0
        addSubview(host)
        controls = host
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let percent = Int((bounds.width / naturalWidth * 100).rounded())
        if controlsModel.percent != percent { controlsModel.percent = percent }
        let size = controls.fittingSize
        // Passt die Pille nicht ins Bild (sehr klein gezogen), bleibt sie unsichtbar; Esc/Doppelklick schließen weiter.
        controls.isHidden = size.width + 2 * Self.controlsInset > bounds.width || size.height + 2 * Self.controlsInset > bounds.height
        controls.frame = NSRect(x: bounds.maxX - size.width - Self.controlsInset, y: bounds.maxY - size.height - Self.controlsInset,
                                width: size.width, height: size.height)
        window?.invalidateShadow()
    }

    #if KNIPS_DEV
    /// Nur Selbsttest: Steuerung zeigen wie beim Darüberfahren.
    func debugShowControls() { controls.alphaValue = 1 }
    #endif

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { controls.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { controls.animator().alphaValue = 0 }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onClose?(); return }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        var frame = window.frame
        let newW = max(60, frame.width * factor)
        let newH = newW * frame.height / frame.width
        frame.origin.x -= (newW - frame.width) / 2
        frame.origin.y -= (newH - frame.height) / 2
        frame.size = NSSize(width: newW, height: newH)
        window.setFrame(frame, display: true)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copyImage()
            return
        }
        super.keyDown(with: event)
    }

    private func copyImage() {
        Clipboard.copy(image: image, fileURL: nil)
        Telemetry.count(.copyImage)
        HUD.show("Kopiert")
    }
}
