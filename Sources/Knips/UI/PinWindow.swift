import AppKit

/// Schwebendes Bild über allen Fenstern. Ziehen verschiebt, Scrollen ändert die Größe,
/// Doppelklick oder Esc schließt.
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
        var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let vf = NSScreen.withMouse.visibleFrame
        let f = min(1, vf.width * 0.6 / size.width, vf.height * 0.6 / size.height)
        size = NSSize(width: size.width * f, height: size.height * f)
        let panel = PinPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size
        panel.minSize = NSSize(width: 60, height: 60 * size.height / max(size.width, 1))
        super.init(window: panel)
        panel.delegate = self
        let view = PinView(image: image)
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

private final class PinView: NSView {
    let image: CGImage
    var onClose: (() -> Void)?
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Schließen")
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.alphaValue = 0
        closeButton.wantsLayer = true
        closeButton.layer?.shadowOpacity = 0.5
        closeButton.layer?.shadowRadius = 3
        addSubview(closeButton)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: 6, y: bounds.height - 30, width: 24, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { closeButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { closeButton.animator().alphaValue = 0 }
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
            Clipboard.copy(image: image, fileURL: nil)
            Telemetry.count(.copyImage)
            HUD.show("Kopiert")
            return
        }
        super.keyDown(with: event)
    }

    @objc private func closeTapped() { onClose?() }
}
