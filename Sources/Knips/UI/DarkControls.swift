import AppKit
import Carbon
import SwiftUI

/// Bausteine für alles, was über anderen Apps schwebt und darum immer dunkel ist (docs/design.md, „Dunkel schwebt“):
/// Menü-Panel, Karten-Knöpfe, Aufnahme-Leiste, Countdown, Scroll-Leiste, Hinweise, Pin-Steuerung.
/// Farben kommen nur aus `Brand.Dark`; abgeleitete Töne (Grün, Warnung, Königsblau-Fläche) sind die dunklen
/// Fassungen der hellen/dunklen Brand-Tokens.

extension Brand.Dark {
    /// „Erledigt“ auf dunklem Grund (dunkle Fassung von `Brand.success`).
    static let success = Brand.success.darkVariant
    /// Hinweis/Warnung auf dunklem Grund (dunkle Fassung von `Brand.warn`).
    static let warn = Brand.warn.darkVariant
    /// Königsblau-Fläche auf dunklem Grund (Icon-Kachel, ausgewählte Fläche).
    static let accentSoft = Brand.Dark.accent.withAlphaComponent(0.14)
    /// Königsblau in voller Stärke (helle Fassung von `Brand.accent`) — Fläche über einem Fenster im Fenstermodus.
    static let royal = Brand.accent.variant(.aqua)
    /// Leichter Glanz an der Oberkante einer Pille (`inset 0 1px 0`).
    static let shine = Brand.Dark.ink.withAlphaComponent(0.07)

    /// Appearance für alle Schwebeflächen — Systemelemente (Tooltips, Fokus, Symbole) passen dann dazu,
    /// egal welche Darstellung (System/Hell/Dunkel) eingestellt ist.
    static var appearance: NSAppearance? { NSAppearance(named: .darkAqua) }
}

extension NSColor {
    /// Die dunkle Fassung einer dynamischen Farbe (fest, unabhängig von der Darstellung).
    var darkVariant: NSColor { variant(.darkAqua) }

    /// Die Fassung einer dynamischen Farbe für eine bestimmte Darstellung.
    func variant(_ name: NSAppearance.Name) -> NSColor {
        var resolved = self
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        return resolved
    }
}

// MARK: - Fläche

extension View {
    /// Dunkle Schwebefläche: Fläche `Brand.Dark.fill`, Linie weiß 8 %, Glanz oben, weicher Schatten.
    func darkSurface<S: InsettableShape>(_ shape: S, fill: NSColor = Brand.Dark.fill, shadow: Bool = true) -> some View {
        background(shape.fill(Color.brand(fill)))
            .overlay(shape.strokeBorder(Color.brand(Brand.Dark.line), lineWidth: 1))
            .overlay(
                shape.inset(by: 1).strokeBorder(
                    LinearGradient(colors: [Color.brand(Brand.Dark.shine), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)),
                    lineWidth: 1)
            )
            .compositingGroup()
            .shadow(color: .black.opacity(shadow ? 0.32 : 0), radius: 14, y: 8)
            .shadow(color: .black.opacity(shadow ? 0.22 : 0), radius: 2.5, y: 1)
    }
}

// MARK: - Knöpfe

