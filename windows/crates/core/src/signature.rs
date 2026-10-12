//! Erkennen unveränderter Bilder (VideoRedactor.swift: `FrameSignature`, `ExactSignature`).

use crate::imageops::resample_gray;
use crate::RgbaImage;

/// Winziges Graustufenbild (32×18). `matches`: mittlere Abweichung < 1,5 Helligkeitsstufen.
#[derive(Clone, Debug, PartialEq)]
pub struct FrameSignature {
    pub pixels: Vec<u8>,
}

impl FrameSignature {
    pub fn new(img: &RgbaImage) -> Self {
        Self { pixels: resample_gray(img, 32, 18) }
    }
    pub fn matches(&self, other: &FrameSignature) -> bool {
        if self.pixels.len() != other.pixels.len() {
            return false;
        }
        let diff: u64 = self.pixels.iter().zip(&other.pixels).map(|(a, b)| (*a as i32 - *b as i32).unsigned_abs() as u64).sum();
        (diff as f64) / (self.pixels.len() as f64) < 1.5
    }
}

/// 160×90 Graustufen: Kompressionsrauschen bleibt unter 24 Stufen, ein bewegter Mauszeiger oder
/// ein getipptes Zeichen liegt darüber. `matches`: kein Pixel weicht mehr als 24 ab.
#[derive(Clone, Debug, PartialEq)]
pub struct ExactSignature {
    pub pixels: Vec<u8>,
}

impl ExactSignature {
    pub fn new(img: &RgbaImage) -> Self {
        Self { pixels: resample_gray(img, 160, 90) }
    }
    pub fn matches(&self, other: &ExactSignature) -> bool {
        self.pixels.len() == other.pixels.len()
            && self.pixels.iter().zip(&other.pixels).all(|(a, b)| (*a as i32 - *b as i32).abs() <= 24)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;

    fn base() -> RgbaImage {
        RgbaImage::from_fn(1280, 720, |x, y| {
            let v = if (x / 40 + y / 40) % 2 == 0 { 200 } else { 60 };
            Rgba([v, v, v, 255])
        })
    }

    #[test]
    fn identical_and_noisy_frames_match() {
        let a = base();
        let mut b = a.clone();
        for (i, p) in b.pixels_mut().enumerate() {
            let n = ((i * 2654435761) >> 28) as i32 % 3 - 1; // ±1 Rauschen
            for c in 0..3 {
                p[c] = (p[c] as i32 + n).clamp(0, 255) as u8;
            }
        }
        assert!(FrameSignature::new(&a).matches(&FrameSignature::new(&a)));
        assert!(FrameSignature::new(&a).matches(&FrameSignature::new(&b)));
        assert!(ExactSignature::new(&a).matches(&ExactSignature::new(&b)));
    }

    #[test]
    fn small_cursor_is_a_change_for_exact_only() {
        let a = base();
        let mut b = a.clone();
        // schwarzer Mauszeiger ~ 16×24 px auf weißer Fläche
        for y in 80..104 {
            for x in 80..96 {
                b.put_pixel(x, y, Rgba([0, 0, 0, 255]));
            }
        }
        assert!(!ExactSignature::new(&a).matches(&ExactSignature::new(&b)));
        // Das grobe 32×18-Bild verschluckt so etwas (gewollt: nur für OCR-Zwischenspeicher)
        assert!(FrameSignature::new(&a).matches(&FrameSignature::new(&b)));
    }

    #[test]
    fn real_change_is_detected() {
        let a = base();
        let b = RgbaImage::from_pixel(1280, 720, Rgba([255, 255, 255, 255]));
        assert!(!FrameSignature::new(&a).matches(&FrameSignature::new(&b)));
        assert!(!ExactSignature::new(&a).matches(&ExactSignature::new(&b)));
        assert_eq!(FrameSignature::new(&a).pixels.len(), 32 * 18);
        assert_eq!(ExactSignature::new(&a).pixels.len(), 160 * 90);
    }

    #[test]
    fn thresholds() {
        let g = |v: u8| RgbaImage::from_pixel(64, 36, Rgba([v, v, v, 255]));
        // mittlere Abweichung 1 → gleich, 2 → verschieden
        assert!(FrameSignature::new(&g(100)).matches(&FrameSignature::new(&g(101))));
        assert!(!FrameSignature::new(&g(100)).matches(&FrameSignature::new(&g(102))));
        // 24 Stufen noch gleich, 25 nicht
        assert!(ExactSignature::new(&g(100)).matches(&ExactSignature::new(&g(124))));
        assert!(!ExactSignature::new(&g(100)).matches(&ExactSignature::new(&g(125))));
    }
}
