//! Scroll-Screenshots zusammensetzen (ScrollCapture.swift: `ScrollStitcher`, `RowProfile`).
//! Jedes neue Bild wird gegen das vorige verschoben verglichen (Zeilenprofile); nur die neu
//! sichtbaren Zeilen unten werden angehängt.

use crate::RgbaImage;

/// Graustufen-Profil: je Zeile 48 Stichproben (Bild auf 48 Spalten Breite verkleinert, Zeile 0 = oben).
#[derive(Clone, Debug)]
pub struct RowProfile {
    pub rows: usize,
    pub values: Vec<u8>,
}

impl RowProfile {
    pub const COLUMNS: usize = 48;

    pub fn new(img: &RgbaImage) -> Self {
        let _ = img;
        todo!("knips-core: RowProfile::new")
    }

    /// Wie weit der Inhalt nach oben gewandert ist (Pixel), oder `None`, wenn nichts sicher passt.
    /// Exakt wie `RowProfile.shift(to:)`: Rand je ein Zehntel, Mindestüberlappung ein Viertel,
    /// grob jede 4. Zeile, die drei besten Kandidaten ±2 mit allen Zeilen nachschärfen, Schwelle 6,
    /// „unbewegt ist genauso gut“ (+0,3) → `None`.
    pub fn shift(&self, next: &RowProfile) -> Option<usize> {
        let _ = next;
        todo!("knips-core: RowProfile::shift")
    }
}

pub struct ScrollStitcher {
    /// (Bild, Zeilenbereich daraus, der angehängt wird)
    pub pieces: Vec<(RgbaImage, std::ops::Range<u32>)>,
    previous: Option<RowProfile>,
    pub height: u32,
    pub width: u32,
}

impl ScrollStitcher {
    pub fn new(first: RgbaImage) -> Self {
        let _ = (&first, &None::<RowProfile>);
        todo!("knips-core: ScrollStitcher::new")
    }

    /// `true`, wenn das Bild neue Zeilen beigetragen hat.
    pub fn add(&mut self, frame: RgbaImage) -> bool {
        let _ = (frame, &self.previous);
        todo!("knips-core: ScrollStitcher::add")
    }

    pub fn sections(&self) -> usize {
        self.pieces.len()
    }

    pub fn assemble(&self) -> RgbaImage {
        todo!("knips-core: ScrollStitcher::assemble")
    }
}
