import AppKit
import SwiftUI

/// Zeichen von Knips (docs/design.md, „Logo und Wortmarke“): vier Auswahl-Ecken (die Auswahl) und ein Balken
/// darin (die Zensur). Geometrie in Einheiten 0…100 — dieselbe wie im App-Icon und in `windows/src/shared/brand.tsx`.
enum BrandGeometry {
    static let frame: ClosedRange<CGFloat> = 22...78
    static let arm: CGFloat = 17
    static let stroke: CGFloat = 9
    static let bar = CGRect(x: 33, y: 45.5, width: 34, height: 9)
    /// Aufnahme-Zustand: Punkt statt Balken (Mittelpunkt 50|50).
    static let dotRadius: CGFloat = 9

    /// Die vier Ecken als offene Pfade (oben links, oben rechts, unten rechts, unten links), y nach unten.
    static func corners(in rect: CGRect) -> Path {
        let s = rect.width / 100
        let lo = frame.lowerBound, hi = frame.upperBound
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        for (corner, dx, dy) in [((lo, lo), 1.0, 1.0), ((hi, lo), -1.0, 1.0), ((hi, hi), -1.0, -1.0), ((lo, hi), 1.0, -1.0)] {
            path.move(to: p(corner.0, corner.1 + dy * arm))
            path.addLine(to: p(corner.0, corner.1))
            path.addLine(to: p(corner.0 + dx * arm, corner.1))
        }
        return path
    }

    static func bar(in rect: CGRect) -> Path {
        let s = rect.width / 100
        let r = CGRect(x: rect.minX + bar.minX * s, y: rect.minY + bar.minY * s, width: bar.width * s, height: bar.height * s)
        return Path(roundedRect: r, cornerRadius: r.height / 2)
    }

    static func dot(in rect: CGRect) -> Path {
        let s = rect.width / 100
        return Path(ellipseIn: CGRect(x: rect.minX + (50 - dotRadius) * s, y: rect.minY + (50 - dotRadius) * s,
                                      width: dotRadius * 2 * s, height: dotRadius * 2 * s))
    }
}

/// Das Zeichen als SwiftUI-Ansicht. `recording`: Punkt statt Balken (Aufnahme-Rot).
struct BrandMark: View {
    var size: CGFloat = 22
    var recording = false
    var ink: Color = .brand(Brand.Side.ink)
    var accent: Color = .brand(Brand.Dark.accent)

    var body: some View {
        Canvas { context, canvas in
            let rect = CGRect(origin: .zero, size: canvas)
            let lineWidth = BrandGeometry.stroke * canvas.width / 100
            context.stroke(BrandGeometry.corners(in: rect), with: .color(ink),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            if recording {
                context.fill(BrandGeometry.dot(in: rect), with: .color(.brand(Brand.Dark.record)))
            } else {
                context.fill(BrandGeometry.bar(in: rect), with: .color(accent))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Wortmarke „knips“ in Kleinbuchstaben, Outfit halbfett. Der i-Punkt ist die Aufnahmelampe: Königsblau in Ruhe,
/// Rot und pulsierend, solange ein Video läuft (wie in der App-Familie).
struct Wordmark: View {
    var size: CGFloat = 20
    var recording = false
    var ink: Color = .brand(Brand.Side.ink)
    var lamp: Color = .brand(Brand.Dark.accent)

    var body: some View {
        let font = Brand.nsFont(size, .semibold)
        // Punkt über dem punktlosen ı: Abstand zur x-Höhe wie beim echten i der Schrift.
        let dot = size * 0.135
        let lift = font.ascender - font.xHeight - size * 0.09 - dot
        HStack(spacing: 0) {
            Text("kn")
            Text("\u{0131}")
                .overlay(alignment: .top) {
                    Group {
                        if recording {
                            // Puls nur auf der Lampe: ein `withAnimation(.repeatForever)` würde Nachbarn mitblenden.
                            Circle().fill(Color.brand(Brand.Dark.record))
                                .phaseAnimator([false, true]) { lampView, dim in lampView.opacity(dim ? 0.35 : 1) }
                                    animation: { _ in .easeInOut(duration: 0.9) }
                        } else {
                            Circle().fill(lamp)
                        }
                    }
                    .frame(width: dot, height: dot)
                    .offset(y: lift)
                }
            Text("ps")
        }
        .font(Font(font as CTFont))
        .foregroundStyle(ink)
        .fixedSize()
        .accessibilityLabel("Knips")
    }
}

extension BrandGeometry {
    /// Zeichen als Vorlage für die Menüleiste (einfarbig, macOS färbt ein). `recording`: Punkt statt Balken.
    static func templateImage(points: CGFloat = 18, recording: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let inset = rect.insetBy(dx: -points * 0.06, dy: -points * 0.06) // Ecken etwas größer als im Icon
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(max(1.5, stroke * inset.width / 100))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(corners(in: inset).cgPath)
            ctx.strokePath()
            ctx.addPath((recording ? dot(in: inset) : bar(in: inset)).cgPath)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? "Knips – Aufnahme läuft" : "Knips"
        return image
    }
}
