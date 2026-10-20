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
/// Rot und pulsierend, solange ein Video läuft.
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
    /// Das Zeichen füllt 14 von 18 pt; Strich 2 pt, Ecken und Balken mit Kanten auf ganzen Punkten — so bleibt es
    /// in @1x und @2x scharf (bei 9 % Strich und freier Lage lägen die Kanten mitten in einem Pixel).
    static func templateImage(points: CGFloat = 18, recording: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let extent = frame.upperBound - frame.lowerBound + stroke   // 65 Einheiten von Außenkante zu Außenkante
            let unit = points * 14 / 18 / extent
            let w = max(1, (stroke * unit).rounded())
            let near = (points / 2 - extent / 2 * unit).rounded() + w / 2  // Mitte der linken/oberen Linie
            let far = points - near
            let arm = (self.arm * unit + w).rounded() - w            // rundes Ende auf einer Punktgrenze
            let path = CGMutablePath()
            for (x, y, dx, dy) in [(near, near, 1.0, 1.0), (far, near, -1.0, 1.0), (far, far, -1.0, -1.0), (near, far, 1.0, -1.0)] {
                path.move(to: CGPoint(x: x, y: y + dy * arm))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + dx * arm, y: y))
            }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(w)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            let mid = points / 2
            if recording {
                // Punkt auf ganze Punkte gerundet (r 9 → 2 pt bei 18 pt), mittig wie der Balken.
                let r = max(1.5, (dotRadius * unit).rounded())
                ctx.fillEllipse(in: CGRect(x: mid - r, y: mid - r, width: 2 * r, height: 2 * r))
            } else {
                let half = mid - (mid - bar.width / 2 * unit).rounded() // Enden auf Punktgrenzen
                let r = CGRect(x: mid - half, y: mid - w / 2, width: 2 * half, height: w)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? "Knips – Aufnahme läuft, Klick stoppt" : "Knips"
        return image
    }
}
