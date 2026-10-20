//! Scroll-Screenshots zusammensetzen (ScrollCapture.swift: `ScrollStitcher`, `RowProfile`).
//! Jedes neue Bild wird gegen das vorige verschoben verglichen (Zeilenprofile); nur die neu
//! sichtbaren Zeilen unten werden angehängt — und nur sie bleiben im Speicher. Höchstens
//! `MAX_HEIGHT` Pixel hoch.

use crate::imageops::resample_gray;
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
        let rows = img.height() as usize;
        Self { rows, values: resample_gray(img, Self::COLUMNS as u32, rows as u32) }
    }

    fn row_diff(&self, a: usize, other: &RowProfile, b: usize) -> u32 {
        let c = Self::COLUMNS;
        let ra = &self.values[a * c..(a + 1) * c];
        let rb = &other.values[b * c..(b + 1) * c];
        ra.iter().zip(rb).map(|(x, y)| (*x as i32 - *y as i32).unsigned_abs()).sum()
    }

    /// Wie weit der Inhalt nach oben gewandert ist (Pixel), oder `None`, wenn nichts sicher passt.
    /// Exakt wie `RowProfile.shift(to:)`: Rand je ein Zehntel, Mindestüberlappung ein Viertel,
    /// grob jede 4. Zeile, die drei besten Kandidaten ±2 mit allen Zeilen nachschärfen, Schwelle 6,
    /// „unbewegt ist genauso gut“ (+0,3) → `None`.
    pub fn shift(&self, next: &RowProfile) -> Option<usize> {
        let h = self.rows.min(next.rows) as i64;
        let margin = h / 10;
        let min_overlap = h / 4;
        if h - min_overlap <= 0 {
            return None;
        }
        let cost = |d: i64, step: usize| -> f64 {
            // Zeile r im neuen Bild entspricht Zeile r + d im alten.
            let lo = margin;
            let hi = h - d - margin;
            if hi - lo < min_overlap / 2 {
                return f64::INFINITY;
            }
            let (mut sum, mut n) = (0u64, 0u64);
            let mut r = lo;
            while r < hi {
                sum += self.row_diff((r + d) as usize, next, r as usize) as u64;
                n += 1;
                r += step as i64;
            }
            if n > 0 {
                sum as f64 / (n * Self::COLUMNS as u64) as f64
            } else {
                f64::INFINITY
            }
        };
        // Jede Verschiebung mit jeder 4. Zeile prüfen (sich wiederholende Zeilen verlangen das),
        // dann die drei besten Kandidaten mit allen Zeilen nachschärfen.
        let limit = h - min_overlap;
        let mut coarse: Vec<(i64, f64)> = (0..limit).map(|d| (d, cost(d, 4))).collect();
        coarse.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        let mut best = (0i64, f64::INFINITY);
        for &(cd, _) in coarse.iter().take(3) {
            for f in (cd - 2).max(0)..=(cd + 2) {
                if f >= limit {
                    continue;
                }
                let c = cost(f, 1);
                if c < best.1 {
                    best = (f, c);
                }
            }
        }
        // Unverändert oder kein eindeutiger Treffer.
        if best.0 <= 0 || best.1 >= 6.0 {
            return None;
        }
        // Ganz ohne Bewegung ist genauso gut wie die beste Verschiebung → nicht gescrollt.
        if cost(0, 1) <= best.1 + 0.3 {
            return None;
        }
        Some(best.0 as usize)
    }
}

/// Höchste Höhe eines Scroll-Screenshots in Pixeln. Darüber kann der Editor das Bild nicht mehr
/// darstellen (Canvas höchstens ~32 767 px), und der Speicher wüchse mit jeder Seite weiter.
/// Ist sie erreicht, endet die Aufnahme von selbst (`is_full`).
pub const MAX_HEIGHT: u32 = 30_000;

pub struct ScrollStitcher {
    /// Das Ergebnis, Zeile für Zeile von oben (RGBA): zuerst das ganze erste Bild, danach nur die
    /// jeweils neu sichtbaren Zeilen. Ganze Einzelbilder werden nicht aufgehoben.
    data: Vec<u8>,
    sections: usize,
    previous: Option<RowProfile>,
    pub height: u32,
    pub width: u32,
    max_height: u32,
}

impl ScrollStitcher {
    pub fn new(first: RgbaImage) -> Self {
        Self::with_max_height(first, MAX_HEIGHT)
    }

    /// Wie `new`, mit eigener Höchsthöhe (Tests).
    pub fn with_max_height(first: RgbaImage, max_height: u32) -> Self {
        let max_height = max_height.max(1);
        let width = first.width();
        let height = first.height().min(max_height);
        let previous = Some(RowProfile::new(&first));
        let row = width as usize * 4;
        let data = first.as_raw()[..height as usize * row].to_vec();
        Self { data, sections: 1, previous, height, width, max_height }
    }

