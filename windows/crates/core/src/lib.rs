//! Knips-Kern: alles, was nicht von Windows abhängt. Läuft und testet auch auf dem Mac
//! (`cargo test -p knips-core`). Die Windows-Teile stehen in `crates/platform`.

pub mod cards;
pub mod format;
pub mod geometry;
pub mod gifenc;
pub mod imageops;
pub mod model;
pub mod redact;
pub mod sensitive;
pub mod settings;
pub mod signature;
pub mod stitch;
pub mod textlayout;
pub mod tracker;
pub mod videodetect;

pub use image::RgbaImage;

/// Längste Kante für die Texterkennung (wie `SensitiveDetector.ocrMaxPixel`): auf 4K-Bildern
/// sonst um Größenordnungen langsamer, bei gleicher Trefferzahl.
pub const OCR_MAX_PIXEL: u32 = 2048;
