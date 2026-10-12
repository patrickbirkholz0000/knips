//! Bildoperationen (ImageIOHelper in Utilities.swift). Kanonisches Format: `RgbaImage`
//! (8 Bit, nicht vormultipliziert, sRGB).

use anyhow::Result;

use crate::geometry::IRect;
use crate::model::ImageFormat;
use crate::RgbaImage;

/// Auf `factor` (< 1) verkleinern, z. B. volle Auflösung → Bildschirmgröße (1×). Hohe Qualität.
/// Neue Maße: gerundet, mindestens 1. Bei `factor >= 0.999` unverändert (Kopie).
pub fn scaled(img: &RgbaImage, factor: f64) -> RgbaImage {
    let _ = (img, factor);
    todo!("knips-core: imageops::scaled")
}

/// Längste Kante auf höchstens `max_pixel` verkleinern (Vorschaubilder 640, Texterkennung 2048).
pub fn downscale(img: &RgbaImage, max_pixel: u32) -> RgbaImage {
    let _ = (img, max_pixel);
    todo!("knips-core: imageops::downscale")
}

/// PNG verlustfrei; JPEG mit Qualität 85 (Schrift bleibt scharf), Transparenz auf Weiß.
pub fn encode(img: &RgbaImage, format: ImageFormat) -> Result<Vec<u8>> {
    let _ = (img, format);
    todo!("knips-core: imageops::encode")
}

/// PNG/JPEG/GIF (erstes Bild)/BMP-Bytes → RGBA.
pub fn decode(bytes: &[u8]) -> Result<RgbaImage> {
    let _ = bytes;
    todo!("knips-core: imageops::decode")
}

pub fn load(path: &std::path::Path) -> Result<RgbaImage> {
    decode(&std::fs::read(path)?)
}

/// Ausschnitt in Pixeln; auf das Bild begrenzt. `None`, wenn nichts übrig bleibt.
pub fn crop(img: &RgbaImage, rect: IRect) -> Option<RgbaImage> {
    let _ = (img, rect);
    todo!("knips-core: imageops::crop")
}

/// BGRA-Zeilen (z. B. aus Direct3D, `stride` Bytes pro Zeile) → RGBA. Alpha wird auf 255 gesetzt,
/// wenn `opaque`.
pub fn from_bgra(width: u32, height: u32, stride: usize, bgra: &[u8], opaque: bool) -> RgbaImage {
    let _ = (width, height, stride, bgra, opaque);
    todo!("knips-core: imageops::from_bgra")
}

/// RGBA → BGRA (dicht gepackt), z. B. für Zwischenablage-DIBs und Media Foundation.
pub fn to_bgra(img: &RgbaImage) -> Vec<u8> {
    let _ = img;
    todo!("knips-core: imageops::to_bgra")
}
