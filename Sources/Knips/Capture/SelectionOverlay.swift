import AppKit
import QuartzCore

enum SelectionPurpose { case screenshot, recording }

enum SelectionResult {
    /// Rechteck in Punkten relativ zum Bildschirm, Ursprung unten links.
    case area(FrozenScreen, CGRect)
    case window(WindowInfo, FrozenScreen)
    case fullScreen(FrozenScreen)
    case cancelled
}

/// Vollbild-Overlay je Bildschirm über dem eingefrorenen Standbild. Ziehen = Bereich,
/// Leertaste = Fenstermodus, ⏎ = ganzer Bildschirm, Esc = Abbruch.
@MainActor final class SelectionOverlay {
    let purpose: SelectionPurpose
    let windowInfos: [WindowInfo]
    private let frozen: [FrozenScreen]
    private var windows: [OverlayWindow] = []
    private var views: [SelectionView] = []
    private var completion: ((SelectionResult) -> Void)?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private(set) var mouse: CGPoint = NSEvent.mouseLocation
    var windowMode: Bool { didSet { refreshAll() } }
    var isDragging = false

    init(frozen: [FrozenScreen], windows: [WindowInfo], purpose: SelectionPurpose, windowMode: Bool,
         completion: @escaping (SelectionResult) -> Void) {
        self.frozen = frozen
        self.windowInfos = windows
        self.purpose = purpose
        self.windowMode = windowMode
        self.completion = completion
    }

