//! Zensur auf Pixeln — für Videobilder (`VideoRedactor.apply`). Bilder rendert der Editor selbst
//! (`src/editor/renderer.ts`) mit denselben Parametern.

#![allow(clippy::chunks_exact_to_as_chunks)] // Rust-Version offen halten: kein `as_chunks`


use std::sync::OnceLock;

use crate::geometry::{IRect, Rect};
use crate::model::RedactStyle;
use crate::RgbaImage;

/// Blockgröße beim Verpixeln: 12 pt, mindestens 10 px (`EffectsCache.pixelBlock`).
pub fn pixel_block(scale: f64) -> u32 {
    (12.0 * scale).round().max(10.0) as u32
}

/// Radius der Unschärfe: 14 pt (`CIGaussianBlur` mit `14 * scale`).
pub fn blur_radius(scale: f64) -> f64 {
    14.0 * scale
}

/// Farbe des Balkens: Grau 0,06 (≈ 15/255).
pub const SOLID: [u8; 3] = [15, 15, 15];

/// Felder in Pixeln (Ursprung oben links) zensieren. Verpixeln: Blockraster ab Bildursprung (0,0),
/// Blockfarbe = Mittelwert. Unschärfe: Gauß (oder 3× Boxfilter) mit Rand-Klemmung am Bildrand,
/// Quelle ist das unveränderte Bild (überlappende Felder beeinflussen sich nicht).
///
/// Gerechnet wird nur im Feld (bei Unschärfe plus Rand), nicht auf dem ganzen Bild — so reicht es
/// pro Videobild in 1080p bis 4K.
pub fn apply(frame: &mut RgbaImage, regions: &[(Rect, RedactStyle)], scale: f64) {
    let (fw, fh) = (frame.width() as i32, frame.height() as i32);
    let bounds = IRect::new(0, 0, fw, fh);
    let block = pixel_block(scale);
    let sigma = blur_radius(scale);
    // Alle Flicken zuerst aus dem unveränderten Bild berechnen, danach der Reihe nach auflegen.
    let mut patches: Vec<(IRect, Option<Vec<u8>>)> = Vec::new();
    for (rect, style) in regions {
        if rect.is_null() {
            continue;
        }
        let Some(ir) = bounds.intersection(&IRect::from_rect(rect)) else { continue };
        let patch = match style {
            RedactStyle::Pixelate => Some(pixelate_patch(frame, ir, block)),
            RedactStyle::Blur => Some(blur_patch(frame, ir, sigma)),
            RedactStyle::Solid => None,
        };
        patches.push((ir, patch));
    }
    let stride = fw as usize * 4;
    let raw: &mut [u8] = frame;
    for (ir, patch) in patches {
        let w = ir.width as usize;
        for row in 0..ir.height as usize {
            let off = (ir.y as usize + row) * stride + ir.x as usize * 4;
            let dst = &mut raw[off..off + w * 4];
            match &patch {
                Some(p) => dst.copy_from_slice(&p[row * w * 4..(row + 1) * w * 4]),
                None => {
                    for px in dst.chunks_exact_mut(4) {
                        px[0] = SOLID[0];
                        px[1] = SOLID[1];
                        px[2] = SOLID[2];
                        px[3] = 255;
                    }
                }
            }
        }
    }
}

