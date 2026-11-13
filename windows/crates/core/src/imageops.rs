//! Bildoperationen (ImageIOHelper in Utilities.swift). Kanonisches Format: `RgbaImage`
//! (8 Bit, nicht vormultipliziert, sRGB).

#![allow(clippy::chunks_exact_to_as_chunks)] // Rust-Version offen halten: kein `as_chunks`


use anyhow::{anyhow, Result};
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::{CompressionType, FilterType, PngEncoder};
use image::{ExtendedColorType, ImageEncoder};

use crate::geometry::IRect;
use crate::model::ImageFormat;
use crate::RgbaImage;

/// Gewichte einer Achse für exaktes Flächenmitteln (Box-Filter mit Bruchteilen): je Ausgabepixel
/// der erste Eingabeindex und die Gewichte (Summe 1).
pub(crate) fn axis_weights(input: usize, output: usize) -> Vec<(usize, Vec<f32>)> {
    let scale = input as f64 / output as f64;
    (0..output)
        .map(|i| {
            let a = i as f64 * scale;
            let b = (i + 1) as f64 * scale;
            let first = a.floor() as usize;
            let last = ((b.ceil() as usize).max(first + 1)).min(input);
            let mut w: Vec<f32> = (first..last)
                .map(|k| {
                    let lo = a.max(k as f64);
                    let hi = b.min(k as f64 + 1.0);
                    ((hi - lo).max(0.0) / scale) as f32
                })
                .collect();
            let sum: f32 = w.iter().sum();
            if sum > 0.0 {
                for v in &mut w {
                    *v /= sum;
                }
            }
            (first.min(input - 1), w)
        })
        .collect()
}

/// Flächenmittel auf `ow`×`oh` (hohe Qualität beim Verkleinern; Alpha-gewichtet). Zeilenweise
/// gestreamt: kein großes Zwischenbild, ein 4K-Bild braucht ~30 ms im Release-Build.
pub(crate) fn resample_rgba(img: &RgbaImage, ow: u32, oh: u32) -> RgbaImage {
    let (iw, ih) = (img.width() as usize, img.height() as usize);
    let (ow_, oh_) = (ow as usize, oh as usize);
    if iw == ow_ && ih == oh_ {
        return img.clone();
    }
    let xw = axis_weights(iw, ow_);
    let yw = axis_weights(ih, oh_);
    let src = img.as_raw();
    let mut out = vec![0u8; ow_ * oh_ * 4];
    let mut acc = vec![0f32; iw * 4];
    for (oy, (y0, wy)) in yw.iter().enumerate() {
        acc.fill(0.0);
        for (k, &w) in wy.iter().enumerate() {
            let row = &src[(y0 + k) * iw * 4..(y0 + k + 1) * iw * 4];
            for (a, p) in acc.chunks_exact_mut(4).zip(row.chunks_exact(4)) {
                let wa = w * p[3] as f32;
                a[0] += p[0] as f32 * wa;
                a[1] += p[1] as f32 * wa;
                a[2] += p[2] as f32 * wa;
                a[3] += wa;
            }
        }
        let orow = &mut out[oy * ow_ * 4..(oy + 1) * ow_ * 4];
        for (o, (x0, wx)) in orow.chunks_exact_mut(4).zip(xw.iter()) {
            let (mut r, mut g, mut b, mut a) = (0f32, 0f32, 0f32, 0f32);
            for (k, &w) in wx.iter().enumerate() {
                let p = &acc[(x0 + k) * 4..(x0 + k) * 4 + 4];
                r += p[0] * w;
                g += p[1] * w;
                b += p[2] * w;
                a += p[3] * w;
            }
            if a > 0.0 {
                o[0] = (r / a + 0.5).min(255.0) as u8;
                o[1] = (g / a + 0.5).min(255.0) as u8;
                o[2] = (b / a + 0.5).min(255.0) as u8;
                o[3] = (a + 0.5).min(255.0) as u8;
            }
        }
    }
    RgbaImage::from_raw(ow, oh, out).expect("Größe stimmt")
}

