//! Erkennen unveränderter Bilder (VideoRedactor.swift: `FrameSignature`, `ExactSignature`).

use crate::RgbaImage;

/// Winziges Graustufenbild (32×18). `matches`: mittlere Abweichung < 1,5 Helligkeitsstufen.
#[derive(Clone, Debug, PartialEq)]
pub struct FrameSignature {
    pub pixels: Vec<u8>,
}

impl FrameSignature {
    pub fn new(img: &RgbaImage) -> Self {
        let _ = img;
        todo!("knips-core: FrameSignature::new")
    }
    pub fn matches(&self, other: &FrameSignature) -> bool {
        let _ = other;
        todo!("knips-core: FrameSignature::matches")
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
        let _ = img;
        todo!("knips-core: ExactSignature::new")
    }
    pub fn matches(&self, other: &ExactSignature) -> bool {
        let _ = other;
        todo!("knips-core: ExactSignature::matches")
    }
}