/// Verpixelter Ausschnitt `ir` (liegt im Bild). Blöcke sitzen auf dem Raster ab (0,0) und werden
/// über den ganzen Block (am Bildrand abgeschnitten) gemittelt, nicht nur über den Ausschnitt.
fn pixelate_patch(src: &RgbaImage, ir: IRect, block: u32) -> Vec<u8> {
    let (iw, ih) = (src.width() as usize, src.height() as usize);
    let b = block as usize;
    let raw = src.as_raw();
    let (x0, y0, w, h) = (ir.x as usize, ir.y as usize, ir.width as usize, ir.height as usize);
    let mut out = vec![0u8; w * h * 4];
    for by in (y0 / b)..=((y0 + h - 1) / b) {
        let sy0 = by * b;
        let sy1 = (sy0 + b).min(ih);
        for bx in (x0 / b)..=((x0 + w - 1) / b) {
            let sx0 = bx * b;
            let sx1 = (sx0 + b).min(iw);
            let mut sum = [0u64; 4];
            for y in sy0..sy1 {
                for p in raw[(y * iw + sx0) * 4..(y * iw + sx1) * 4].chunks_exact(4) {
                    sum[0] += p[0] as u64;
                    sum[1] += p[1] as u64;
                    sum[2] += p[2] as u64;
                    sum[3] += p[3] as u64;
                }
            }
            let n = ((sy1 - sy0) * (sx1 - sx0)) as u64;
            let avg = [0, 1, 2, 3].map(|c| ((sum[c] + n / 2) / n) as u8);
            let (cx0, cx1) = (sx0.max(x0), sx1.min(x0 + w));
            let (cy0, cy1) = (sy0.max(y0), sy1.min(y0 + h));
            for y in cy0..cy1 {
                for x in cx0..cx1 {
                    let o = ((y - y0) * w + (x - x0)) * 4;
                    out[o..o + 4].copy_from_slice(&avg);
                }
            }
        }
    }
    out
}

/// Radien der drei Boxfilter, die zusammen einen Gauß mit `sigma` annähern (Kutskir).
fn box_radii(sigma: f64) -> [usize; 3] {
    let n = 3.0;
    let ideal = (12.0 * sigma * sigma / n + 1.0).sqrt();
    let mut wl = ideal.floor() as i64;
    if wl % 2 == 0 {
        wl -= 1;
    }
    let wl = wl.max(1);
    let wu = wl + 2;
    let m = ((12.0 * sigma * sigma - n * (wl * wl) as f64 - 4.0 * n * wl as f64 - 3.0 * n) / (-4.0 * wl as f64 - 4.0)).round() as i64;
    [0, 1, 2].map(|i| ((if (i as i64) < m { wl } else { wu } - 1) / 2) as usize)
}

/// Ein Boxfilter-Durchlauf waagerecht mit Randklemmung (4 Kanäle).
fn box_h(src: &[u8], dst: &mut [u8], w: usize, h: usize, r: usize) {
    if r == 0 {
        dst.copy_from_slice(src);
        return;
    }
    let div = (2 * r + 1) as u32;
    for y in 0..h {
        let row = &src[y * w * 4..(y + 1) * w * 4];
        let out = &mut dst[y * w * 4..(y + 1) * w * 4];
        for c in 0..4 {
            let at = |x: isize| row[(x.clamp(0, w as isize - 1) as usize) * 4 + c] as u32;
            let mut sum = at(0) * (r as u32 + 1);
            for k in 1..=r as isize {
                sum += at(k);
            }
            for x in 0..w as isize {
                out[x as usize * 4 + c] = ((sum + div / 2) / div) as u8;
                sum = sum + at(x + r as isize + 1) - at(x - r as isize);
            }
        }
    }
}

/// Wie `box_h`, senkrecht — zeilenweise, damit der Speicherzugriff linear bleibt.
fn box_v(src: &[u8], dst: &mut [u8], w: usize, h: usize, r: usize) {
    if r == 0 {
        dst.copy_from_slice(src);
        return;
    }
    let div = (2 * r + 1) as u32;
    let rowlen = w * 4;
    let mut sums = vec![0u32; rowlen];
    let row = |y: isize| {
        let y = y.clamp(0, h as isize - 1) as usize;
        &src[y * rowlen..(y + 1) * rowlen]
    };
    for (s, &v) in sums.iter_mut().zip(row(0)) {
        *s = v as u32 * (r as u32 + 1);
    }
    for k in 1..=r as isize {
        for (s, &v) in sums.iter_mut().zip(row(k)) {
            *s += v as u32;
        }
    }
    for y in 0..h as isize {
        let out = &mut dst[y as usize * rowlen..(y as usize + 1) * rowlen];
        let add = row(y + r as isize + 1);
        let sub = row(y - r as isize);
        for i in 0..rowlen {
            out[i] = ((sums[i] + div / 2) / div) as u8;
            sums[i] = sums[i] + add[i] as u32 - sub[i] as u32;
        }
    }
}

