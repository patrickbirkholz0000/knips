import AppKit
import Combine

/// Zeichenfläche des Bild-Editors. Bildkoordinaten = Pixel des Originals, Ursprung oben links;
/// die View ist gespiegelt, damit Bild- und View-Achsen in dieselbe Richtung zeigen.
final class CanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let model: EditorModel
    private var cancellables: Set<AnyCancellable> = []

    private enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end }

    private enum Drag {
        case none
        case create(UUID)
        case move(UUID, last: CGPoint, moved: Bool)
        case resize(UUID, Handle, anchor: CGPoint)
        case cropNew(origin: CGPoint)
        case cropMove(last: CGPoint)
        case cropResize(Handle, original: CGRect)
    }

    private var drag: Drag = .none
    private var editingID: UUID?
    private var textField: NSTextField?
    private var trackingArea: NSTrackingArea?
    static let background = NSColor(srgbRed: 0.105, green: 0.105, blue: 0.115, alpha: 1)

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Seit macOS 14 clippen Views nicht mehr von selbst — sonst übermalt die Fläche die Werkzeugleiste.
        clipsToBounds = true
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.needsDisplay = true
                self?.window?.invalidateCursorRects(for: self!)
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometrie

    private var viewport: CGRect { model.tool == .crop ? model.fullRect : (model.crop ?? model.fullRect) }

    private var fitScale: CGFloat {
        let vp = viewport
        let pad: CGFloat = 32
        let s = min((bounds.width - 2 * pad) / vp.width, (bounds.height - 2 * pad) / vp.height)
        // Höchstens 1:1 in Punkten — ein Retina-Screenshot erscheint so groß wie auf dem Bildschirm.
        return max(0.02, min(s, 1 / model.scale))
    }

    private var origin: CGPoint {
        let vp = viewport, s = fitScale
        return CGPoint(x: ((bounds.width - vp.width * s) / 2).rounded(), y: ((bounds.height - vp.height * s) / 2).rounded())
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let s = fitScale, o = origin, vp = viewport
        return CGPoint(x: (p.x - o.x) / s + vp.minX, y: (p.y - o.y) / s + vp.minY)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let s = fitScale, o = origin, vp = viewport
        return CGPoint(x: (p.x - vp.minX) * s + o.x, y: (p.y - vp.minY) * s + o.y)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let a = toView(r.origin), s = fitScale
        return CGRect(x: a.x, y: a.y, width: r.width * s, height: r.height * s)
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Self.background.setFill()
        bounds.intersection(dirtyRect).fill()

        let vp = viewport, s = fitScale
        let imageRect = toView(vp)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(imageRect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: imageRect)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -vp.minX, y: -vp.minY)
        ctx.interpolationQuality = s < 1 ? .high : .none
        Renderer.drawImage(model.base, in: model.fullRect, ctx: ctx)
        Renderer.drawAll(model.annotations, ctx: ctx, scale: model.scale, effects: model.effects, hiding: editingID)
        ctx.restoreGState()

        if model.tool == .crop {
            drawCropOverlay(ctx, imageRect: imageRect)
        } else if let sel = model.selected, editingID == nil {
            drawSelection(sel, ctx: ctx)
        }
    }

    private func drawSelection(_ a: Annotation, ctx: CGContext) {
        let box = toView(Renderer.bounds(of: a, scale: model.scale)).insetBy(dx: -4, dy: -4)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        if !a.isLineLike { ctx.stroke(box) }
        ctx.restoreGState()
        for (_, p) in handles(for: a) { drawHandle(at: p, ctx: ctx) }
    }

    private func drawHandle(at p: CGPoint, ctx: CGContext) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.fillEllipse(in: r)
        ctx.strokeEllipse(in: r)
    }

    private func drawCropOverlay(_ ctx: CGContext, imageRect: CGRect) {
        guard let draft = model.cropDraft else { return }
        let r = toView(draft)
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(imageRect)
        path.addRect(r)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(r)
        // Drittel-Raster
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
        for (_, p) in cropHandles(r) {
            let h = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(h)
        }
        let label = "\(Int(draft.width)) × \(Int(draft.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let bg = CGRect(x: r.midX - size.width / 2 - 8, y: max(4, r.minY - size.height - 12), width: size.width + 16, height: size.height + 6)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: bg.height / 2, cornerHeight: bg.height / 2, transform: nil))
        ctx.fillPath()
        label.draw(at: CGPoint(x: bg.minX + 8, y: bg.minY + 3), withAttributes: attrs)
    }

    // MARK: Griffe

    private func handles(for a: Annotation) -> [(Handle, CGPoint)] {
        if a.isLineLike { return [(.start, toView(a.start)), (.end, toView(a.end))] }
        guard a.isRectLike else { return [] }
        let r = toView(a.rect)
        return [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
    }

    private func cropHandles(_ r: CGRect) -> [(Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
         (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    private func handleHit(_ viewPoint: CGPoint, in list: [(Handle, CGPoint)]) -> Handle? {
        list.first { hypot($0.1.x - viewPoint.x, $0.1.y - viewPoint.y) <= 8 }?.0
    }

    /// Oberste Anmerkung unter dem Punkt (Bildkoordinaten).
    private func annotation(at p: CGPoint) -> Annotation? {
        let tolerance = 6 / fitScale
        let ordered = model.annotations.filter { $0.kind != .redact } + model.annotations.filter { $0.kind == .redact }
        for a in ordered.reversed() {
            switch a.kind {
            case .arrow, .line:
                if Renderer.distance(from: p, toSegment: a.start, a.end) <= max(tolerance, a.lineWidth(scale: model.scale)) { return a }
            case .rectangle, .ellipse:
                let r = a.rect
                if a.filled {
                    if r.insetBy(dx: -tolerance, dy: -tolerance).contains(p) { return a }
                } else {
                    let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
                    let inner = r.insetBy(dx: tolerance + a.lineWidth(scale: model.scale), dy: tolerance + a.lineWidth(scale: model.scale))
                    if outer.contains(p) && !inner.contains(p) { return a }
                }
            default:
                if Renderer.bounds(of: a, scale: model.scale).insetBy(dx: -tolerance, dy: -tolerance).contains(p) { return a }
            }
        }
        return nil
    }

    // MARK: Maus

    override func mouseDown(with event: NSEvent) {
        if editingID != nil { endTextEditing() }
        window?.makeFirstResponder(self)
        let vp = convert(event.locationInWindow, from: nil)
        let p = toImage(vp)

        if model.tool == .crop {
            beginCropDrag(viewPoint: vp, imagePoint: p)
            return
        }

        if let sel = model.selected, let h = handleHit(vp, in: handles(for: sel)) {
            model.checkpoint()
            let anchor: CGPoint
            switch h {
            case .start: anchor = sel.end
            case .end: anchor = sel.start
            default:
                let r = sel.rect
                switch h {
                case .topLeft: anchor = CGPoint(x: r.maxX, y: r.maxY)
                case .topRight: anchor = CGPoint(x: r.minX, y: r.maxY)
                case .bottomLeft: anchor = CGPoint(x: r.maxX, y: r.minY)
                default: anchor = CGPoint(x: r.minX, y: r.minY)
                }
            }
            drag = .resize(sel.id, h, anchor: anchor)
            return
        }

        let hit = annotation(at: p)
        let grabsExisting = hit != nil && (model.tool == .select || hit?.id == model.selectedID
                                           || (model.tool == .text && hit?.kind == .text))
        if let hit, grabsExisting {
            model.selectedID = hit.id
            if event.clickCount == 2 && hit.kind == .text {
                beginTextEditing(hit.id)
                return
            }
            drag = .move(hit.id, last: p, moved: false)
            return
        }

        model.selectedID = nil
        guard let kind = model.tool.annotationKind else {
            drag = .none
            return
        }
        switch kind {
        case .text:
            model.checkpoint()
            var a = model.makeAnnotation(kind: .text, at: p)
            a.start.y -= a.fontSize(scale: model.scale) * 0.6
            model.annotations.append(a)
            model.selectedID = a.id
            beginTextEditing(a.id)
            drag = .none
        case .counter:
            model.checkpoint()
            let a = model.makeAnnotation(kind: .counter, at: p)
            model.annotations.append(a)
            model.selectedID = a.id
            drag = .move(a.id, last: p, moved: true)
        default:
            model.checkpoint()
            let a = model.makeAnnotation(kind: kind, at: p)
            model.annotations.append(a)
            drag = .create(a.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        var p = toImage(vp)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            break
        case .create(let id):
            guard let a = model.annotations.first(where: { $0.id == id }) else { return }
            if shift { p = constrain(p, from: a.start, lineLike: a.isLineLike) }
            model.update(id) { $0.end = p }
        case .move(let id, let last, _):
            let d = CGVector(dx: p.x - last.x, dy: p.y - last.y)
            if case .move(_, _, false) = drag { model.checkpoint() }
            model.update(id) { $0.offset(by: d) }
            drag = .move(id, last: p, moved: true)
        case .resize(let id, let handle, let anchor):
            if shift {
                let lineLike = handle == .start || handle == .end
                p = constrain(p, from: anchor, lineLike: lineLike)
            }
            model.update(id) { a in
                switch handle {
                case .start: a.start = p
                case .end: a.end = p
                default:
                    a.start = anchor
                    a.end = p
                }
            }
        case .cropNew(let o):
            model.cropDraft = CGRect(x: min(o.x, p.x), y: min(o.y, p.y), width: abs(p.x - o.x), height: abs(p.y - o.y))
                .intersection(model.fullRect)
        case .cropMove(let last):
            guard var r = model.cropDraft else { return }
            r.origin.x += p.x - last.x
            r.origin.y += p.y - last.y
            r.origin.x = max(0, min(r.origin.x, model.fullRect.width - r.width))
            r.origin.y = max(0, min(r.origin.y, model.fullRect.height - r.height))
            model.cropDraft = r
            drag = .cropMove(last: p)
        case .cropResize(let handle, let original):
            var minX = original.minX, minY = original.minY, maxX = original.maxX, maxY = original.maxY
            switch handle {
            case .topLeft: minX = p.x; minY = p.y
            case .top: minY = p.y
            case .topRight: maxX = p.x; minY = p.y
            case .right: maxX = p.x
            case .bottomRight: maxX = p.x; maxY = p.y
            case .bottom: maxY = p.y
            case .bottomLeft: minX = p.x; maxY = p.y
            case .left: minX = p.x
            default: break
            }
            model.cropDraft = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
                .intersection(model.fullRect)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .create(let id):
            if let a = model.annotations.first(where: { $0.id == id }) {
                let viewLength = hypot(a.end.x - a.start.x, a.end.y - a.start.y) * fitScale
                let tooSmall = a.isLineLike ? viewLength < 6 : (a.rect.width * fitScale < 4 || a.rect.height * fitScale < 4)
                if tooSmall {
                    model.remove(id)
                    model.dropCheckpoint()
                } else {
                    model.selectedID = id
                }
            }
        case .move(_, _, let moved):
            if !moved { /* reine Auswahl */ }
        default:
            break
        }
        drag = .none
        needsDisplay = true
    }

    private func beginCropDrag(viewPoint vp: CGPoint, imagePoint p: CGPoint) {
        guard let draft = model.cropDraft else { return }
        let r = toView(draft)
        if let h = handleHit(vp, in: cropHandles(r)) {
            drag = .cropResize(h, original: draft)
        } else if r.contains(vp) {
            drag = .cropMove(last: p)
        } else {
            drag = .cropNew(origin: CGPoint(x: max(0, min(p.x, model.fullRect.maxX)), y: max(0, min(p.y, model.fullRect.maxY))))
        }
    }

    /// Shift: Linien auf 45°-Schritte, Rechtecke quadratisch.
    private func constrain(_ p: CGPoint, from o: CGPoint, lineLike: Bool) -> CGPoint {
        let dx = p.x - o.x, dy = p.y - o.y
        if lineLike {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: o.x + cos(angle) * len, y: o.y + sin(angle) * len)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: o.x + (dx < 0 ? -side : side), y: o.y + (dy < 0 ? -side : side))
    }

    // MARK: Tastatur

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 51, 117: // ⌫ ⌦
            model.deleteSelection()
            return
        case 53: // Esc
            if model.tool == .crop { model.cancelCrop() } else if model.selectedID != nil { model.selectedID = nil } else { window?.performClose(nil) }
            return
        case 36, 76: // Return
            if model.tool == .crop { model.applyCrop(); return }
            if let sel = model.selected, sel.kind == .text { beginTextEditing(sel.id); return }
        case 123, 124, 125, 126: // Pfeiltasten verschieben die Auswahl
            guard let id = model.selectedID else { break }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 * model.scale : model.scale
            let d: CGVector = switch event.keyCode {
            case 123: CGVector(dx: -step, dy: 0)
            case 124: CGVector(dx: step, dy: 0)
            case 125: CGVector(dx: 0, dy: step)
            default: CGVector(dx: 0, dy: -step)
            }
            if !event.isARepeat { model.checkpoint() }
            model.update(id) { $0.offset(by: d) }
            return
        default:
            break
        }
        if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = EditorTool.allCases.first(where: { $0.key == ch }) {
            if tool == .crop { model.startCrop() } else { model.tool = tool }
            return
        }
        super.keyDown(with: event)
    }

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return model.canUndo
        case #selector(redo(_:)): return model.canRedo
        case #selector(delete(_:)): return model.selectedID != nil
        default: return true
        }
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    private func updateCursor(at vp: CGPoint) {
        if model.tool == .crop {
            if let d = model.cropDraft, toView(d).contains(vp) { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
            return
        }
        if let sel = model.selected, handleHit(vp, in: handles(for: sel)) != nil { NSCursor.pointingHand.set(); return }
        let hit = annotation(at: toImage(vp))
        if let hit, model.tool == .select || hit.id == model.selectedID { NSCursor.openHand.set(); return }
        switch model.tool {
        case .select: NSCursor.arrow.set()
        case .text: NSCursor.iBeam.set()
        default: NSCursor.crosshair.set()
        }
    }

    // MARK: Text

    private func beginTextEditing(_ id: UUID) {
        guard let a = model.annotations.first(where: { $0.id == id }) else { return }
        editingID = id
        let field = GrowingTextField(string: a.text)
        field.font = NSFont.systemFont(ofSize: a.fontSize(scale: model.scale) * fitScale, weight: .bold)
        field.textColor = a.color.nsColor
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(white: a.color.luminance > 0.75 ? 0.2 : 1, alpha: 0.9)
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        let origin = toView(a.start)
        field.frame = CGRect(origin: origin, size: .zero)
        field.fit()
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func endTextEditing() {
        guard let id = editingID, let field = textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editingID = nil
        textField = nil
        field.delegate = nil
        field.removeFromSuperview()
        if text.isEmpty {
            model.remove(id)
            model.selectedID = nil
        } else {
            if model.annotations.first(where: { $0.id == id })?.text != text, !(model.annotations.first(where: { $0.id == id })?.text.isEmpty ?? true) {
                model.checkpoint()
            }
            model.update(id) { $0.text = text }
            model.selectedID = id
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) { (textField as? GrowingTextField)?.fit() }
    func controlTextDidEndEditing(_ obj: Notification) { endTextEditing() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        return false
    }

    func commitPendingEdits() { if editingID != nil { endTextEditing() } }
}

private final class GrowingTextField: NSTextField {
    func fit() {
        let text = stringValue.isEmpty ? "Text" : stringValue + " "
        let size = (text as NSString).boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin],
                                                   attributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).size
        setFrameSize(CGSize(width: ceil(size.width) + 12, height: ceil(size.height) + 4))
    }
}
