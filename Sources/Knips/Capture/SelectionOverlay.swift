import AppKit
import QuartzCore

enum SelectionPurpose { case screenshot, recording, text, scroll }

enum SelectionResult {
    /// Rechteck in Punkten relativ zum Bildschirm, Ursprung unten links.
    case area(NSScreen, CGRect)
    case window(WindowInfo, NSScreen)
    case fullScreen(NSScreen)
    case cancelled
}

/// Vollbild-Overlay je Bildschirm. Erscheint sofort über dem laufenden Bildschirm; das Standbild
/// wird darunter im Hintergrund aufgenommen und nachgereicht (`setFrozen`).
/// Ziehen = Bereich, Leertaste = Fenstermodus, ⏎ = ganzer Bildschirm, Esc = Abbruch.
/// Per knips://-Link geöffnet (`armDelay` > 0) gelten ⏎ und Klicks erst nach der Schutzzeit — ein Tastendruck oder
/// Klick, der gerade für eine andere App gedacht war, als das Overlay erschien, nimmt so nichts auf.
@MainActor final class SelectionOverlay {
    let purpose: SelectionPurpose
    let windowInfos: [WindowInfo]
    private let screens: [NSScreen]
    private var windows: [OverlayPanel] = []
    private var views: [SelectionView] = []
    private var completion: ((SelectionResult) -> Void)?
    private var keyMonitor: Any?
    private(set) var mouse: CGPoint = NSEvent.mouseLocation
    var windowMode: Bool { didSet { refreshAll() } }
    var isDragging = false
    /// Nimmt ⏎ und Klicks an (sofort, außer per Link geöffnet).
    private(set) var armed: Bool

    init(screens: [NSScreen], windows: [WindowInfo], purpose: SelectionPurpose, windowMode: Bool,
         armDelay: TimeInterval = 0, completion: @escaping (SelectionResult) -> Void) {
        self.screens = screens
        self.windowInfos = windows
        self.purpose = purpose
        self.windowMode = windowMode
        self.completion = completion
        armed = armDelay <= 0
        if !armed {
            DispatchQueue.main.asyncAfter(deadline: .now() + armDelay) { [weak self] in self?.armed = true }
        }
    }