    func present() {
        previousApp = NSWorkspace.shared.frontmostApplication
        for f in frozen {
            let window = OverlayWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(f.screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = SelectionView(frozen: f, overlay: self)
            view.frame = NSRect(origin: .zero, size: f.screen.frame.size)
            window.contentView = view
            windows.append(window)
            views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        let target = zip(windows, frozen).first { NSMouseInRect(mouse, $0.1.screen.frame, false) }?.0 ?? windows.first
        target?.makeKey()
        if let target, let view = target.contentView { target.makeFirstResponder(view) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        NSCursor.crosshair.set()
        refreshAll()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: finish(.cancelled); return true
        case 49:
            if !isDragging { windowMode.toggle() }
            return true
        case 36, 76:
            if let f = frozen.first(where: { NSMouseInRect(mouse, $0.screen.frame, false) }) ?? frozen.first {
                finish(.fullScreen(f))
            }
            return true
        default:
            return false
        }
    }

    func mouseMoved(to global: CGPoint) {
        mouse = global
        refreshAll()
    }

    func refreshAll() { views.forEach { $0.refresh() } }

    /// Vorderstes Fenster unter dem Punkt (global, Cocoa).
    func hoveredWindow() -> WindowInfo? {
        windowInfos.first { $0.frame.contains(mouse) }
    }

    func finish(_ result: SelectionResult) {
        guard let completion else { return }
        self.completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        // Fokus zurück an die App, in der gearbeitet wurde.
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
        completion(result)
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    let frozen: FrozenScreen
    private unowned let overlay: SelectionOverlay
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var tracking: NSTrackingArea?

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let crossH = CALayer()
    private let crossV = CALayer()
    private let sizeBG = CALayer()
    private let sizeText = CATextLayer()
    private let hintBG = CALayer()
    private let hintText = CATextLayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeCenter = CALayer()
    private let loupeText = CATextLayer()

    private static let loupeSize: CGFloat = 132
    private static let loupePixels = 13

    init(frozen: FrozenScreen, overlay: SelectionOverlay) {
        self.frozen = frozen
        self.overlay = overlay
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setupLayers() {
        guard let root = layer else { return }
        let scale = frozen.screen.backingScaleFactor
        imageLayer.contents = frozen.image
        imageLayer.contentsGravity = .resize
        root.addSublayer(imageLayer)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.38).cgColor
        root.addSublayer(dimLayer)

        highlightLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        highlightLayer.strokeColor = NSColor.controlAccentColor.cgColor
        highlightLayer.lineWidth = 3
        root.addSublayer(highlightLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1
        borderLayer.shadowColor = NSColor.black.cgColor
        borderLayer.shadowOpacity = 0.6
        borderLayer.shadowRadius = 1
        borderLayer.shadowOffset = .zero
        root.addSublayer(borderLayer)

        for l in [crossH, crossV] {
            l.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.5
            l.shadowRadius = 0.5
            l.shadowOffset = .zero
            root.addSublayer(l)
        }

        for (bg, text) in [(sizeBG, sizeText), (hintBG, hintText)] {
            bg.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
            bg.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            bg.borderWidth = 1
            text.contentsScale = scale
            text.foregroundColor = NSColor.white.cgColor
            text.alignmentMode = .center
            bg.addSublayer(text)
            root.addSublayer(bg)
        }
        sizeText.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        sizeText.fontSize = 12
        hintText.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        hintText.fontSize = 12.5

        loupe.frame = CGRect(x: 0, y: 0, width: Self.loupeSize, height: Self.loupeSize)
        loupe.cornerRadius = Self.loupeSize / 2
        loupe.masksToBounds = true
        loupe.borderColor = NSColor.white.cgColor
        loupe.borderWidth = 2
        loupe.backgroundColor = NSColor.black.cgColor
        loupeImage.frame = loupe.bounds
        loupeImage.magnificationFilter = .nearest
        loupeImage.contentsGravity = .resize
        loupe.addSublayer(loupeImage)
        let cell = Self.loupeSize / CGFloat(Self.loupePixels)
        loupeCenter.frame = CGRect(x: (Self.loupeSize - cell) / 2, y: (Self.loupeSize - cell) / 2, width: cell, height: cell)
        loupeCenter.borderColor = NSColor.white.cgColor
        loupeCenter.borderWidth = 1.5
        loupe.addSublayer(loupeCenter)
        root.addSublayer(loupe)
        loupeText.contentsScale = scale
        loupeText.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        loupeText.fontSize = 10.5
        loupeText.foregroundColor = NSColor.white.cgColor
        loupeText.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        loupeText.cornerRadius = 5
        loupeText.alignmentMode = .center
        root.addSublayer(loupeText)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        if window?.isKeyWindow == false { window?.makeKey(); window?.makeFirstResponder(self) }
        overlay.mouseMoved(to: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = clamp(convert(event.locationInWindow, from: nil))
        selection = nil
        overlay.isDragging = true
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = clamp(convert(event.locationInWindow, from: nil))
        var r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        if event.modifierFlags.contains(.shift) {
            let side = max(r.width, r.height)
            r = CGRect(x: p.x < start.x ? start.x - side : start.x, y: p.y < start.y ? start.y - side : start.y, width: side, height: side)
                .intersection(bounds)
        }
        selection = r
        overlay.mouseMoved(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        overlay.isDragging = false
        defer { dragStart = nil }
        if let r = selection, r.width >= 4, r.height >= 4 {
            overlay.finish(.area(frozen, r.integral))
            return
        }
        selection = nil
        if overlay.windowMode, let w = overlay.hoveredWindow() {
            overlay.finish(.window(w, frozen))
            return
        }
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) { overlay.finish(.cancelled) }

    /// Nur für Selbsttests.
    func debugSelect(_ r: CGRect) { selection = r }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(p.x, bounds.width)), y: max(0, min(p.y, bounds.height)))
    }

    // MARK: Darstellung

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let screenFrame = frozen.screen.frame
        let mouseInside = NSMouseInRect(overlay.mouse, screenFrame, false)
        let local = CGPoint(x: overlay.mouse.x - screenFrame.minX, y: overlay.mouse.y - screenFrame.minY)
        let dragging = selection != nil

        // Abdunkeln mit Loch für Auswahl bzw. Fenster
        var hole: CGRect?
        if let selection {
            hole = selection
        } else if overlay.windowMode, let w = overlay.hoveredWindow() {
            hole = w.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds)
        }
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole, !hole.isNull { path.addRect(hole) }
        dimLayer.path = path

        if !dragging, overlay.windowMode, let hole, !hole.isNull {
            highlightLayer.path = CGPath(rect: hole.insetBy(dx: 1.5, dy: 1.5), transform: nil)
            highlightLayer.isHidden = false
        } else {
            highlightLayer.isHidden = true
        }

        if let selection {
            borderLayer.path = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            borderLayer.isHidden = false
            let s = frozen.scale
            setLabel(sizeText, bg: sizeBG, text: "\(Int((selection.width * s).rounded())) × \(Int((selection.height * s).rounded()))")
            var origin = CGPoint(x: selection.maxX - sizeBG.bounds.width, y: selection.minY - sizeBG.bounds.height - 8)
            if origin.y < 4 { origin.y = selection.minY + 8 }
            origin.x = max(4, min(origin.x, bounds.width - sizeBG.bounds.width - 4))
            sizeBG.frame.origin = origin
            sizeBG.isHidden = false
        } else {
            borderLayer.isHidden = true
            sizeBG.isHidden = true
        }

        let showCross = mouseInside && !overlay.windowMode && !dragging
        crossH.isHidden = !showCross
        crossV.isHidden = !showCross
        if showCross {
            crossH.frame = CGRect(x: 0, y: local.y.rounded() - 0.5, width: bounds.width, height: 1)
            crossV.frame = CGRect(x: local.x.rounded() - 0.5, y: 0, width: 1, height: bounds.height)
        }

        updateLoupe(local: local, visible: mouseInside && !overlay.windowMode)
        updateHint(visible: mouseInside && !dragging)
    }

    private func updateLoupe(local: CGPoint, visible: Bool) {
        loupe.isHidden = !visible
        loupeText.isHidden = !visible
        guard visible else { return }
        let s = frozen.scale
        let px = Int(local.x * s), py = Int((bounds.height - local.y) * s)
        let half = Self.loupePixels / 2
        let region = CGRect(x: px - half, y: py - half, width: Self.loupePixels, height: Self.loupePixels)
        let clipped = region.intersection(CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height))
        if !clipped.isNull, let crop = frozen.image.cropping(to: clipped) {
            loupeImage.contents = crop
            let cell = Self.loupeSize / CGFloat(Self.loupePixels)
            loupeImage.frame = CGRect(x: (clipped.minX - region.minX) * cell,
                                      y: (region.maxY - clipped.maxY) * cell,
                                      width: clipped.width * cell, height: clipped.height * cell)
        }
        let size = Self.loupeSize
        var o = CGPoint(x: local.x + 26, y: local.y - size - 26)
        if o.x + size > bounds.width - 4 { o.x = local.x - size - 26 }
        if o.y < 24 { o.y = local.y + 26 }
        loupe.frame.origin = o
        loupeText.string = "\(px), \(py)"
        loupeText.frame = CGRect(x: o.x + size / 2 - 42, y: o.y - 20, width: 84, height: 16)
    }

