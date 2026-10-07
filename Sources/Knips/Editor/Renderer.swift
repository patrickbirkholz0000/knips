import AppKit
import CoreImage

/// Vollbild-Effektbilder (verpixelt, unscharf) — Zensurflächen zeigen davon nur ihren Ausschnitt.
final class EffectsCache {
    let base: CGImage
    let scale: CGFloat
    private var cache: [RedactStyle: CGImage] = [:]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init(base: CGImage, scale: CGFloat) {
        self.base = base
        self.scale = scale
    }

    /// Blockgröße: 12 pt — bei normaler UI-Schrift ist eine Zeile damit höchstens zwei Blöcke hoch.
    var pixelBlock: CGFloat { max(10, (12 * scale).rounded()) }

    func image(for style: RedactStyle) -> CGImage? {
        if style == .solid { return nil }
        if let cached = cache[style] { return cached }
        let input = CIImage(cgImage: base)
        let extent = input.extent
        let output: CIImage
        switch style {
        case .pixelate:
            output = input.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: pixelBlock, kCIInputCenterKey: CIVector(x: 0, y: 0)])
                .cropped(to: extent)
        case .blur:
            output = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14 * scale])
                .cropped(to: extent)
        case .solid:
            return nil
        }
        let space = Renderer.rgbSpace(base.colorSpace)
        let image = Self.context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: space)
        cache[style] = image
        return image
    }
}