    func present() {
        for screen in screens {
            // Nicht-aktivierendes Panel: die App, in der gearbeitet wird, bleibt aktiv — ihre Fenster
            // erscheinen im Screenshot nicht grau, und danach muss kein Fokus zurückgegeben werden.
            let window = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = false
            window.acceptsMouseMovedEvents = true
            window.animationBehavior = .none
            window.appearance = Brand.Dark.appearance
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = SelectionView(screen: screen, overlay: self)
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            window.contentView = view
            windows.append(window)
            views.append(view)
        }
        for w in windows { w.orderFrontRegardless() }
        let target = zip(windows, screens).first { NSMouseInRect(mouse, $0.1.frame, false) }?.0 ?? windows.first
        target?.makeKey()
        if let target, let view = target.contentView { target.makeFirstResponder(view) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event.keyCode) ? nil : event
        }
        NSCursor.crosshair.set()
        refreshAll()
    }

    /// Standbilder nachreichen, sobald die Aufnahme im Hintergrund fertig ist.
    func setFrozen(_ frozen: [FrozenScreen]) {
        for view in views {
            if let f = frozen.first(where: { $0.screen == view.screen }) { view.setImage(f.image) }
        }
        refreshAll()
    }

    var isActive: Bool { completion != nil }

    private func handleKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 53: finish(.cancelled); return true
        case 49:
            if !isDragging { windowMode.toggle() }
            return true
        case 36, 76:
            guard armed else { return true }
            if let screen = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? screens.first {
                finish(.fullScreen(screen))
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

    #if KNIPS_DEV
    /// Nur für Selbsttests: Taste ohne Ereignis-Monitor.
    func debugKey(_ keyCode: UInt16) -> Bool { handleKey(keyCode) }
    #endif

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
        // Overlay sofort vom Bildschirm nehmen, bevor irgendetwas anderes passiert.
        CATransaction.flush()
        completion(result)
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionView: NSView {
    let screen: NSScreen
    private(set) var image: CGImage?
    private unowned let overlay: SelectionOverlay
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var tracking: NSTrackingArea?

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    /// Eckgriffe der Auswahl: vier kräftige L-Ecken wie im Zeichen.
    private let handleLayer = CAShapeLayer()
    private let crossH = CALayer()
    private let crossV = CALayer()
    private let sizeBG = CALayer()
    private let sizeText = CATextLayer()
    /// Hinweiszeile unten: fertig gezeichnete dunkle Pille mit Tastenkappen (`HintPill`).
    private let hintBG = CALayer()
    private var hintKey: String?
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeCenter = CALayer()
    private let loupeText = CATextLayer()

    private static let loupeSize: CGFloat = 132
    private static let loupePixels = 13

    init(screen: NSScreen, overlay: SelectionOverlay, image: CGImage? = nil) {
        self.screen = screen
        self.image = image
        self.overlay = overlay
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Pixel pro Punkt des Standbilds.
    private var scale: CGFloat { image.map { CGFloat($0.width) / screen.frame.width } ?? screen.backingScaleFactor }

    func setImage(_ image: CGImage) {
        self.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    private func setupLayers() {
        guard let root = layer else { return }
        let scale = screen.backingScaleFactor
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        root.addSublayer(imageLayer)

        // Darstellung nach docs/design.md („Auswahl-Overlay“): abgedunkelt, Auswahl in Königsblau hell mit Eckgriffen,
        // Größe und Hinweise als dunkle Pillen, Zahlen in Mono.
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = Brand.Dark.fill.withAlphaComponent(0.4).cgColor
        root.addSublayer(dimLayer)

        // Fenstermodus: Königsblau-Fläche 12 % und Rand in Königsblau hell.
        highlightLayer.fillColor = Brand.Dark.royal.withAlphaComponent(0.12).cgColor
        highlightLayer.strokeColor = Brand.Dark.accent.cgColor
        highlightLayer.lineWidth = 2
        highlightLayer.shadowColor = NSColor.black.cgColor
        highlightLayer.shadowOpacity = 0.35
        highlightLayer.shadowRadius = 1.5
        highlightLayer.shadowOffset = .zero
        root.addSublayer(highlightLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = Brand.Dark.accent.cgColor
        borderLayer.lineWidth = 1.5
        handleLayer.fillColor = nil
        handleLayer.strokeColor = Brand.Dark.accent.cgColor
        handleLayer.lineWidth = 4
        handleLayer.lineCap = .round
        handleLayer.lineJoin = .round
        for l in [borderLayer, handleLayer] {
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.45
            l.shadowRadius = 1.5
            l.shadowOffset = .zero
            root.addSublayer(l)
        }

        for l in [crossH, crossV] {
            l.backgroundColor = Brand.Dark.ink.withAlphaComponent(0.55).cgColor
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.5
            l.shadowRadius = 0.5
            l.shadowOffset = .zero
            root.addSublayer(l)
        }

        sizeBG.backgroundColor = Brand.Dark.fill.cgColor
        sizeBG.borderColor = Brand.Dark.line.cgColor
        sizeBG.borderWidth = 1
        sizeBG.shadowColor = NSColor.black.cgColor
        sizeBG.shadowOpacity = 0.3
        sizeBG.shadowRadius = 6
        sizeBG.shadowOffset = CGSize(width: 0, height: -2)
        sizeText.contentsScale = scale
        sizeText.foregroundColor = Brand.Dark.ink.cgColor
        sizeText.alignmentMode = .center
        sizeText.font = Brand.nsMono(12, .medium)
        sizeText.fontSize = 12
        sizeBG.addSublayer(sizeText)
        root.addSublayer(sizeBG)

        hintBG.contentsScale = scale
        hintBG.contentsGravity = .resize
        hintBG.shadowColor = NSColor.black.cgColor
        hintBG.shadowOpacity = 0.35
        hintBG.shadowRadius = 10
        hintBG.shadowOffset = CGSize(width: 0, height: -4)
        root.addSublayer(hintBG)

        loupe.frame = CGRect(x: 0, y: 0, width: Self.loupeSize, height: Self.loupeSize)
        loupe.cornerRadius = Self.loupeSize / 2
        loupe.masksToBounds = true
        // Dunkler Ring außen, feine helle Linie innen: auf hellem wie dunklem Inhalt sichtbar.
        loupe.borderColor = Brand.Dark.fill.cgColor
        loupe.borderWidth = 3
        loupe.backgroundColor = Brand.Dark.fill.cgColor
        loupeImage.frame = loupe.bounds
        loupeImage.magnificationFilter = .nearest
        loupeImage.contentsGravity = .resize
        loupe.addSublayer(loupeImage)
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: loupe.bounds.insetBy(dx: 3.5, dy: 3.5), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = Brand.Dark.ink.withAlphaComponent(0.55).cgColor
        ring.lineWidth = 1
        loupe.addSublayer(ring)
        let cell = Self.loupeSize / CGFloat(Self.loupePixels)
        loupeCenter.frame = CGRect(x: (Self.loupeSize - cell) / 2, y: (Self.loupeSize - cell) / 2, width: cell, height: cell)
        loupeCenter.borderColor = Brand.Dark.accent.cgColor
        loupeCenter.borderWidth = 1.5
        loupe.addSublayer(loupeCenter)
        root.addSublayer(loupe)
        loupeText.contentsScale = scale
        loupeText.font = Brand.nsMono(10.5, .medium)
        loupeText.fontSize = 10.5
        loupeText.foregroundColor = Brand.Dark.ink.cgColor
        loupeText.backgroundColor = Brand.Dark.fill.cgColor
        loupeText.cornerRadius = 8
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
        guard overlay.armed else { return }
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
        // Nur Klicks, die auf dem Overlay begonnen haben (per Link erst nach der Schutzzeit).
        guard dragStart != nil else { return }
        defer { dragStart = nil }
        if let r = selection, r.width >= 4, r.height >= 4 {
            overlay.finish(.area(screen, r.integral))
            return
        }
        selection = nil
        if overlay.windowMode, let w = overlay.hoveredWindow() {
            overlay.finish(.window(w, screen))
            return
        }
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) { overlay.finish(.cancelled) }

    #if KNIPS_DEV
    /// Nur für Selbsttests.
    func debugSelect(_ r: CGRect) { selection = r }
    #endif

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(p.x, bounds.width)), y: max(0, min(p.y, bounds.height)))
    }

    // MARK: Darstellung

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let screenFrame = screen.frame
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
            let outline = selection.insetBy(dx: -0.75, dy: -0.75)
            borderLayer.path = CGPath(rect: outline, transform: nil)
            borderLayer.isHidden = false
            handleLayer.path = AreaFrame.cornerPath(in: outline, arm: min(16, outline.width / 2.5, outline.height / 2.5))
            handleLayer.isHidden = false
            let s = scale
            setLabel(sizeText, bg: sizeBG, text: "\(Int((selection.width * s).rounded())) × \(Int((selection.height * s).rounded()))")
            var origin = CGPoint(x: selection.maxX - sizeBG.bounds.width, y: selection.minY - sizeBG.bounds.height - 10)
            if origin.y < 4 { origin.y = selection.minY + 10 }
            origin.x = max(4, min(origin.x, bounds.width - sizeBG.bounds.width - 4))
            sizeBG.frame.origin = origin
            sizeBG.isHidden = false
        } else {
            borderLayer.isHidden = true
            handleLayer.isHidden = true
            sizeBG.isHidden = true
        }

        let showCross = mouseInside && !overlay.windowMode && !dragging
        crossH.isHidden = !showCross
        crossV.isHidden = !showCross
        if showCross {
            crossH.frame = CGRect(x: 0, y: local.y.rounded() - 0.5, width: bounds.width, height: 1)
            crossV.frame = CGRect(x: local.x.rounded() - 0.5, y: 0, width: 1, height: bounds.height)
        }

        updateLoupe(local: local, visible: mouseInside && !overlay.windowMode && image != nil)
        updateHint(visible: mouseInside && !dragging)
    }

    private func updateLoupe(local: CGPoint, visible: Bool) {
        loupe.isHidden = !visible
        loupeText.isHidden = !visible
        guard visible, let image else { return }
        let s = scale
        let px = Int(local.x * s), py = Int((bounds.height - local.y) * s)
        let half = Self.loupePixels / 2
        let region = CGRect(x: px - half, y: py - half, width: Self.loupePixels, height: Self.loupePixels)
        let clipped = region.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !clipped.isNull, let crop = image.cropping(to: clipped) {
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

    /// Hinweiszeile unten als dunkle Pille: was die Maus tut, dann die Tasten als Mono-Tastenkappen.
    private func updateHint(visible: Bool) {
        hintBG.isHidden = !visible
        guard visible else { return }
        let parts = HintPill.parts(purpose: overlay.purpose, windowMode: overlay.windowMode)
        let scale = screen.backingScaleFactor
        let key = "\(parts)|\(scale)"
        if key != hintKey, let pill = HintPill.render(parts, scale: scale) {
            hintKey = key
            hintBG.contents = pill.image
            hintBG.bounds = CGRect(origin: .zero, size: pill.size)
        }
        // Über dem Dock bzw. dem unteren Bildschirmrand.
        let bottomInset = screen.visibleFrame.minY - screen.frame.minY
        hintBG.frame.origin = CGPoint(x: ((bounds.width - hintBG.bounds.width) / 2).rounded(), y: bottomInset + 28)
    }

    private func setLabel(_ text: CATextLayer, bg: CALayer, text string: String, padX: CGFloat = 9, height: CGFloat = 24) {
        let font = (text.font as? NSFont) ?? NSFont.systemFont(ofSize: text.fontSize)
        let width = (string as NSString).size(withAttributes: [.font: NSFont(descriptor: font.fontDescriptor, size: text.fontSize) ?? font]).width
        text.string = string
        bg.bounds = CGRect(x: 0, y: 0, width: ceil(width) + 2 * padX, height: height)
        bg.cornerRadius = height / 2
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        text.frame = CGRect(x: 0, y: ((height - lineHeight) / 2).rounded(), width: bg.bounds.width, height: lineHeight)
    }
}

/// Hinweiszeile des Auswahl-Overlays als fertiges Bild (eine Ebene, kein Layout pro Mausbewegung).
enum HintPill {
    enum Part: CustomStringConvertible {
        /// Art der Aufnahme als Mono-Versalien (`VIDEO`).
        case overline(String)
        /// Was die Maus tut.
        case lead(String)
        /// Taste und was sie tut.
        case key(String, String)

        var description: String {
            switch self {
            case .overline(let s): "o:\(s)"
            case .lead(let s): "l:\(s)"
            case .key(let k, let s): "k:\(k)=\(s)"
            }
        }
    }

    static func parts(purpose: SelectionPurpose, windowMode: Bool) -> [Part] {
        var parts: [Part] = []
        switch purpose {
        case .recording: parts.append(.overline("Video"))
        case .text: parts.append(.overline("Text erfassen"))
        case .scroll: parts.append(.overline("Scroll-Screenshot"))
        case .screenshot: break
        }
        if windowMode {
            parts += [.lead("Fenster anklicken"), .key("Leertaste", "Bereich")]
        } else {
            parts += [.lead(purpose == .scroll ? "Sichtbaren Bereich ziehen" : "Bereich ziehen"), .key("Leertaste", "Fenster"),
                      .key("⇧", "Quadrat")]
        }
        parts += [.key("⏎", "Bildschirm"), .key("Esc", "Abbrechen")]
        return parts
    }

    static let height: CGFloat = 38

    /// Zeichnet die Pille in Punkten × `scale`.
    static func render(_ parts: [Part], scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let lead: [NSAttributedString.Key: Any] = [.font: Brand.nsFont(13, .medium), .foregroundColor: Brand.Dark.ink]
        let soft: [NSAttributedString.Key: Any] = [.font: Brand.nsFont(13), .foregroundColor: Brand.Dark.muted]
        let over: [NSAttributedString.Key: Any] = [.font: Brand.nsMono(10.5, .medium), .foregroundColor: Brand.Dark.accent,
                                                    .kern: Brand.overlineTracking]
        let cap: [NSAttributedString.Key: Any] = [.font: Brand.nsMono(11, .medium),
                                                   .foregroundColor: Brand.Dark.ink.withAlphaComponent(0.88)]
        let capHeight: CGFloat = 21, capPad: CGFloat = 6, keyGap: CGFloat = 6, groupGap: CGFloat = 16, pad: CGFloat = 16

        // Erst messen: Elemente mit Breite und Zeichenbefehl.
        typealias Item = (width: CGFloat, draw: (CGFloat) -> Void)
        var items: [Item] = []
        func text(_ s: String, _ attrs: [NSAttributedString.Key: Any]) -> Item {
            let a = NSAttributedString(string: s, attributes: attrs)
            let size = a.size()
            return (ceil(size.width), { x in a.draw(at: NSPoint(x: x, y: ((height - size.height) / 2).rounded())) })
        }
        func divider() -> Item {
            (1, { x in
                Brand.Dark.line.setFill()
                NSRect(x: x, y: (height - 16) / 2, width: 1, height: 16).fill()
            })
        }
        for (i, part) in parts.enumerated() {
            if i > 0 { items.append((groupGap, { _ in })) }
            switch part {
            case .overline(let s):
                items.append(text(s.uppercased(), over))
                items.append((groupGap, { _ in }))
                items.append(divider())
            case .lead(let s):
                items.append(text(s, lead))
            case .key(let k, let s):
                var attrs = cap
                if KeySymbols.isSymbol(k) { attrs[.font] = NSFont.systemFont(ofSize: 12, weight: .medium) }
                let label = NSAttributedString(string: k, attributes: attrs)
                let ls = label.size()
                let w = max(capHeight, ceil(ls.width) + 2 * capPad)
                items.append((w, { x in
                    let r = NSRect(x: x + 0.5, y: (height - capHeight) / 2 + 0.5, width: w - 1, height: capHeight - 1)
                    let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
                    Brand.Dark.raised.setFill()
                    path.fill()
                    Brand.Dark.line.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                    label.draw(at: NSPoint(x: x + (w - ls.width) / 2, y: ((height - ls.height) / 2).rounded()))
                }))
                items.append((keyGap, { _ in }))
                items.append(text(s, soft))
            }
        }
        let width = ceil(items.reduce(2 * pad) { $0 + $1.width })
        let size = CGSize(width: width, height: height)
        guard let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let pill = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                                xRadius: height / 2 - 0.5, yRadius: height / 2 - 0.5)
        Brand.Dark.fill.setFill()
        pill.fill()
        Brand.Dark.line.setStroke()
        pill.lineWidth = 1
        pill.stroke()
        var x = pad
        for item in items {
            item.draw(x)
            x += item.width
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return nil }
        return (image, size)
    }
}