    private func updateHint(visible: Bool) {
        hintBG.isHidden = !visible
        guard visible else { return }
        let prefix = overlay.purpose == .recording ? "Aufnahme  ·  " : ""
        let text = overlay.windowMode
            ? prefix + "Fenster anklicken  ·  Leertaste: Bereich  ·  ⏎ ganzer Bildschirm  ·  Esc: Abbrechen"
            : prefix + "Bereich ziehen  ·  Leertaste: Fenster  ·  ⏎ ganzer Bildschirm  ·  Esc: Abbrechen"
        setLabel(hintText, bg: hintBG, text: text, padX: 14, height: 30)
        let menuBar = frozen.screen.frame.maxY - frozen.screen.visibleFrame.maxY
        hintBG.frame.origin = CGPoint(x: (bounds.width - hintBG.bounds.width) / 2, y: bounds.height - menuBar - hintBG.bounds.height - 18)
    }

    private func setLabel(_ text: CATextLayer, bg: CALayer, text string: String, padX: CGFloat = 9, height: CGFloat = 24) {
        let font = (text.font as? NSFont) ?? NSFont.systemFont(ofSize: text.fontSize)
        let width = (string as NSString).size(withAttributes: [.font: NSFont(descriptor: font.fontDescriptor, size: text.fontSize) ?? font]).width
        text.string = string
        bg.bounds = CGRect(x: 0, y: 0, width: ceil(width) + 2 * padX, height: height)
        bg.cornerRadius = height / 2
        let lineHeight = text.fontSize * 1.25
        text.frame = CGRect(x: 0, y: (height - lineHeight) / 2, width: bg.bounds.width, height: lineHeight)
    }
}
