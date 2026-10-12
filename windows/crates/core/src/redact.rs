//! Zensur auf Pixeln — für Videobilder (`VideoRedactor.apply`). Bilder rendert der Editor selbst
//! (`src/editor/renderer.ts`) mit denselben Parametern.

use crate::geometry::Rect;
use crate::model::RedactStyle;
use crate::RgbaImage;

/// Blockgröße beim Verpixeln: 12 pt, mindestens 10 px (`EffectsCache.pixelBlock`).
pub fn pixel_block(scale: f64) -> u32 {
    (12.0 * scale).round().max(10.0) as u32
}

/// Radius der Unschärfe: 14 pt (`CIGaussianBlur` mit `14 * scale`).
pub fn blur_radius(scale: f64) -> f64 {
    14.0 * scale
}

/// Farbe des Balkens: Grau 0,06 (≈ 15/255).
pub const SOLID: [u8; 3] = [15, 15, 15];

/// Felder in Pixeln (Ursprung oben links) zensieren. Verpixeln: Blockraster ab Bildursprung (0,0),
/// Blockfarbe = Mittelwert. Unschärfe: Gauß (oder 3× Boxfilter) mit Rand-Klemmung am Bildrand,
/// Quelle ist das unveränderte Bild (überlappende Felder beeinflussen sich nicht).
pub fn apply(frame: &mut RgbaImage, regions: &[(Rect, RedactStyle)], scale: f64) {
    let _ = (frame, regions, scale);
    todo!("knips-core: redact::apply")
}