/// Graustufen-Flächenmittel (Luma 0,30/0,59/0,11) auf `ow`×`oh`, Zeile für Zeile oben nach unten.
pub(crate) fn resample_gray(img: &RgbaImage, ow: u32, oh: u32) -> Vec<u8> {
    let (iw, ih) = (img.width() as usize, img.height() as usize);
    let (ow_, oh_) = (ow as usize, oh as usize);
    if iw == 0 || ih == 0 || ow_ == 0 || oh_ == 0 {
        return vec![0; ow_ * oh_];
    }
    let xw = if iw == ow_ { Vec::new() } else { axis_weights(iw, ow_) };
    let yw = axis_weights(ih, oh_);
    let src = img.as_raw();
    let mut out = vec![0u8; ow_ * oh_];
    let mut acc = vec![0f32; iw];
    let luma = |p: &[u8]| ((77 * p[0] as u32 + 151 * p[1] as u32 + 28 * p[2] as u32) as f32) / 256.0;
    for (oy, (y0, wy)) in yw.iter().enumerate() {
        acc.fill(0.0);
        for (k, &w) in wy.iter().enumerate() {
            let row = &src[(y0 + k) * iw * 4..(y0 + k + 1) * iw * 4];
            for (a, p) in acc.iter_mut().zip(row.chunks_exact(4)) {
                *a += luma(p) * w;
            }
        }
        let orow = &mut out[oy * ow_..(oy + 1) * ow_];
        if xw.is_empty() {
            for (o, a) in orow.iter_mut().zip(&acc) {
                *o = (a + 0.5).min(255.0) as u8;
            }
        } else {
            for (o, (x0, wx)) in orow.iter_mut().zip(xw.iter()) {
                let s: f32 = wx.iter().enumerate().map(|(k, w)| acc[x0 + k] * w).sum();
                *o = (s + 0.5).min(255.0) as u8;
            }
        }
    }
    out
}

/// Auf `factor` (< 1) verkleinern, z. B. volle Auflösung → Bildschirmgröße (1×). Hohe Qualität.
/// Neue Maße: gerundet, mindestens 1. Bei `factor >= 0.999` unverändert (Kopie).
pub fn scaled(img: &RgbaImage, factor: f64) -> RgbaImage {
    if factor >= 0.999 || img.width() == 0 || img.height() == 0 {
        return img.clone();
    }
    let w = ((img.width() as f64 * factor).round() as u32).max(1);
    let h = ((img.height() as f64 * factor).round() as u32).max(1);
    resample_rgba(img, w, h)
}

/// Längste Kante auf höchstens `max_pixel` verkleinern (Vorschaubilder 640, Texterkennung 2048).
pub fn downscale(img: &RgbaImage, max_pixel: u32) -> RgbaImage {
    let longest = img.width().max(img.height());
    if longest <= max_pixel || max_pixel == 0 {
        return img.clone();
    }
    let f = max_pixel as f64 / longest as f64;
    let w = ((img.width() as f64 * f) as u32).max(1);
    let h = ((img.height() as f64 * f) as u32).max(1);
    resample_rgba(img, w, h)
}

/// PNG verlustfrei; JPEG mit Qualität 85 (Schrift bleibt scharf), Transparenz auf Weiß. PNG mit schneller
/// Kompression: Original und Vorschaubild dürfen weder Karte noch Overlay aufhalten.
pub fn encode(img: &RgbaImage, format: ImageFormat) -> Result<Vec<u8>> {
    encode_with(img, format, CompressionType::Fast)
}

/// Wie `encode`, PNG aber dichter gepackt — für die Datei im Ablageordner. Gleiche Pixel, rund 30 % kleiner
/// (gemessen 13.11.2026 an 40 Aufnahmen: 54,6 → 38,0 MB), dafür im Schnitt 0,14 s statt 0,01 s im Hintergrund.
/// Noch dichter („Best“) brächte 1 % mehr und dauerte dreimal so lang.
pub fn encode_compact(img: &RgbaImage, format: ImageFormat) -> Result<Vec<u8>> {
    encode_with(img, format, CompressionType::Default)
}

/// Mindestgüte der Farbreduktion nach dem Maß von libimagequant (0–100). Darunter — Fotos, Videobilder — sähe man
/// Körnung; dann gibt es kein Farbtabellen-PNG.
pub const PALETTE_MIN_QUALITY: u8 = 85;
/// Größere Bilder (sehr lange Scroll-Screenshots) bleiben bei der bisherigen Ausgabe.
pub const PALETTE_MAX_PIXELS: u64 = 40_000_000;

