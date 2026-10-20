import AppKit
import SwiftUI

/// Markensprache der App-Familie — Beschreibung in `docs/design.md`.
/// Tinte auf Papier, Königsblau als einziger Akzent, Rot nur während einer Aufnahme, Grün nur für „erledigt“.
/// Farben passen sich Hell/Dunkel an (`appearance` des Fensters bzw. der App); Pillen, Leisten, Menü und
/// Karten-Knöpfe sind immer dunkel (`Brand.Dark`).
enum Brand {
    // MARK: Farben (hell | dunkel)

    /// Fensterfläche (Papier).
    static let canvas = dynamic(0xF4F5F7, 0x101114)
    /// Spuren, graue Chips, Hover, Segment-Hintergrund.
    static let fill = dynamic(0xECEEF2, 0x22242A)
    /// Karten.
    static let surface = dynamic(0xFFFFFF, 0x18191D)
    /// Erhöhte Kachel in einer Karte.
    static let surfaceRaised = dynamic(0xF8F9FB, 0x1E1F24)
    static let line = dynamic(0xE2E4E9, 0x2A2C32)
    static let lineStrong = dynamic(0xD5D7DE, 0x383A42)
    /// Text (Tinte).
    static let ink = dynamic(0x15161A, 0xECEEF2)
    static let inkMuted = dynamic(0x4A4D55, 0xC3C6CE)
    /// Zweittext (Bleistift).
    static let inkSoft = dynamic(0x6C6F78, 0x979BA5)
    /// Einziger Akzent: Schalter, Auswahl, aktives Werkzeug, Fortschritt, Fokusrahmen.
    static let accent = dynamic(0x2D46D2, 0x8B98FF)
    static let accentSoft = dynamic(0x2D46D2, 0x8B98FF, alpha: (0.09, 0.12))
    static let onAccent = dynamic(0xFFFFFF, 0x15161A)
    /// Nur während einer Aufnahme (und bei fehlenden Schritten im Bereit-Check).
    static let record = dynamic(0xE8523F, 0xFF7A66)
    static let recordSoft = dynamic(0xE8523F, 0xFF7A66, alpha: (0.12, 0.14))
    /// Nur „erledigt“ (Häkchen, „Erlaubt“).
    static let success = dynamic(0x1F8A5B, 0x4CC58E)
    static let successSoft = dynamic(0x1F8A5B, 0x4CC58E, alpha: (0.12, 0.14))
    static let warn = dynamic(0xA8641A, 0xE0A24F)
    /// Primärknopf auf hellen Flächen: Tinte (im Dunkeln Papier) mit Gegenfarbe als Schrift.
    static let buttonFill = dynamic(0x15161A, 0xECEEF2)
    static let buttonInk = dynamic(0xFFFFFF, 0x15161A)
    /// Dünner Daumen im Segment-Schalter.
    static let segmentThumb = dynamic(0xFFFFFF, 0x2A2B31)

    /// Seitenleiste der Einstellungen — immer dunkel.
    enum Side {
        static let fill = rgb(0x1B1C20)
        static let raised = rgb(0x2C2D33)
        static let ink = rgb(0xECEEF2)
        static let muted = rgb(0x9A9EA8)
        static let line = rgb(0xECEEF2, alpha: 0.08)
    }

    /// Immer dunkle Flächen: Menü-Panel, Pillen (Aufnahme, Scrollen, Hinweise), Knöpfe auf den Karten.
    enum Dark {
        static let fill = rgb(0x141518)
        static let raised = rgb(0x24262C)
        static let hover = rgb(0x2E3037)
        static let line = rgb(0xFFFFFF, alpha: 0.08)
        static let ink = rgb(0xECEEF2)
        static let muted = rgb(0x979BA5)
        /// Helles Königsblau auf dunklem Grund (wie das Overlay).
        static let accent = rgb(0x9AA6FF)
        static let record = rgb(0xFF7A66)
        /// Primärknopf auf dunklem Grund: Papier mit Tinte als Schrift.
        static let button = rgb(0xF4F5F7)
        static let buttonInk = rgb(0x15161A)
    }

    // MARK: Formen

    enum Radius {
        static let small: CGFloat = 6
        static let field: CGFloat = 10
        static let button: CGFloat = 10
        static let card: CGFloat = 14
        static let panel: CGFloat = 16
        static let dialog: CGFloat = 22
    }

    // MARK: Schrift

    /// Outfit (Titel halbfett, Text normal). Liegt in `Resources/Fonts` (OFL) und wird über
    /// `ATSApplicationFontsPath` geladen; ohne Bundle (z. B. `swift run`) fällt sie auf die Systemschrift zurück.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(nsFont(size, weight))
    }

    /// JetBrains Mono für Zahlen, Zeiten, Größen, Kürzel und die kleinen Überschriften in Versalien.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(nsMono(size, weight))
    }

    static func nsFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        resolve(family: "Outfit", size: size, weight: weight) ?? .systemFont(ofSize: size, weight: weight.ns)
    }

    static func nsMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        resolve(family: "JetBrains Mono", size: size, weight: weight)
            ?? .monospacedSystemFont(ofSize: size, weight: weight.ns)
    }

    /// Kleine Überschrift in Versalien mit Sperrung (`AUFNAHME`, `ZULETZT`).
    static let overlineTracking: CGFloat = 0.9

    // MARK: Intern

    private static func resolve(family: String, size: CGFloat, weight: Font.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.ns.rawValue],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == family else { return nil }
        return font
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark, alpha: alpha.1) : rgb(light, alpha: alpha.0)
        }
    }
}

extension Font.Weight {
    var ns: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

extension Color {
    /// Kurzform für SwiftUI: `Color(Brand.accent)` → `.brand(Brand.accent)`.
    static func brand(_ color: NSColor) -> Color { Color(nsColor: color) }
}