    /// `true`, wenn das Bild neue Zeilen beigetragen hat. Ist die Höchsthöhe erreicht, kommt nichts
    /// mehr dazu (`is_full`).
    pub fn add(&mut self, frame: RgbaImage) -> bool {
        if self.is_full() || frame.width() != self.width {
            return false;
        }
        let Some(prev) = &self.previous else { return false };
        let current = RowProfile::new(&frame);
        let Some(shift) = prev.shift(&current).filter(|&s| s > 0) else { return false };
        let shift = (shift as u32).min(frame.height());
        // Neu sichtbar sind die unteren `shift` Zeilen; bei erreichter Höchsthöhe nur deren Anfang,
        // damit das Bild lückenlos bleibt.
        let take = shift.min(self.max_height - self.height);
        let row = self.width as usize * 4;
        let start = (frame.height() - shift) as usize;
        self.data.extend_from_slice(&frame.as_raw()[start * row..(start + take as usize) * row]);
        self.height += take;
        self.sections += 1;
        self.previous = Some(current);
        true
    }

    /// Höchsthöhe erreicht — die Aufnahme sollte enden.
    pub fn is_full(&self) -> bool {
        self.height >= self.max_height
    }

    pub fn max_height(&self) -> u32 {
        self.max_height
    }

    pub fn sections(&self) -> usize {
        self.sections
    }

    /// Belegter Speicher für die Bilddaten (Bytes) — wächst nur mit dem Ergebnis, nicht je Einzelbild.
    pub fn memory_bytes(&self) -> usize {
        self.data.len()
    }

    /// Das zusammengesetzte Bild (Kopie; `into_image` ohne).
    pub fn assemble(&self) -> RgbaImage {
        RgbaImage::from_raw(self.width, self.height, self.data.clone()).expect("Größe stimmt")
    }