/// PNG in voller Auflösung mit höchstens 256 Farben (Farbtabelle statt drei Bytes je Pixel) — die Ausgabe
/// „Automatisch“ (`Settings::reduces_colors`). Die Farben wählt libimagequant, mit feinem Raster an Verläufen;
/// Durchsicht bleibt erhalten. `None`: 256 Farben reichen nicht, ohne dass man es sähe, oder das Bild ist zu groß —
/// dann nimmt der Aufrufer die bisherige Ausgabe. Gemessen an 80 echten Aufnahmen (Mac-Fassung, gleiche
/// Einstellungen): 76 bestehen die Schwelle, Abstand zum Original im Mittel 56 dB und nie unter 40 dB.
pub fn encode_palette(img: &RgbaImage) -> Option<Vec<u8>> {
    encode_palette_with(img, PALETTE_MIN_QUALITY)
}

pub(crate) fn encode_palette_with(img: &RgbaImage, min_quality: u8) -> Option<Vec<u8>> {
    let (w, h) = img.dimensions();
    if w == 0 || h == 0 || w as u64 * h as u64 > PALETTE_MAX_PIXELS {
        return None;
    }
    let mut attr = imagequant::new();
    attr.set_speed(4).ok()?;
    attr.set_quality(min_quality, 100).ok()?;
    let pixels: Vec<imagequant::RGBA> = img.as_raw().chunks_exact(4).map(|p| imagequant::RGBA::new(p[0], p[1], p[2], p[3])).collect();
    let mut image = attr.new_image(pixels, w as usize, h as usize, 0.0).ok()?;
    // Unter der Mindestgüte bricht libimagequant hier ab.
    let mut result = attr.quantize(&mut image).ok()?;
    result.set_dithering_level(1.0).ok()?;
    let (palette, indices) = result.remapped(&mut image).ok()?;
    if palette.is_empty() || palette.len() > 256 {
        return None;
    }
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, w, h);
        enc.set_color(png::ColorType::Indexed);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_palette(palette.iter().flat_map(|c| [c.r, c.g, c.b]).collect::<Vec<u8>>());
        if let Some(last) = palette.iter().rposition(|c| c.a < 255) {
            enc.set_trns(palette[..=last].iter().map(|c| c.a).collect::<Vec<u8>>());
        }
        // Ohne Zeilenfilter: bei Farbtabellen packt das am besten.
        enc.set_compression(png::Compression::High);
        enc.set_filter(png::Filter::NoFilter);
        let mut writer = enc.write_header().ok()?;
        writer.write_image_data(&indices).ok()?;
        writer.finish().ok()?;
    }
    Some(out)
}

fn encode_with(img: &RgbaImage, format: ImageFormat, compression: CompressionType) -> Result<Vec<u8>> {
    let (w, h) = img.dimensions();
    let opaque = img.as_raw().chunks_exact(4).all(|p| p[3] == 255);
    let mut out = Vec::new();
    match format {
        ImageFormat::Png => {
            let enc = PngEncoder::new_with_quality(&mut out, compression, FilterType::Adaptive);
            if opaque {
                let rgb: Vec<u8> = img.as_raw().chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
                enc.write_image(&rgb, w, h, ExtendedColorType::Rgb8)?;
            } else {
                enc.write_image(img.as_raw(), w, h, ExtendedColorType::Rgba8)?;
            }
        }
        ImageFormat::Jpeg => {
            let mut rgb = Vec::with_capacity((w * h * 3) as usize);
            for p in img.as_raw().chunks_exact(4) {
                let a = p[3] as u32;
                for &c in &p[..3] {
                    rgb.push(((c as u32 * a + 255 * (255 - a) + 127) / 255) as u8);
                }
            }
            JpegEncoder::new_with_quality(&mut out, 85).write_image(&rgb, w, h, ExtendedColorType::Rgb8)?;
        }
    }
    Ok(out)
}