enum Renderer {
    static func rgbSpace(_ space: CGColorSpace?) -> CGColorSpace {
        if let space, space.model == .rgb, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Endgültiges Bild: Original + Anmerkungen, auf den Zuschnitt begrenzt.
    static func render(base: CGImage, document: ImageDocument, scale: CGFloat, effects: EffectsCache) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let crop = (document.crop ?? full).integral.intersection(full)
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        let w = Int(crop.width), h = Int(crop.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: rgbSpace(base.colorSpace),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawImage(base, in: full, ctx: ctx)
        drawAll(document.annotations, ctx: ctx, scale: scale, effects: effects, hiding: nil)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Zensur zuerst (sie verdeckt Bildinhalt, nicht andere Markierungen), danach alles andere in Reihenfolge.
    static func drawAll(_ annotations: [Annotation], ctx: CGContext, scale: CGFloat, effects: EffectsCache?, hiding: UUID?) {
        for a in annotations where a.kind == .redact && a.id != hiding { draw(a, ctx: ctx, scale: scale, effects: effects) }
        for a in annotations where a.kind != .redact && a.id != hiding { draw(a, ctx: ctx, scale: scale, effects: effects) }
    }

    /// Zeichnet ein CGImage in einen gespiegelten Kontext (Ursprung oben links) aufrecht.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func draw(_ a: Annotation, ctx: CGContext, scale: CGFloat, effects: EffectsCache?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let lw = a.lineWidth(scale: scale)
        switch a.kind {
        case .redact:
            let r = a.rect.integral
            guard r.width > 0, r.height > 0 else { return }
            ctx.clip(to: r)
            if a.redactStyle != .solid, let effects, let fx = effects.image(for: a.redactStyle) {
                drawImage(fx, in: CGRect(x: 0, y: 0, width: fx.width, height: fx.height), ctx: ctx)
            } else {
                ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
                ctx.fill(r)
            }
        case .highlight:
            var c = a.color
            c.a = 0.38
            ctx.setFillColor(c.cgColor)
            ctx.fill(a.rect)
        case .rectangle, .ellipse:
            applyShadow(ctx, scale: scale)
            let r = a.rect
            let path = a.kind == .rectangle
                ? CGPath(roundedRect: r, cornerWidth: min(lw, r.width / 2), cornerHeight: min(lw, r.height / 2), transform: nil)
                : CGPath(ellipseIn: r, transform: nil)
            ctx.addPath(path)
            if a.filled {
                ctx.setFillColor(a.color.cgColor)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(a.color.cgColor)
                ctx.setLineWidth(lw)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }
        case .line:
            applyShadow(ctx, scale: scale)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .arrow:
            applyShadow(ctx, scale: scale)
            guard let path = arrowPath(from: a.start, to: a.end, width: lw) else { return }
            ctx.addPath(path)
            ctx.setFillColor(a.color.cgColor)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(lw * 0.35)
            ctx.setLineJoin(.round)
            ctx.drawPath(using: .fillStroke)
        case .counter:
            applyShadow(ctx, scale: scale)
            let r = a.counterRadius(scale: scale)
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(a.color.cgColor)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(max(1.5, 2 * scale))
            ctx.strokeEllipse(in: circle.insetBy(dx: scale, dy: scale))
            let fg: NSColor = a.color.luminance > 0.7 ? .black : .white
            let str = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
                .foregroundColor: fg,
            ])
            let size = str.size()
            str.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2))
        case .text:
            guard !a.text.isEmpty else { return }
            let halo = NSAttributedString(string: a.text, attributes: textAttributes(for: a, scale: scale, halo: true))
            halo.draw(at: a.start)
            NSAttributedString(string: a.text, attributes: textAttributes(for: a, scale: scale, halo: false)).draw(at: a.start)
        }
    }

    static func textAttributes(for a: Annotation, scale: CGFloat, halo: Bool) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: a.fontSize(scale: scale), weight: .bold),
            .foregroundColor: a.color.nsColor,
        ]
        if halo {
            let haloColor: NSColor = a.color.luminance > 0.75 ? NSColor(white: 0.08, alpha: 0.9) : NSColor(white: 1, alpha: 0.95)
            attrs[.strokeColor] = haloColor
            attrs[.strokeWidth] = 22
            attrs[.foregroundColor] = haloColor
        }
        return attrs
    }

    static func textRect(for a: Annotation, scale: CGFloat) -> CGRect {
        let text = a.text.isEmpty ? " " : a.text
        let size = NSAttributedString(string: text, attributes: textAttributes(for: a, scale: scale, halo: false)).size()
        return CGRect(origin: a.start, size: size)
    }

    /// Bounding-Box für Treffer und Auswahlrahmen.
    static func bounds(of a: Annotation, scale: CGFloat) -> CGRect {
        switch a.kind {
        case .text: return textRect(for: a, scale: scale)
        case .counter:
            let r = a.counterRadius(scale: scale)
            return CGRect(x: a.start.x - r, y: a.start.y - r, width: 2 * r, height: 2 * r)
        case .arrow, .line:
            let lw = a.lineWidth(scale: scale)
            return a.rect.insetBy(dx: -lw * 2, dy: -lw * 2)
        default: return a.rect
        }
    }

    /// Spitz zulaufender Pfeil: schmaler Schaft, breiter Kopf.
    static func arrowPath(from start: CGPoint, to end: CGPoint, width w: CGFloat) -> CGPath? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let headLength = min(max(w * 4.2, 14), length * 0.7)
        let headHalf = max(w * 2.1, headLength * 0.48)
        let tailHalf = w * 0.22
        let shaftHalf = w * 0.62
        func p(_ along: CGFloat, _ across: CGFloat, from o: CGPoint) -> CGPoint {
            CGPoint(x: o.x + ux * along + nx * across, y: o.y + uy * along + ny * across)
        }
        let baseAlong = length - headLength * 0.82
        let path = CGMutablePath()
        path.move(to: p(0, tailHalf, from: start))
        path.addLine(to: p(baseAlong, shaftHalf, from: start))
        path.addLine(to: p(length - headLength, headHalf, from: start))
        path.addLine(to: end)
        path.addLine(to: p(length - headLength, -headHalf, from: start))
        path.addLine(to: p(baseAlong, -shaftHalf, from: start))
        path.addLine(to: p(0, -tailHalf, from: start))
        path.closeSubpath()
        return path
    }

    private static func applyShadow(_ ctx: CGContext, scale: CGFloat) {
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * scale), blur: 3 * scale, color: CGColor(gray: 0, alpha: 0.35))
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