/// Unscharfer Ausschnitt `ir`: Boxfilter ×3 (≈ Gauß mit `sigma`) auf Ausschnitt plus Rand; die
/// Ränder werden an den Bildrändern geklemmt, innen reicht der Rand für exakte Werte.
fn blur_patch(src: &RgbaImage, ir: IRect, sigma: f64) -> Vec<u8> {
    let (iw, ih) = (src.width() as i32, src.height() as i32);
    let radii = if sigma < 0.5 { [0, 0, 0] } else { box_radii(sigma) };
    let margin = radii.iter().sum::<usize>() as i32 + 1;
    let area = IRect::new(0, 0, iw, ih).intersection(&IRect::new(ir.x - margin, ir.y - margin, ir.width + 2 * margin, ir.height + 2 * margin)).unwrap_or(ir);
    let (w, h) = (area.width as usize, area.height as usize);
    let raw = src.as_raw();
    let mut a = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        let o = ((area.y as usize + y) * iw as usize + area.x as usize) * 4;
        a.extend_from_slice(&raw[o..o + w * 4]);
    }
    let mut b = vec![0u8; a.len()];
    for &r in &radii {
        box_h(&a, &mut b, w, h, r);
        box_v(&b, &mut a, w, h, r);
    }
    let (ox, oy) = ((ir.x - area.x) as usize, (ir.y - area.y) as usize);
    let (pw, ph) = (ir.width as usize, ir.height as usize);
    let mut out = Vec::with_capacity(pw * ph * 4);
    for y in 0..ph {
        let o = ((oy + y) * w + ox) * 4;
        out.extend_from_slice(&a[o..o + pw * 4]);
    }
    out
}

/// Zensur-Fassungen eines Bildes (`EffectsCache`): verpixelt und unscharf, je einmal über das
/// ganze Bild berechnet und gemerkt. `Solid` braucht kein Bild (`None`).
pub struct EffectsCache {
    pub base: RgbaImage,
    pub scale: f64,
    pixelated: OnceLock<RgbaImage>,
    blurred: OnceLock<RgbaImage>,
}

impl EffectsCache {
    pub fn new(base: RgbaImage, scale: f64) -> Self {
        Self { base, scale, pixelated: OnceLock::new(), blurred: OnceLock::new() }
    }

    pub fn pixel_block(&self) -> u32 {
        pixel_block(self.scale)
    }