/// PNG/JPEG/GIF (erstes Bild)/BMP-Bytes → RGBA.
pub fn decode(bytes: &[u8]) -> Result<RgbaImage> {
    let img = image::load_from_memory(bytes).map_err(|e| anyhow!("Bild nicht lesbar: {e}"))?;
    Ok(img.to_rgba8())
}

pub fn load(path: &std::path::Path) -> Result<RgbaImage> {
    decode(&std::fs::read(path)?)
}

/// Ausschnitt in Pixeln; auf das Bild begrenzt. `None`, wenn nichts übrig bleibt.
pub fn crop(img: &RgbaImage, rect: IRect) -> Option<RgbaImage> {
    let full = IRect::new(0, 0, img.width() as i32, img.height() as i32);
    let r = rect.intersection(&full)?;
    let (w, h) = (r.width as usize, r.height as usize);
    let stride = img.width() as usize * 4;
    let mut out = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        let start = (r.y as usize + y) * stride + r.x as usize * 4;
        out.extend_from_slice(&img.as_raw()[start..start + w * 4]);
    }
    RgbaImage::from_raw(w as u32, h as u32, out)
}

/// BGRA-Zeilen (z. B. aus Direct3D, `stride` Bytes pro Zeile) → RGBA. Alpha wird auf 255 gesetzt,
/// wenn `opaque`.
pub fn from_bgra(width: u32, height: u32, stride: usize, bgra: &[u8], opaque: bool) -> RgbaImage {
    let (w, h) = (width as usize, height as usize);
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        let Some(row) = bgra.get(y * stride..y * stride + w * 4) else { break };
        let dst = &mut out[y * w * 4..(y + 1) * w * 4];
        for (d, s) in dst.chunks_exact_mut(4).zip(row.chunks_exact(4)) {
            d[0] = s[2];
            d[1] = s[1];
            d[2] = s[0];
            d[3] = if opaque { 255 } else { s[3] };
        }
    }
    RgbaImage::from_raw(width, height, out).expect("Größe stimmt")
}

/// Helligkeit eines Bildes (oder Ausschnitts) aus einem Raster von Stichproben.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Brightness {
    /// Mittlere Helligkeit 0…255 (Rec. 601).
    pub mean: f64,
    /// Anteil fast schwarzer Pixel (alle Kanäle ≤ 8), 0…1.
    pub black: f64,
}

impl Brightness {
    /// Kein Inhalt: so gut wie jedes Pixel schwarz. Ein echter Bildschirm hat fast immer etwas Helles
    /// (Taskleiste, Text, Symbole); ganz schwarz ist er nur bei einem leeren Bild der Aufnahme.
    pub fn is_blank(&self) -> bool {
        self.black > 0.995
    }
}

/// Helligkeit im Ausschnitt `rect` (ganzes Bild bei `None`), jedes `step`-te Pixel in beiden Richtungen.
pub fn brightness(img: &RgbaImage, rect: Option<IRect>, step: u32) -> Brightness {
    let full = IRect::new(0, 0, img.width() as i32, img.height() as i32);
    let Some(r) = rect.map_or(Some(full), |r| r.intersection(&full)) else { return Brightness { mean: 0.0, black: 1.0 } };
    let step = step.max(1) as usize;
    let (mut sum, mut black, mut n) = (0f64, 0u64, 0u64);
    for y in (r.y as u32..r.bottom() as u32).step_by(step) {
        for x in (r.x as u32..r.right() as u32).step_by(step) {
            let p = img.get_pixel(x, y).0;
            sum += 0.299 * p[0] as f64 + 0.587 * p[1] as f64 + 0.114 * p[2] as f64;
            if p[0] <= 8 && p[1] <= 8 && p[2] <= 8 {
                black += 1;
            }
            n += 1;
        }
    }
    if n == 0 {
        return Brightness { mean: 0.0, black: 1.0 };
    }
    Brightness { mean: sum / n as f64, black: black as f64 / n as f64 }
}

