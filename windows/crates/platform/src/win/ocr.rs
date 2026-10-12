//! Texterkennung mit Windows.Media.Ocr (lokal). Port von `TextLayout.lines` /
//! `SensitiveDetector.detectSync` (Vorbereitung): verkleinern, erkennen, auf Quellpixel zurückrechnen.

use std::sync::OnceLock;

use anyhow::{anyhow, Result};
use knips_core::model::{TextLine, TextWord};
use knips_core::{geometry::Rect, RgbaImage};
use windows::core::HSTRING;
use windows::Globalization::Language;
use windows::Graphics::Imaging::{BitmapPixelFormat, SoftwareBitmap};
use windows::Media::Ocr::OcrEngine;
use windows::Storage::Streams::DataWriter;

use super::util::init_com;

struct Engine(OcrEngine);

// SAFETY: OcrEngine ist ein agiles WinRT-Objekt (MTA); RecognizeAsync darf von mehreren Threads laufen.
unsafe impl Send for Engine {}
unsafe impl Sync for Engine {}

/// Engine einmal anlegen: Profilsprachen, sonst Deutsch, sonst Englisch.
fn engine() -> Option<&'static OcrEngine> {
    static ENGINE: OnceLock<Option<Engine>> = OnceLock::new();
    init_com();
    ENGINE
        .get_or_init(|| {
            if let Ok(e) = OcrEngine::TryCreateFromUserProfileLanguages() {
                return Some(Engine(e));
            }
            for tag in ["de-DE", "en-US"] {
                if let Ok(lang) = Language::CreateLanguage(&HSTRING::from(tag)) {
                    if let Ok(e) = OcrEngine::TryCreateFromLanguage(&lang) {
                        return Some(Engine(e));
                    }
                }
            }
            log::warn!("Keine Windows-Texterkennung verfügbar (Sprachpaket fehlt?)");
            None
        })
        .as_ref()
        .map(|e| &e.0)
}

/// Texterkennung (lokal). Verkleinert intern auf ≤ 2048 px und rechnet zurück; Zeilen in
/// Lesereihenfolge, `TextLine.text` = Wörter mit Leerzeichen.
pub fn recognize(img: &RgbaImage) -> Result<Vec<TextLine>> {
    let engine = engine().ok_or_else(|| anyhow!("Texterkennung nicht verfügbar"))?;
    if img.width() == 0 || img.height() == 0 {
        return Ok(vec![]);
    }
    let engine_max = OcrEngine::MaxImageDimension().unwrap_or(2600).max(64);
    let limit = knips_core::OCR_MAX_PIXEL.min(engine_max);
    let small;
    let src: &RgbaImage = if img.width().max(img.height()) > limit {
        small = knips_core::imageops::downscale(img, limit);
        &small
    } else {
        img
    };
    let (w, h) = (src.width(), src.height());
    let sx = img.width() as f64 / w as f64;
    let sy = img.height() as f64 / h as f64;

    // RGBA → BGRA, opak (OCR ignoriert Alpha, Premultiplied soll keine Farben verfälschen).
    let mut bgra = Vec::with_capacity(w as usize * h as usize * 4);
    for p in src.pixels() {
        bgra.extend_from_slice(&[p[2], p[1], p[0], 255]);
    }
    let writer = DataWriter::new()?;
    writer.WriteBytes(&bgra)?;
    let buffer = writer.DetachBuffer()?;
    let bitmap = SoftwareBitmap::CreateCopyFromBuffer(&buffer, BitmapPixelFormat::Bgra8, w as i32, h as i32)?;
    let result = engine.RecognizeAsync(&bitmap)?.join()?;

    let mut lines = Vec::new();
    for line in result.Lines()? {
        let mut words = Vec::new();
        for word in line.Words()? {
            let text = word.Text()?.to_string();
            if text.trim().is_empty() {
                continue;
            }
            let r = word.BoundingRect()?;
            words.push(TextWord {
                text,
                rect: Rect::new(r.X as f64 * sx, r.Y as f64 * sy, r.Width as f64 * sx, r.Height as f64 * sy),
            });
        }
        if !words.is_empty() {
            lines.push(TextLine::from_words(words));
        }
    }
    knips_core::textlayout::sort_reading_order(&mut lines);
    Ok(lines)
}

pub fn available() -> bool {
    engine().is_some()
}