    pub fn image(&self, style: RedactStyle) -> Option<&RgbaImage> {
        let full = || IRect::new(0, 0, self.base.width() as i32, self.base.height() as i32);
        match style {
            RedactStyle::Solid => None,
            RedactStyle::Pixelate => Some(self.pixelated.get_or_init(|| {
                let (w, h) = self.base.dimensions();
                RgbaImage::from_raw(w, h, pixelate_patch(&self.base, full(), pixel_block(self.scale))).expect("Größe stimmt")
            })),
            RedactStyle::Blur => Some(self.blurred.get_or_init(|| {
                let (w, h) = self.base.dimensions();
                RgbaImage::from_raw(w, h, blur_patch(&self.base, full(), blur_radius(self.scale))).expect("Größe stimmt")
            })),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;

    fn noise(w: u32, h: u32) -> RgbaImage {
        let mut s = 7u64;
        RgbaImage::from_fn(w, h, |_, _| {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let v = (s >> 40) as u8;
            Rgba([v, v.wrapping_mul(3), v.wrapping_add(50), 255])
        })
    }

    #[test]
    fn constants() {
        assert_eq!(pixel_block(1.0), 12);
        assert_eq!(pixel_block(2.0), 24);
        assert_eq!(pixel_block(0.5), 10);
        assert_eq!(blur_radius(2.0), 28.0);
        assert_eq!(pixel_block(1.0), 12);
    }

    #[test]
    fn solid_fills_only_region() {
        let src = noise(100, 80);
        let mut f = src.clone();
        apply(&mut f, &[(Rect::new(10.4, 20.2, 30.0, 10.0), RedactStyle::Solid)], 1.0);
        // integral: x 10..41, y 20..31
        assert_eq!(f.get_pixel(10, 20), &Rgba([15, 15, 15, 255]));
        assert_eq!(f.get_pixel(40, 30), &Rgba([15, 15, 15, 255]));
        assert_eq!(f.get_pixel(41, 30), src.get_pixel(41, 30));
        assert_eq!(f.get_pixel(9, 20), src.get_pixel(9, 20));
        assert_eq!(f.get_pixel(20, 31), src.get_pixel(20, 31));
        assert_eq!(f.get_pixel(20, 19), src.get_pixel(20, 19));
    }

    #[test]
    fn pixelate_blocks_on_origin_grid_with_average() {
        let src = noise(100, 80);
        let mut f = src.clone();
        // Feld deckt Blöcke (12er Raster) 1..3 × 2..4 teilweise ab
        apply(&mut f, &[(Rect::new(15.0, 30.0, 20.0, 8.0), RedactStyle::Pixelate)], 1.0);
        // Block (1,2) = x 12..24, y 24..36: Mittelwert über den ganzen Block
        let mut sum = [0u32; 3];
        for y in 24..36 {
            for x in 12..24 {
                for (c, s) in sum.iter_mut().enumerate() {
                    *s += src.get_pixel(x, y)[c] as u32;
                }
            }
        }
        let want: Vec<u8> = sum.iter().map(|s| ((s + 72) / 144) as u8).collect();
        for &(x, y) in &[(15, 30), (23, 35), (20, 32)] {
            let p = f.get_pixel(x, y);
            assert_eq!([p[0], p[1], p[2]], [want[0], want[1], want[2]], "{x},{y}");
        }
        // innerhalb des Blocks konstant, außerhalb des Felds unverändert
        assert_eq!(f.get_pixel(15, 30), f.get_pixel(23, 35));
        assert_eq!(f.get_pixel(14, 30), src.get_pixel(14, 30));
        assert_eq!(f.get_pixel(15, 38), src.get_pixel(15, 38));
        assert_eq!(f.get_pixel(35, 30), src.get_pixel(35, 30));
        // benachbarter Block hat anderen Wert
        assert_ne!(f.get_pixel(15, 30), f.get_pixel(25, 30));
    }

    #[test]
    fn pixelate_at_image_edge_averages_clipped_block() {
        let src = noise(30, 30); // letzter Block 24..30 (6 px)
        let mut f = src.clone();
        apply(&mut f, &[(Rect::new(24.0, 24.0, 20.0, 20.0), RedactStyle::Pixelate)], 1.0);
        let mut sum = 0u32;
        for y in 24..30 {
            for x in 24..30 {
                sum += src.get_pixel(x, y)[0] as u32;
            }
        }
        assert_eq!(f.get_pixel(29, 29)[0], ((sum + 18) / 36) as u8);
    }

    #[test]
    fn blur_flat_stays_flat_and_smooths_edge() {
        let mut src = RgbaImage::from_pixel(120, 60, Rgba([200, 100, 50, 255]));
        let mut f = src.clone();
        apply(&mut f, &[(Rect::new(10.0, 10.0, 80.0, 40.0), RedactStyle::Blur)], 1.0);
        assert!(f.pixels().all(|p| *p == Rgba([200, 100, 50, 255])));
        // harte Kante: links schwarz, rechts weiß
        for y in 0..60 {
            for x in 0..120 {
                src.put_pixel(x, y, if x < 60 { Rgba([0, 0, 0, 255]) } else { Rgba([255, 255, 255, 255]) });
            }
        }
        let mut f = src.clone();
        apply(&mut f, &[(Rect::new(20.0, 10.0, 80.0, 40.0), RedactStyle::Blur)], 1.0);
        let at = |x| f.get_pixel(x, 30)[0] as i32;
        assert!((at(60) - 128).abs() <= 4, "Mitte der Kante ≈ 128, ist {}", at(60));
        assert!(at(52) > 5 && at(52) < at(60));
        assert!(at(68) < 250 && at(68) > at(60));
        assert!(at(25) <= 3); // weit weg von der Kante: fast unverändert
        assert_eq!(f.get_pixel(19, 30), src.get_pixel(19, 30));
    }

    #[test]
    fn blur_matches_gaussian_profile() {
        // Sprungantwort: Gauß-Φ((x-60)/σ), σ = 14
        let src = RgbaImage::from_fn(200, 40, |x, _| if x < 100 { Rgba([0, 0, 0, 255]) } else { Rgba([255, 255, 255, 255]) });
        let mut f = src.clone();
        apply(&mut f, &[(Rect::new(0.0, 0.0, 200.0, 40.0), RedactStyle::Blur)], 1.0);
        let phi = |z: f64| 0.5 * (1.0 + erf(z / std::f64::consts::SQRT_2));
        for x in [70usize, 85, 100, 115, 130] {
            let want = 255.0 * phi((x as f64 + 0.5 - 100.0) / 14.0);
            let got = f.get_pixel(x as u32, 20)[0] as f64;
            assert!((got - want).abs() < 9.0, "x={x}: {got} vs {want}");
        }
    }

    fn erf(x: f64) -> f64 {
        // Abramowitz-Stegun 7.1.26
        let t = 1.0 / (1.0 + 0.3275911 * x.abs());
        let y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * (-x * x).exp();
        if x >= 0.0 { y } else { -y }
    }

    #[test]
    fn blur_clamps_at_image_border() {
        let src = RgbaImage::from_pixel(50, 50, Rgba([90, 90, 90, 255]));
        let mut f = src.clone();
        apply(&mut f, &[(Rect::new(-10.0, -10.0, 70.0, 70.0), RedactStyle::Blur)], 1.0);
        assert!(f.pixels().all(|p| p[0] == 90));
    }

    #[test]
    fn overlapping_regions_use_untouched_source() {
        let src = noise(100, 60);
        let mut a = src.clone();
        apply(&mut a, &[(Rect::new(0.0, 0.0, 60.0, 40.0), RedactStyle::Pixelate), (Rect::new(30.0, 0.0, 60.0, 40.0), RedactStyle::Pixelate)], 1.0);
        let mut b = src.clone();
        apply(&mut b, &[(Rect::new(30.0, 0.0, 60.0, 40.0), RedactStyle::Pixelate)], 1.0);
        // im rechten Feld (x ≥ 60, nur von ihm überdeckt) gleich
        assert_eq!(a.get_pixel(70, 10), b.get_pixel(70, 10));
        // und der Überlapp ist exakt dasselbe wie allein (Quelle unverändert)
        assert_eq!(a.get_pixel(40, 10), b.get_pixel(40, 10));
    }

    #[test]
    fn out_of_bounds_and_empty_regions_ignored() {
        let src = noise(40, 40);
        let mut f = src.clone();
        apply(
            &mut f,
            &[
                (Rect::new(100.0, 100.0, 10.0, 10.0), RedactStyle::Solid),
                (Rect::NULL, RedactStyle::Blur),
                (Rect::new(5.0, 5.0, 0.0, 0.0), RedactStyle::Pixelate),
            ],
            1.0,
        );
        assert_eq!(f, src);
    }

    #[test]
    fn effects_cache() {
        let c = EffectsCache::new(noise(64, 48), 1.0);
        assert!(c.image(RedactStyle::Solid).is_none());
        let p = c.image(RedactStyle::Pixelate).unwrap();
        assert_eq!(p.dimensions(), (64, 48));
        assert_eq!(p.get_pixel(0, 0), p.get_pixel(11, 11));
        let b = c.image(RedactStyle::Blur).unwrap();
        assert_eq!(b.dimensions(), (64, 48));
        assert_eq!(c.pixel_block(), 12);
    }

    #[test]
    #[ignore]
    fn perf_apply() {
        for (w, h) in [(1920u32, 1080u32), (3840, 2160)] {
            let mut f = noise(w, h);
            let regions = vec![
                (Rect::new(200.0, 300.0, 600.0, 40.0), RedactStyle::Blur),
                (Rect::new(900.0, 500.0, 500.0, 40.0), RedactStyle::Pixelate),
                (Rect::new(100.0, 700.0, 300.0, 30.0), RedactStyle::Solid),
            ];
            let t = std::time::Instant::now();
            for _ in 0..10 {
                apply(&mut f, &regions, 1.0);
            }
            println!("redact::apply {w}x{h}, 3 Felder: {:?} pro Bild", t.elapsed() / 10);
        }
    }
}
