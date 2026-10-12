//! GIF-Export (`VideoRedactor.exportGIF`): Endlosschleife, unveränderte Bilder verlängern die
//! Anzeigedauer des vorigen statt wiederholt zu werden (`ExactSignature`).

#![allow(clippy::chunks_exact_to_as_chunks)] // Rust-Version offen halten: kein `as_chunks`


use std::fs::File;
use std::io::BufWriter;
use std::path::Path;

use anyhow::{anyhow, Result};
use gif::{Encoder, Frame, Repeat};

use crate::signature::ExactSignature;
use crate::RgbaImage;

/// Farbquantisierung: 1 = beste Qualität, 30 = schnellste. 10 ist gut genug für Bildschirminhalt.
const QUANT_SPEED: i32 = 10;

struct Pending {
    image: RgbaImage,
    signature: ExactSignature,
    duration: f64,
}

pub struct GifWriter {
    encoder: Encoder<BufWriter<File>>,
    width: u32,
    height: u32,
    pending: Option<Pending>,
    /// Rundungsrest in Hundertstelsekunden, damit die Gesamtdauer stimmt.
    carry: f64,
    written: usize,
}

impl GifWriter {
    pub fn create(path: &Path, width: u32, height: u32) -> Result<Self> {
        let (w, h) = (u16::try_from(width)?, u16::try_from(height)?);
        if w == 0 || h == 0 {
            return Err(anyhow!("GIF braucht mindestens 1×1 Pixel"));
        }
        let _ = std::fs::remove_file(path);
        let file = BufWriter::new(File::create(path)?);
        let mut encoder = Encoder::new(file, w, h, &[])?;
        encoder.set_repeat(Repeat::Infinite)?;
        Ok(Self { encoder, width, height, pending: None, carry: 0.0, written: 0 })
    }

    /// Bild mit Anzeigedauer `delay` (Sekunden). Alle Bilder haben die Größe aus `create`.
    pub fn push(&mut self, frame: &RgbaImage, delay: f64) -> Result<()> {
        if frame.dimensions() != (self.width, self.height) {
            return Err(anyhow!("Bildgröße weicht ab: {}×{} statt {}×{}", frame.width(), frame.height(), self.width, self.height));
        }
        let signature = ExactSignature::new(frame);
        if let Some(p) = &mut self.pending {
            if p.signature.matches(&signature) {
                p.duration += delay;
                return Ok(());
            }
        }
        self.flush()?;
        self.pending = Some(Pending { image: frame.clone(), signature, duration: delay });
        Ok(())
    }

    fn flush(&mut self) -> Result<()> {
        let Some(p) = self.pending.take() else { return Ok(()) };
        // Hundertstelsekunden mit Übertrag; mindestens 1.
        let want = p.duration * 100.0 + self.carry;
        let cs = want.round().clamp(1.0, 65535.0);
        self.carry = want - cs;
        let mut rgba = p.image.into_raw();
        for px in rgba.chunks_exact_mut(4) {
            px[3] = 255;
        }
        let mut frame = Frame::from_rgba_speed(self.width as u16, self.height as u16, &mut rgba, QUANT_SPEED);
        frame.delay = cs as u16;
        self.encoder.write_frame(&frame)?;
        self.written += 1;
        Ok(())
    }

    /// Schreibt das letzte Bild und schließt die Datei. Liefert die Zahl geschriebener Bilder.
    pub fn finish(mut self) -> Result<usize> {
        self.flush()?;
        let mut w = self.encoder.into_inner()?;
        std::io::Write::flush(&mut w)?;
        Ok(self.written)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;

    fn solid(v: u8) -> RgbaImage {
        RgbaImage::from_pixel(64, 36, Rgba([v, v / 2, 255 - v, 255]))
    }

    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join("knips-core-tests");
        std::fs::create_dir_all(&d).unwrap();
        d.join(name)
    }

    fn read(path: &Path) -> (Vec<(u16, Vec<u8>)>, gif::Repeat) {
        let mut opts = gif::DecodeOptions::new();
        opts.set_color_output(gif::ColorOutput::RGBA);
        let mut dec = opts.read_info(File::open(path).unwrap()).unwrap();
        let mut out = Vec::new();
        while let Some(f) = dec.read_next_frame().unwrap() {
            out.push((f.delay, f.buffer.to_vec()));
        }
        (out, dec.repeat())
    }

    #[test]
    fn dedups_identical_frames_and_keeps_delays() {
        let path = tmp("dedup.gif");
        let mut w = GifWriter::create(&path, 64, 36).unwrap();
        // 5 Bilder à 1/10 s gleich, 2 anders, 3 gleich wie das erste
        for _ in 0..5 {
            w.push(&solid(40), 0.1).unwrap();
        }
        for _ in 0..2 {
            w.push(&solid(200), 0.1).unwrap();
        }
        for _ in 0..3 {
            w.push(&solid(40), 0.1).unwrap();
        }
        assert_eq!(w.finish().unwrap(), 3);
        let (frames, repeat) = read(&path);
        assert_eq!(frames.len(), 3);
        assert_eq!(frames.iter().map(|f| f.0).collect::<Vec<_>>(), vec![50, 20, 30]);
        assert!(matches!(repeat, gif::Repeat::Infinite));
        // Farben stimmen annähernd
        assert!((frames[0].1[0] as i32 - 40).abs() < 12);
        assert!((frames[1].1[0] as i32 - 200).abs() < 12);
    }

    #[test]
    fn rounding_carry_keeps_total_duration() {
        let path = tmp("carry.gif");
        let mut w = GifWriter::create(&path, 64, 36).unwrap();
        // 1/30 s = 3,33 cs; 30 verschiedene Bilder → Summe 100 cs
        for i in 0..30 {
            w.push(&solid(if i % 2 == 0 { 20 } else { 230 }), 1.0 / 30.0).unwrap();
        }
        assert_eq!(w.finish().unwrap(), 30);
        let (frames, _) = read(&path);
        let total: u32 = frames.iter().map(|f| f.0 as u32).sum();
        assert_eq!(total, 100);
        assert!(frames.iter().all(|f| f.0 == 3 || f.0 == 4));
    }

    #[test]
    fn small_change_extends_cursor_moves_new_frame() {
        let path = tmp("cursor.gif");
        let a = solid(120);
        let mut noisy = a.clone();
        noisy.put_pixel(3, 3, Rgba([130, 60, 125, 255])); // Rauschen, unter Schwelle
        let mut cursor = a.clone();
        for y in 10..26 {
            for x in 10..22 {
                cursor.put_pixel(x, y, Rgba([0, 0, 0, 255]));
            }
        }
        let mut w = GifWriter::create(&path, 64, 36).unwrap();
        w.push(&a, 0.05).unwrap();
        w.push(&noisy, 0.05).unwrap();
        w.push(&cursor, 0.05).unwrap();
        assert_eq!(w.finish().unwrap(), 2);
        let (frames, _) = read(&path);
        assert_eq!(frames.iter().map(|f| f.0).collect::<Vec<_>>(), vec![10, 5]);
    }

    #[test]
    fn rejects_wrong_size_and_handles_empty() {
        let path = tmp("err.gif");
        let mut w = GifWriter::create(&path, 64, 36).unwrap();
        assert!(w.push(&RgbaImage::new(10, 10), 0.1).is_err());
        assert_eq!(w.finish().unwrap(), 0);
        assert!(GifWriter::create(&path, 0, 10).is_err());
        assert!(GifWriter::create(&path, 70000, 10).is_err());
    }
}
