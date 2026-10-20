//! Farben, Schriften und Maße des Auswahl-Overlays und des Aufnahmerahmens — die einzige Stelle in Rust.
//! Werte wie `windows/src/shared/tokens.css` (`--k-dark-*`, `--k-record`) und `Sources/Knips/UI/Brand.swift`
//! (`Brand.Dark`), Regeln in `docs/design.md` („Auswahl-Overlay“, „Dunkel schwebt“): Overlay-Elemente sind
//! immer dunkel, Königsblau hell ist der einzige Akzent, Rot nur für den Rahmen einer laufenden Aufnahme.
//! Reine Daten ohne Windows-Typen (auf dem Mac testbar).

#![allow(dead_code)]

/// Farbe mit geradem Alpha, Kanäle 0…1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

/// `0xRRGGBB` + Deckkraft.
pub const fn hex(rgb: u32, a: f32) -> Rgba {
    Rgba {
        r: ((rgb >> 16) & 0xFF) as f32 / 255.0,
        g: ((rgb >> 8) & 0xFF) as f32 / 255.0,
        b: (rgb & 0xFF) as f32 / 255.0,
        a,
    }
}

impl Rgba {
    pub const fn with_alpha(self, a: f32) -> Rgba {
        Rgba { a, ..self }
    }
}

// --- Tokens (tokens.css) ---------------------------------------------------------------------------

/// `--k-dark`: dunkle Schwebefläche.
pub const DARK: Rgba = hex(0x141518, 1.0);
/// `--k-dark-raised`: gehoben (Tastenkappen).
pub const DARK_RAISED: Rgba = hex(0x24262C, 1.0);
/// `--k-dark-line`: Linie weiß 8 %.
pub const DARK_LINE: Rgba = hex(0xFFFFFF, 0.08);
/// `--k-dark-ink`: Text auf dunklem Grund.
pub const DARK_INK: Rgba = hex(0xECEEF2, 1.0);
/// `--k-dark-muted`: leiser Text auf dunklem Grund.
pub const DARK_MUTED: Rgba = hex(0x979BA5, 1.0);
/// `--k-dark-accent`: Königsblau hell — Auswahlrahmen, Eckgriffe, Fenstermodus, Scroll-Rahmen.
pub const DARK_ACCENT: Rgba = hex(0x9AA6FF, 1.0);
/// `--k-record` (hell): Aufnahme-Rot für den Rahmen einer laufenden Bildschirmaufnahme.
pub const RECORD: Rgba = hex(0xE8523F, 1.0);

// --- Overlay ---------------------------------------------------------------------------------------

/// Abdunklung außerhalb der Auswahl (wie bisher: Schwarz 38 %).
pub const DIM: Rgba = hex(0x000000, 0.38);
/// Auswahlrahmen: Königsblau hell, 1,5 pt.
pub const SELECTION: Rgba = DARK_ACCENT;
pub const SELECTION_WIDTH: f32 = 1.5;
/// Weicher dunkler Saum unter Rahmen und Eckgriffen, damit sie auf hellem Inhalt stehen.
pub const HALO: Rgba = DARK.with_alpha(0.35);
/// Eckgriffe: Winkel wie die Ecken im Zeichen, 3 pt stark, Schenkel bis 14 pt.
pub const HANDLE_WIDTH: f32 = 3.0;
pub const HANDLE_ARM: f64 = 14.0;
/// Fenstermodus: Königsblau-Fläche 12 % und Rand 2 pt.
pub const WINDOW_FILL: Rgba = DARK_ACCENT.with_alpha(0.12);
pub const WINDOW_STROKE: Rgba = DARK_ACCENT;
pub const WINDOW_STROKE_WIDTH: f32 = 2.0;
/// Pillen (Größe, Hinweiszeile, Koordinaten der Lupe): dunkle Fläche, Linie, heller Text.
pub const PILL: Rgba = DARK.with_alpha(0.94);
pub const PILL_LINE: Rgba = DARK_LINE;
pub const PILL_INK: Rgba = DARK_INK;
pub const PILL_MUTED: Rgba = DARK_MUTED;
/// Tastenkappen in der Hinweiszeile.
pub const KEYCAP: Rgba = DARK_RAISED;
pub const KEYCAP_LINE: Rgba = hex(0xFFFFFF, 0.10);
/// Fadenkreuz (wie bisher).
pub const CROSSHAIR: Rgba = hex(0xFFFFFF, 0.55);
pub const CROSSHAIR_SHADOW: Rgba = hex(0x000000, 0.22);
/// Lupe: Ring und mittleres Pixel in heller Tinte.
pub const LOUPE_RING: Rgba = DARK_INK;

// --- Aufnahmerahmen --------------------------------------------------------------------------------

/// Gestrichelter Rahmen um eine laufende Bildschirmaufnahme.
pub const FRAME_RECORDING: Rgba = RECORD;
/// … und um einen Scroll-Screenshot (Königsblau hell wie der Auswahlrahmen, aus dem er entsteht).
pub const FRAME_SCROLL: Rgba = DARK_ACCENT;
/// Saum unter dem Rahmen (hebt ihn auf hellem und dunklem Inhalt ab).
pub const FRAME_HALO: Rgba = DARK.with_alpha(0.45);

// --- Schrift ---------------------------------------------------------------------------------------
// JetBrains Mono und Outfit liegen nicht im System; DirectWrite nimmt die nächsten Verwandten.

/// `--k-mono`: Zahlen (Größe, Koordinaten) und Tastenkappen. Erste vorhandene Familie gewinnt.
pub const MONO_FAMILIES: [&str; 2] = ["Cascadia Mono", "Consolas"];
/// `--k-font`: Text der Hinweiszeile.
pub const TEXT_FAMILIES: [&str; 2] = ["Segoe UI Variable Text", "Segoe UI"];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_channels() {
        let c = hex(0x9AA6FF, 1.0);
        assert_eq!((c.r * 255.0).round() as u8, 0x9A);
        assert_eq!((c.g * 255.0).round() as u8, 0xA6);
        assert_eq!((c.b * 255.0).round() as u8, 0xFF);
        assert_eq!(RECORD, hex(0xE8523F, 1.0));
        assert_eq!(WINDOW_FILL.a, 0.12);
        assert_eq!(PILL.r, DARK.r);
    }
}