/// Pillen-Knopf auf dunklem Grund. `primary` = Papier mit Tinte (Hauptaktion), `raised` = dunkel gehoben,
/// `ghost` = leiser Textknopf.
struct DarkButtonStyle: ButtonStyle {
    enum Kind { case primary, raised, ghost }
    var kind: Kind = .raised
    var height: CGFloat = 28
    var width: CGFloat?
    var fontSize: CGFloat = 12.5

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = switch kind {
        case .primary: .brand(Brand.Dark.button)
        case .raised: .brand(configuration.isPressed ? Brand.Dark.hover : Brand.Dark.raised)
        case .ghost: configuration.isPressed ? .brand(Brand.Dark.hover) : .clear
        }
        let ink: Color = switch kind {
        case .primary: .brand(Brand.Dark.buttonInk)
        case .raised: .brand(Brand.Dark.ink)
        case .ghost: .brand(configuration.isPressed ? Brand.Dark.ink : Brand.Dark.muted)
        }
        return configuration.label
            .font(Brand.font(fontSize, kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(width: width, height: height)
            .foregroundStyle(ink)
            .background(Capsule().fill(fill))
            .overlay(kind == .raised ? Capsule().strokeBorder(Color.brand(Brand.Dark.line)) : nil)
            .opacity(configuration.isPressed && kind == .primary ? 0.86 : 1)
            .contentShape(Capsule())
    }
}

/// Kleiner runder Knopf mit Symbol auf dunklem Grund (Ecken der Karten, Pin-Steuerung, Verwerfen).
struct DarkIconButtonStyle: ButtonStyle {
    var size: CGFloat = 24
    var symbolSize: CGFloat = 11
    /// `true`: eigene dunkle Fläche (auf Bildern); `false`: nur Hover-/Druckfläche (in einer Pille).
    var filled = true
    var tint: NSColor = Brand.Dark.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(Color.brand(tint))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.brand(filled
                ? (configuration.isPressed ? Brand.Dark.hover : Brand.Dark.fill)
                : (configuration.isPressed ? Brand.Dark.hover : Brand.Dark.raised))))
            .overlay(filled ? Circle().strokeBorder(Color.brand(Brand.Dark.line)) : nil)
            .contentShape(Circle())
    }
}

// MARK: - Tastenkappen, Überschriften, Aufnahmepunkt

/// Tastensymbole (⇧ ⌘ ⏎ …): In JetBrains Mono sind sie deutlich kleiner als Ziffern und Buchstaben,
/// deshalb stehen sie in der Systemschrift, etwas größer — so wirken ⇧ ⌘ 4 gleich groß.
enum KeySymbols {
    static let all: Set<Character> = ["⌃", "⌥", "⇧", "⌘", "⏎", "↩", "⎋", "⇥", "⌫", "⌦", "←", "→", "↑", "↓", "↖", "↘", "⇞", "⇟"]

    static func isSymbol(_ s: String) -> Bool { s.count == 1 && s.first.map(all.contains) == true }

    /// Kürzel als Text: Symbole in der Systemschrift, Taste in Mono.
    static func text(_ combo: KeyCombo, size: CGFloat) -> Text {
        combo.capLabels.reduce(Text("")) { result, label in
            result + Text(label).font(isSymbol(label) ? .system(size: size + 0.5, weight: .medium) : Brand.mono(size))
        }
    }
}

/// Tastenkappe in Mono (dunkel gehoben, feine Linie) .
struct KeyCap: View {
    let label: String
    var size: CGFloat = 11

    var body: some View {
        Text(label)
            .font(KeySymbols.isSymbol(label) ? .system(size: size + 1, weight: .medium) : Brand.mono(size, .medium))
            .foregroundStyle(Color.brand(Brand.Dark.ink).opacity(0.86))
            .padding(.horizontal, 5)
            .frame(minWidth: size + 9, minHeight: size + 9)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.brand(Brand.Dark.raised)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.brand(Brand.Dark.line)))
            .fixedSize()
    }
}

/// Kürzel als Reihe von Tastenkappen (⇧ ⌘ 4).
struct KeyCaps: View {
    let combo: KeyCombo
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(combo.capLabels.enumerated()), id: \.offset) { _, label in KeyCap(label: label, size: size) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combo.display)
    }
}