    /// Das zusammengesetzte Bild ohne zweite Kopie im Speicher.
    pub fn into_image(self) -> RgbaImage {
        RgbaImage::from_raw(self.width, self.height, self.data).expect("Größe stimmt")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;

    /// Deterministischer Zufall.
    fn rng(seed: &mut u64) -> u32 {
        *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (*seed >> 33) as u32
    }

    /// Langes Testbild wie auf dem Mac: „Textzeilen“ (zufällige Blöcke) alle 34 px, einzelne
    /// farbige Balken. Eindeutiger Inhalt in jeder Zeile.
    fn tall_image(w: u32, h: u32) -> RgbaImage {
        let mut img = RgbaImage::from_pixel(w, h, Rgba([247, 247, 247, 255]));
        let mut seed = 12345u64;
        let mut i = 0;
        let mut y = 20;
        while y + 26 < h {
            let mut x = 40 + (i % 5) * 12;
            while x < w - 60 {
                let bw = 6 + rng(&mut seed) % 14;
                let g = 20 + (rng(&mut seed) % 120) as u8;
                if !rng(&mut seed).is_multiple_of(4) {
                    for yy in y + 4..y + 22 {
                        for xx in x..(x + bw).min(w) {
                            img.put_pixel(xx, yy, Rgba([g, g, g, 255]));
                        }
                    }
                }
                x += bw + 4 + rng(&mut seed) % 6;
            }
            if i % 9 == 0 {
                for yy in y..y + 26 {
                    for xx in 700..1000.min(w) {
                        img.put_pixel(xx, yy, Rgba([150, 190, 240, 255]));
                    }
                }
            }
            y += 34;
            i += 1;
        }
        img
    }

    fn slice(img: &RgbaImage, y: u32, h: u32) -> RgbaImage {
        image::imageops::crop_imm(img, 0, y, img.width(), h).to_image()
    }

    #[test]
    fn stitches_exactly() {
        let (w, h, view) = (1200, 4200, 900);
        let tall = tall_image(w, h);
        let offsets = [0u32, 0, 140, 140, 410, 760, 760, 1180, 1500, 1990, 2400, 2760, 3100, 3300];
        let frames: Vec<_> = offsets.iter().map(|&o| slice(&tall, o, view)).collect();
        let mut st = ScrollStitcher::new(frames[0].clone());
        let mut added = 0;
        for f in &frames[1..] {
            if st.add(f.clone()) {
                added += 1;
            }
        }
        let expected = offsets.last().unwrap() + view;
        let result = st.assemble();
        assert_eq!(result.height(), expected);
        assert_eq!(added, 10); // vier Wiederholungen ohne Bewegung (0, 140, 760 doppelt) fallen weg
        assert_eq!(st.sections(), added + 1);
        assert_eq!(result, slice(&tall, 0, expected), "zusammengesetzt = Original");
    }

    #[test]
    fn fixed_header_and_footer_are_ignored() {
        let (w, h, view) = (1000, 3000, 800);
        let mut tall = tall_image(w, h);
        let offsets = [0u32, 90, 260, 500, 777, 1100, 1500];
        let mut frames: Vec<RgbaImage> = offsets.iter().map(|&o| slice(&tall, o, view)).collect();
        // feste Kopf- (60 px) und Fußleiste (50 px) in jedem Bild
        for f in &mut frames {
            for y in 0..60 {
                for x in 0..w {
                    f.put_pixel(x, y, Rgba([30, 30, 120, 255]));
                }
            }
            for y in view - 50..view {
                for x in 0..w {
                    f.put_pixel(x, y, Rgba([200, 60, 60, 255]));
                }
            }
        }
        let mut st = ScrollStitcher::new(frames[0].clone());
        let n = frames[1..].iter().filter(|f| st.add((*f).clone())).count();
        assert_eq!(n, offsets.len() - 1);
        assert_eq!(st.height, offsets.last().unwrap() + view);
        // Wie auf dem Mac: die Fußleiste steckt in den angehängten Zeilen (nur der Vergleich ignoriert sie),
        // die Kopfleiste steht nur oben.
        let result = st.assemble();
        assert_eq!(result.get_pixel(500, 10), &Rgba([30, 30, 120, 255]));
        assert_eq!(result.get_pixel(500, result.height() - 10), &Rgba([200, 60, 60, 255]));
        let _ = &mut tall;
    }

    #[test]
    fn rejects_other_width_and_unmoved() {
        let tall = tall_image(600, 2000);
        let a = slice(&tall, 0, 500);
        let mut st = ScrollStitcher::new(a.clone());
        assert!(!st.add(a.clone()));
        assert!(!st.add(slice(&tall_image(500, 2000), 0, 500)));
        assert_eq!(st.height, 500);
        assert!(st.add(slice(&tall, 120, 500)));
        assert_eq!(st.height, 620);
    }

    #[test]
    fn unrelated_image_does_not_match() {
        let a = tall_image(600, 2000);
        let mut seed = 99;
        let noise = RgbaImage::from_fn(600, 500, |_, _| {
            let v = (rng(&mut seed) % 256) as u8;
            Rgba([v, v, v, 255])
        });
        let mut st = ScrollStitcher::new(slice(&a, 0, 500));
        assert!(!st.add(noise));
    }

    #[test]
    fn keeps_only_new_rows_in_memory() {
        let (w, h, view) = (800, 6000, 700);
        let tall = tall_image(w, h);
        let mut st = ScrollStitcher::new(slice(&tall, 0, view));
        let mut o = 0;
        for _ in 0..40 {
            o += 130;
            if o + view > h {
                break;
            }
            assert!(st.add(slice(&tall, o, view)));
        }
        // Speicher = genau das Ergebnis; früher je Abschnitt ein ganzes Einzelbild (hier ~5× so viel).
        assert_eq!(st.memory_bytes(), (w * st.height * 4) as usize);
        let whole_frames = st.sections() * (w * view * 4) as usize;
        assert!(st.memory_bytes() * 4 < whole_frames, "{} vs. {whole_frames}", st.memory_bytes());
        assert_eq!(st.into_image(), slice(&tall, 0, o + view));
    }

    #[test]
    fn stops_at_max_height() {
        let (w, h, view) = (600, 5000, 500);
        let tall = tall_image(w, h);
        let max = 1234;
        let mut st = ScrollStitcher::with_max_height(slice(&tall, 0, view), max);
        let mut o = 0;
        let mut full_after = None;
        for i in 0..8 {
            o += 180;
            st.add(slice(&tall, o, view));
            if st.is_full() && full_after.is_none() {
                full_after = Some(i);
            }
        }
        assert!(st.is_full());
        assert_eq!(st.height, max, "genau auf die Höchsthöhe begrenzt");
        assert!(!st.add(slice(&tall, o + 200, view)), "danach kommt nichts mehr dazu");
        let img = st.assemble();
        assert_eq!((img.width(), img.height()), (w, max));
        // Lückenlos: der Anfang des Originals bis zur Höchsthöhe.
        assert_eq!(img, slice(&tall, 0, max));
        assert_eq!(full_after, Some(4), "500 + 4 × 180 = 1220, das 5. Bild füllt die letzten 14 Zeilen");
        // Erstes Bild höher als die Grenze: abgeschnitten, sofort voll.
        let st = ScrollStitcher::with_max_height(slice(&tall, 0, view), 300);
        assert!(st.is_full());
        assert_eq!(st.assemble(), slice(&tall, 0, 300));
        assert_eq!(MAX_HEIGHT, 30_000);
    }

    #[test]
    fn tiny_profiles_do_not_panic() {
        let a = RowProfile::new(&RgbaImage::from_pixel(10, 3, Rgba([1, 2, 3, 255])));
        assert_eq!(a.shift(&a), None);
    }

    #[test]
    #[ignore]
    fn perf_shift() {
        let tall = tall_image(3840, 3000);
        let a = RowProfile::new(&slice(&tall, 0, 2160));
        let b = RowProfile::new(&slice(&tall, 300, 2160));
        let t = std::time::Instant::now();
        let s = a.shift(&b);
        println!("shift 4K (2160 Zeilen): {:?} -> {:?}", t.elapsed(), s);
        let img = slice(&tall, 0, 2160);
        let t = std::time::Instant::now();
        let _ = RowProfile::new(&img);
        println!("RowProfile 3840x2160: {:?}", t.elapsed());
    }
}
