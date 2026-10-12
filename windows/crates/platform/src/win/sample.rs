//! TODO(Windows): Startfassung = Kopie der Attrappe. Durch die echte Implementierung ersetzen,
//! Signaturen exakt beibehalten (Referenz: `mock/mod.rs`).

use knips_core::RgbaImage;

/// Testbild wie `SelfTest.sampleImage`: helles App-Fenster mit Seitenleiste und Kundendaten
/// (Name, E-Mail, Telefon, IBAN, Stripe-Key, Bestellnummer, Hinweis, Knopf) — mit echter
/// Schrift, damit Texterkennung und Auto-Zensur etwas finden. `scale`: Pixel pro Punkt.
pub fn sample_image(width: u32, height: u32, scale: f64) -> RgbaImage {
    let _ = scale;
    RgbaImage::from_fn(width.max(1), height.max(1), |x, y| {
        let sidebar = x < width / 5;
        let top = y < height / 14;
        if top {
            image::Rgba([210, 214, 222, 255])
        } else if sidebar {
            image::Rgba([46, 50, 62, 255])
        } else if y % 64 < 18 && x > width / 4 && x < width * 3 / 4 {
            image::Rgba([40, 40, 48, 255])
        } else {
            image::Rgba([235, 237, 242, 255])
        }
    })
}