extension KeyCombo {
    /// Einzelne Tasten in der macOS-Reihenfolge: ⌃ ⌥ ⇧ ⌘ Taste.
    var capLabels: [String] {
        var caps: [String] = []
        if modifiers & UInt32(controlKey) != 0 { caps.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { caps.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { caps.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { caps.append("⌘") }
        caps.append(KeyCombo.keyName(keyCode))
        return caps
    }
}

/// Kleine Überschrift in Mono-Versalien (`ZULETZT`).
struct Overline: View {
    let text: String
    var color: NSColor = Brand.Dark.muted

    var body: some View {
        Text(text.uppercased())
            .font(Brand.mono(11, .medium))
            .tracking(Brand.overlineTracking)
            .foregroundStyle(Color.brand(color))
            .lineLimit(1)
            .fixedSize()
    }
}

/// Roter Aufnahmepunkt mit Hof, pulsierend. Rot nur, solange ein Video läuft.
struct RecordDot: View {
    var size: CGFloat = 8
    var pulsing = true

    var body: some View {
        ZStack {
            Circle().fill(Color.brand(Brand.Dark.record).opacity(0.2)).frame(width: size + 6, height: size + 6)
            if pulsing {
                Circle().fill(Color.brand(Brand.Dark.record))
                    .frame(width: size, height: size)
                    .phaseAnimator([false, true]) { dot, dim in dot.opacity(dim ? 0.45 : 1) }
                        animation: { _ in .easeInOut(duration: 0.7) }
            } else {
                Circle().fill(Color.brand(Brand.Dark.record)).frame(width: size, height: size)
            }
        }
        .frame(width: size + 6, height: size + 6)
        .accessibilityHidden(true)
    }
}

/// Statuspunkt mit Hof in beliebiger Brand-Farbe (Grün „Bereit“, Rot „fehlt“).
struct StatusDot: View {
    let color: NSColor
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(Color.brand(color))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.brand(color).opacity(0.2)).frame(width: size + 6, height: size + 6))
            .frame(width: size + 6, height: size + 6)
            .accessibilityHidden(true)
    }
}

// MARK: - Rahmen um einen Aufnahmebereich

/// Rahmen knapp außerhalb eines Bereichs (Video in Aufnahme-Rot, Scroll-Screenshot in Königsblau):
/// feine Linie und kräftige Ecken wie im Zeichen (vier Auswahl-Ecken). Fenster nimmt keine Mausereignisse an.
enum AreaFrame {
    /// Abstand des Rahmens zum Bereich (Knips-Fenster sind ohnehin nicht im Bild).
    static let outset: CGFloat = 4

    static func makeView(size: CGSize, color: NSColor) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.appearance = Brand.Dark.appearance
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
        let line = CAShapeLayer()
        line.path = CGPath(rect: rect, transform: nil)
        line.fillColor = nil
        line.strokeColor = color.withAlphaComponent(0.7).cgColor
        line.lineWidth = 1.5
        let corners = CAShapeLayer()
        corners.path = cornerPath(in: rect, arm: min(18, rect.width / 3, rect.height / 3))
        corners.fillColor = nil
        corners.strokeColor = color.cgColor
        corners.lineWidth = 4
        corners.lineCap = .round
        corners.lineJoin = .round
        for layer in [line, corners] {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 1.5
            layer.shadowOffset = .zero
            view.layer?.addSublayer(layer)
        }
        return view
    }

    /// Vier L-förmige Ecken eines Rechtecks.
    static func cornerPath(in r: CGRect, arm: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return path
    }
}

// MARK: - Schwebendes Panel

/// Panel für Leisten über anderen Apps: randlos, durchsichtig, nimmt keinen Fokus, immer dunkel.
/// Ohne `ignoresMouse` bleibt die Voreinstellung: Klicks auf ganz durchsichtige Stellen (der Rand für den
/// Schatten um die Pille) gehen an die App darunter.
@MainActor enum FloatingPanel {
    static func make(_ rect: NSRect, ignoresMouse: Bool, level: NSWindow.Level = .statusBar) -> NSPanel {
        let p = ClickablePanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = level
        p.hidesOnDeactivate = false
        if ignoresMouse { p.ignoresMouseEvents = true }
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.appearance = Brand.Dark.appearance
        p.setFrame(rect, display: false)
        return p
    }
}
