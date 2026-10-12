//! GIF-Export (`VideoRedactor.exportGIF`): Endlosschleife, unveränderte Bilder verlängern die
//! Anzeigedauer des vorigen statt wiederholt zu werden (`ExactSignature`).

use std::path::Path;

use anyhow::Result;

use crate::RgbaImage;

pub struct GifWriter {
    _private: (),
}

impl GifWriter {
    pub fn create(path: &Path, width: u32, height: u32) -> Result<Self> {
        let _ = (path, width, height);
        todo!("knips-core: GifWriter::create")
    }

    /// Bild mit Anzeigedauer `delay` (Sekunden). Alle Bilder haben die Größe aus `create`.
    pub fn push(&mut self, frame: &RgbaImage, delay: f64) -> Result<()> {
        let _ = (frame, delay);
        todo!("knips-core: GifWriter::push")
    }

    /// Schreibt das letzte Bild und schließt die Datei. Liefert die Zahl geschriebener Bilder.
    pub fn finish(self) -> Result<usize> {
        todo!("knips-core: GifWriter::finish")
    }
}
