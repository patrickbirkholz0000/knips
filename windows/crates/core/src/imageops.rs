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

/// PNG verlustfrei; JPEG mit Qualität 85 (Schrift bleibt scharf), Transparenz auf Weiß.
pub fn encode(img: &RgbaImage, format: ImageFormat) -> Result<Vec<u8>> {
    let (w, h) = img.dimensions();
    let opaque = img.as_raw().chunks_exact(4).all(|p| p[3] == 255);
    let mut out = Vec::new();
    match format {
        ImageFormat::Png => {
            // Schnelle Kompression: ein 4K-PNG darf weder Karte noch Overlay aufhalten.
            let enc = PngEncoder::new_with_quality(&mut out, CompressionType::Fast, FilterType::Adaptive);
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
