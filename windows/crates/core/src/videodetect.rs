//! Auto-Zensur im Video (`VideoRedactor.detect`): Texterkennung auf Einzelbildern alle `step`
//! Sekunden, Treffer werden zu Zeitbereichen verbunden.

use std::collections::BTreeSet;
use std::sync::atomic::AtomicBool;

use anyhow::Result;

use crate::model::{RedactStyle, SensitiveKind, TextLine, VideoRedaction};
use crate::RgbaImage;

pub struct DetectParams<'a> {
    pub start: f64,
    pub end: f64,
    pub step: f64,
    /// Volle Videogröße in Pixeln; Bilder von `frame_at` dürfen kleiner sein (≤ 2048), Funde werden hochgerechnet.
    pub video_width: f64,
    pub video_height: f64,
    pub style: RedactStyle,
    pub kinds: &'a BTreeSet<SensitiveKind>,
    pub cancel: &'a AtomicBool,
}

/// `frame_at(t)` liefert das Bild zum Zeitpunkt t (oder `None`), `ocr` die Zeilen eines Bildes.
/// Unveränderte Bilder (`FrameSignature`) übernehmen die Funde des vorigen. Spuren mit gleichem
/// Text und IoU > 0,3 werden verbunden; Ergebnis: Rechteck um 25 % der Höhe erweitert, Zeitbereich
/// um `step` erweitert (auf start/end begrenzt), `auto = true`. Abbruch → `Err`.
pub fn detect(
    params: &DetectParams,
    frame_at: &mut dyn FnMut(f64) -> Option<RgbaImage>,
    ocr: &mut dyn FnMut(&RgbaImage) -> Vec<TextLine>,
    progress: &mut dyn FnMut(f64),
) -> Result<Vec<VideoRedaction>> {
    let _ = (params, frame_at, ocr, progress);
    todo!("knips-core: videodetect::detect")
}