/// RGBA → BGRA (dicht gepackt), z. B. für Zwischenablage-DIBs und Media Foundation.
pub fn to_bgra(img: &RgbaImage) -> Vec<u8> {
    let mut out = img.as_raw().clone();
    for p in out.chunks_exact_mut(4) {
        p.swap(0, 2);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;

    fn gradient(w: u32, h: u32) -> RgbaImage {
        RgbaImage::from_fn(w, h, |x, y| Rgba([(x * 255 / w.max(1)) as u8, (y * 255 / h.max(1)) as u8, 90, 255]))
    }

    /// Wie ein Bildschirmfoto: Flächen, Linien und „Text“ aus wenigen Farben, dazu ein Verlauf.
    fn screen_like(w: u32, h: u32) -> RgbaImage {
        RgbaImage::from_fn(w, h, |x, y| {
            if y < h / 6 {
                Rgba([(x * 255 / w) as u8, 120, 200, 255])
            } else if (y / 14) % 2 == 0 && (x * 7 + y * 3) % 11 < 4 {
                Rgba([30, 30, 34, 255])
            } else {
                Rgba([250, 250, 252, 255])
            }
        })
    }

    /// Wie ein Foto: Verläufe in allen Farben mit Rauschen — mit 256 Farben nicht darstellbar.
    fn photo_like(w: u32, h: u32) -> RgbaImage {
        let mut seed = 12345u32;
        RgbaImage::from_fn(w, h, |x, y| {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let noise = (seed >> 24) % 40;
            Rgba([(x * 255 / w + noise / 2).min(255) as u8, (y * 255 / h + noise / 3).min(255) as u8, (((x + y) * 255 / (w + h)) ^ (noise * 3)).min(255) as u8, 255])
        })
    }

    fn psnr(a: &RgbaImage, b: &RgbaImage) -> f64 {
        let sum: f64 = a.as_raw().iter().zip(b.as_raw()).map(|(x, y)| (*x as f64 - *y as f64).powi(2)).sum();
        let mse = sum / a.as_raw().len() as f64;
        if mse == 0.0 { 99.0 } else { 10.0 * (255.0f64 * 255.0 / mse).log10() }
    }

    /// Ausgabe „Automatisch“: Farbtabellen-PNG für Oberflächen, kein Ergebnis für Fotos, Durchsicht bleibt.
    #[test]
    fn palette_png_for_screens_not_for_photos() {
        let img = screen_like(640, 400);
        let data = encode_palette(&img).expect("Oberfläche: Farbtabelle");
        // Kopf: Farbtyp 3 (Farbtabelle), 8 Bit.
        assert_eq!((data[24], data[25]), (8, 3));
        let back = decode(&data).unwrap();
        assert_eq!(back.dimensions(), img.dimensions());
        assert!(psnr(&back, &img) >= 40.0, "Abstand {:.1} dB", psnr(&back, &img));
        let lossless = encode_compact(&img, ImageFormat::Png).unwrap();
        assert!(data.len() < lossless.len(), "Farbtabelle {} ≥ verlustfrei {}", data.len(), lossless.len());

        let photo = photo_like(600, 400);
        assert!(encode_palette(&photo).is_none(), "Foto: 256 Farben reichen nicht");
        assert!(encode_palette_with(&photo, 0).is_some(), "ohne Mindestgüte gelingt es");

        // Durchsichtige Ecke bleibt durchsichtig.
        let mut clear = screen_like(200, 120);
        for y in 0..20 {
            for x in 0..20 {
                clear.put_pixel(x, y, Rgba([0, 0, 0, 0]));
            }
        }
        let back = decode(&encode_palette(&clear).expect("mit Durchsicht")).unwrap();
        assert_eq!(back.get_pixel(5, 5)[3], 0);
        assert_eq!(back.get_pixel(100, 100)[3], 255);
    }

    /// Dichter gepacktes PNG (Datei im Ablageordner): dieselben Pixel, kleiner als die schnelle Fassung.
    #[test]
    fn compact_png_is_smaller_and_lossless() {
        // Wie ein Bildschirmfoto: Flächen, Linien und „Text“ aus wenigen Farben, dazu ein Verlauf.
        let img = RgbaImage::from_fn(640, 400, |x, y| {
            if y < 60 {
                Rgba([(x * 255 / 640) as u8, 120, 200, 255])
            } else if (y / 14) % 2 == 0 && (x * 7 + y * 3) % 11 < 4 {
                Rgba([30, 30, 34, 255])
            } else {
                Rgba([250, 250, 252, 255])
            }
        });
        let fast = encode(&img, ImageFormat::Png).unwrap();
        let compact = encode_compact(&img, ImageFormat::Png).unwrap();
        assert!(compact.len() < fast.len(), "dicht {} ≥ schnell {}", compact.len(), fast.len());
        assert_eq!(decode(&compact).unwrap().as_raw(), img.as_raw());
        assert_eq!(decode(&fast).unwrap().as_raw(), img.as_raw());
        // Mit Durchsicht bleibt der Alphakanal.
        let mut clear = img.clone();
        clear.put_pixel(0, 0, Rgba([0, 0, 0, 0]));
        assert_eq!(decode(&encode_compact(&clear, ImageFormat::Png).unwrap()).unwrap().as_raw(), clear.as_raw());
    }

    #[test]
    fn scaled_sizes() {
        let img = gradient(3840, 2160);
        let s = scaled(&img, 0.5);
        assert_eq!(s.dimensions(), (1920, 1080));
        let s = scaled(&gradient(101, 51), 0.5);
        assert_eq!(s.dimensions(), (51, 26)); // 50,5 → 51; 25,5 → 26
        assert_eq!(scaled(&img, 1.0).dimensions(), (3840, 2160));
        assert_eq!(scaled(&img, 0.9995).dimensions(), (3840, 2160));
        assert_eq!(scaled(&gradient(3, 3), 0.01).dimensions(), (1, 1));
    }

    #[test]
    fn scaled_keeps_flat_colour_and_average() {
        let img = RgbaImage::from_pixel(400, 200, Rgba([10, 120, 250, 255]));
        let s = scaled(&img, 0.37);
        assert!(s.pixels().all(|p| *p == Rgba([10, 120, 250, 255])));
        // Schachbrett → Mittelgrau
        let chk = RgbaImage::from_fn(64, 64, |x, y| if (x + y) % 2 == 0 { Rgba([0, 0, 0, 255]) } else { Rgba([255, 255, 255, 255]) });
        let s = scaled(&chk, 0.5);
        assert!(s.pixels().all(|p| (p[0] as i32 - 128).abs() <= 1));
    }

    #[test]
    fn downscale_longest_edge() {
        let img = gradient(4000, 1000);
        let d = downscale(&img, 2048);
        assert_eq!(d.dimensions(), (2048, 512));
        let d = downscale(&gradient(1000, 3000), 640);
        assert_eq!(d.dimensions(), (213, 640));
        assert_eq!(downscale(&img, 4000).dimensions(), (4000, 1000));
        assert_eq!(downscale(&img, 5000).dimensions(), (4000, 1000));
    }

    #[test]
    fn png_round_trip_and_jpeg() {
        let img = gradient(120, 80);
        let png = encode(&img, ImageFormat::Png).unwrap();
        assert_eq!(&png[1..4], b"PNG");
        assert_eq!(decode(&png).unwrap(), img);
        let mut alpha = img.clone();
        alpha.put_pixel(3, 3, Rgba([1, 2, 3, 100]));
        assert_eq!(decode(&encode(&alpha, ImageFormat::Png).unwrap()).unwrap(), alpha);
        let jpg = encode(&img, ImageFormat::Jpeg).unwrap();
        assert_eq!(&jpg[..2], &[0xFF, 0xD8]);
        let back = decode(&jpg).unwrap();
        assert_eq!(back.dimensions(), (120, 80));
        let diff: u64 = back.pixels().zip(img.pixels()).map(|(a, b)| (a[0] as i32 - b[0] as i32).unsigned_abs() as u64).sum();
        assert!(diff / (120 * 80) < 6);
    }

    #[test]
    fn jpeg_flattens_on_white() {
        let img = RgbaImage::from_pixel(32, 32, Rgba([0, 0, 0, 0]));
        let back = decode(&encode(&img, ImageFormat::Jpeg).unwrap()).unwrap();
        assert!(back.pixels().all(|p| p[0] > 245 && p[1] > 245 && p[2] > 245));
    }

    #[test]
    fn brightness_and_blank() {
        let black = RgbaImage::from_pixel(64, 48, Rgba([0, 0, 0, 255]));
        let b = brightness(&black, None, 4);
        assert_eq!(b.mean, 0.0);
        assert!(b.is_blank());
        let white = RgbaImage::from_pixel(64, 48, Rgba([255, 255, 255, 255]));
        let b = brightness(&white, None, 1);
        assert!((b.mean - 255.0).abs() < 0.01 && b.black == 0.0 && !b.is_blank());
        // Dunkle Fläche mit heller Leiste (wie ein dunkler Desktop mit Taskleiste) ist nicht leer.
        let mut desk = RgbaImage::from_pixel(100, 100, Rgba([3, 3, 3, 255]));
        for x in 0..100 {
            for y in 90..100 {
                desk.put_pixel(x, y, Rgba([40, 40, 48, 255]));
            }
        }
        let b = brightness(&desk, None, 1);
        assert!((b.black - 0.9).abs() < 1e-9 && !b.is_blank());
        // Ausschnitt: nur die Leiste
        let b = brightness(&desk, Some(IRect::new(0, 90, 100, 10)), 1);
        assert_eq!(b.black, 0.0);
        // Ausschnitt außerhalb → leer
        assert!(brightness(&desk, Some(IRect::new(200, 200, 10, 10)), 1).is_blank());
    }

    #[test]
    fn decode_rejects_garbage() {
        assert!(decode(b"kein bild").is_err());
    }

    #[test]
    fn crop_clamps() {
        let img = gradient(100, 50);
        let c = crop(&img, IRect::new(10, 5, 20, 10)).unwrap();
        assert_eq!(c.dimensions(), (20, 10));
        assert_eq!(c.get_pixel(0, 0), img.get_pixel(10, 5));
        assert_eq!(c.get_pixel(19, 9), img.get_pixel(29, 14));
        let c = crop(&img, IRect::new(-10, -10, 30, 30)).unwrap();
        assert_eq!(c.dimensions(), (20, 20));
        let c = crop(&img, IRect::new(90, 40, 50, 50)).unwrap();
        assert_eq!(c.dimensions(), (10, 10));
        assert!(crop(&img, IRect::new(200, 0, 10, 10)).is_none());
        assert!(crop(&img, IRect::new(0, 0, 0, 10)).is_none());
    }

    #[test]
    fn bgra_round_trip() {
        let img = gradient(7, 5);
        let bgra = to_bgra(&img);
        assert_eq!(bgra[0], img.get_pixel(0, 0)[2]);
        assert_eq!(from_bgra(7, 5, 28, &bgra, false), img);
        // Stride mit Füllbytes, Alpha erzwingen
        let mut padded = Vec::new();
        for row in bgra.chunks(28) {
            padded.extend_from_slice(row);
            padded.extend_from_slice(&[9, 9, 9, 9]);
        }
        let mut transparent = padded.clone();
        for p in transparent.chunks_exact_mut(4) {
            p[3] = 0;
        }
        let out = from_bgra(7, 5, 32, &transparent, true);
        assert!(out.pixels().all(|p| p[3] == 255));
        assert_eq!(out.get_pixel(6, 4)[0], img.get_pixel(6, 4)[0]);
    }

    #[test]
    #[ignore]
    fn perf_scaled() {
        let img = gradient(3840, 2160);
        for _ in 0..2 {
            let t = std::time::Instant::now();
            let s = scaled(&img, 0.5);
            println!("scaled 4K -> 1x: {:?}", t.elapsed());
            let t = std::time::Instant::now();
            let _ = downscale(&img, 2048);
            println!("downscale 4K -> 2048: {:?}", t.elapsed());
            let t = std::time::Instant::now();
            let _ = downscale(&img, 640);
            println!("downscale 4K -> 640: {:?}", t.elapsed());
            let t = std::time::Instant::now();
            let png = encode(&s, ImageFormat::Png).unwrap();
            println!("png 1080p: {:?} {} KB", t.elapsed(), png.len() / 1024);
            let t = std::time::Instant::now();
            let png = encode(&img, ImageFormat::Png).unwrap();
            println!("png 4K: {:?} {} KB", t.elapsed(), png.len() / 1024);
            let t = std::time::Instant::now();
            let _ = encode(&img, ImageFormat::Jpeg).unwrap();
            println!("jpeg 4K: {:?}", t.elapsed());
        }
    }
}
