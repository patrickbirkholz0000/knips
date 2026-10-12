//! Mitlaufende Zensurbalken (`VideoRedactor.track`). Auf dem Mac verfolgt Vision
//! (`VNTrackObjectRequest`) den Bildinhalt; hier übernimmt das ein eigener Verfolger
//! (Vorlagenvergleich auf Graustufen), mit derselben Schnittstelle und derselben Nachbearbeitung.
//!
//! Verfahren: Die Vorlage ist der Bildinhalt unter `rect` zum Zeitpunkt `t0` (bleibt für den
//! ganzen Lauf fest, kein Abdriften). Pro Bild wird um die zuletzt gefundene Stelle gesucht,
//! verschoben um die letzte Geschwindigkeit; der Suchradius wächst mit der Geschwindigkeit und
//! mit jedem verlorenen Bild (mindestens 32 px, im ersten Schritt 64 px, bei 1280 px Breite).
//! Verglichen wird per normierter Kreuzkorrelation (NCC, helligkeits- und kontrastunabhängig) mit
//! Integralbildern für die Fenstersummen; große Vorlagen werden grob (2×/4× verkleinert) gesucht
//! und dann in voller Auflösung nachgeschärft, die Spitze wird per Parabel auf Teilpixel genau
//! bestimmt. Ein Treffer gilt ab NCC 0,55; sonst bleibt der Balken an der letzten sicheren Stelle
//! stehen. Die Größe bleibt fest.

#![allow(clippy::chunks_exact_to_as_chunks)] // Rust-Version offen halten: kein `as_chunks`


use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{bail, Result};

use crate::geometry::Rect;
use crate::imageops::resample_gray;
use crate::model::TrackPoint;
use crate::RgbaImage;

pub struct TrackParams<'a> {
    /// Balken in Videopixeln zum Zeitpunkt `t0`.
    pub rect: Rect,
    pub t0: f64,
    pub start: f64,
    pub end: f64,
    /// Bildrate des Videos; Schrittweite = 1 / clamp(fps, 15, 60).
    pub fps: f64,
    pub video_width: f64,
    pub video_height: f64,
    pub cancel: &'a AtomicBool,
}

/// Längste Kante der Arbeitsbilder.
const WORK_MAX: f64 = 1280.0;
/// Ab dieser NCC gilt der Treffer als sicher (Vision: `confidence > 0.3`).
const CONFIDENT: f32 = 0.55;
/// Suchradius im ersten Schritt / mindestens danach (Pixel im Arbeitsbild).
const FIRST_RADIUS: f64 = 64.0;
const MIN_RADIUS: f64 = 32.0;
const MAX_RADIUS: f64 = 160.0;
/// Mindeststreuung (Graustufen) einer brauchbaren Vorlage.
const MIN_STD: f64 = 3.0;

struct Gray {
    w: usize,
    h: usize,
    d: Vec<u8>,
}

impl Gray {
    fn from_rgba(img: &RgbaImage, w: usize, h: usize) -> Gray {
        Gray { w, h, d: resample_gray(img, w as u32, h as u32) }
    }

    /// k×k-Kästchen mitteln (Breite/Höhe abgerundet).
    fn down(&self, k: usize) -> Gray {
        let (w, h) = (self.w / k, self.h / k);
        let mut d = vec![0u8; w * h];
        let area = (k * k) as u32;
        for y in 0..h {
            for x in 0..w {
                let mut s = 0u32;
                for yy in 0..k {
                    let row = &self.d[(y * k + yy) * self.w + x * k..][..k];
                    s += row.iter().map(|&v| v as u32).sum::<u32>();
                }
                d[y * w + x] = ((s + area / 2) / area) as u8;
            }
        }
        Gray { w, h, d }
    }
}

struct Template {
    w: usize,
    h: usize,
    /// Mittelwertfrei.
    data: Vec<f32>,
    /// sqrt(Σ t²)
    norm: f64,
    std: f64,
}

impl Template {
    fn new(g: &Gray, x: usize, y: usize, w: usize, h: usize) -> Option<Template> {
        if w == 0 || h == 0 || x + w > g.w || y + h > g.h {
            return None;
        }
        let n = (w * h) as f64;
        let mut sum = 0u64;
        for j in 0..h {
            sum += g.d[(y + j) * g.w + x..][..w].iter().map(|&v| v as u64).sum::<u64>();
        }
        let mean = sum as f64 / n;
        let mut data = Vec::with_capacity(w * h);
        let mut ss = 0f64;
        for j in 0..h {
            for &v in &g.d[(y + j) * g.w + x..][..w] {
                let t = v as f64 - mean;
                ss += t * t;
                data.push(t as f32);
            }
        }
        Some(Template { w, h, data, norm: ss.sqrt(), std: (ss / n).sqrt() })
    }
}

fn dot(t: &[f32], p: &[u8]) -> f32 {
    let mut acc = [0f32; 8];
    let tc = t.chunks_exact(8);
    let pc = p.chunks_exact(8);
    let (tr, pr) = (tc.remainder(), pc.remainder());
    for (a, b) in tc.zip(pc) {
        for i in 0..8 {
            acc[i] += a[i] * b[i] as f32;
        }
    }
    let mut s: f32 = acc.iter().sum();
    for (a, b) in tr.iter().zip(pr) {
        s += a * *b as f32;
    }
    s
}

/// NCC-Werte für alle Positionen im Rechteck `[x0,x1]×[y0,y1]` (auf gültige Positionen begrenzt).
struct Grid {
    x0: i64,
    y0: i64,
    nx: usize,
    ny: usize,
    s: Vec<f32>,
}

impl Grid {
    fn at(&self, x: i64, y: i64) -> Option<f32> {
        let (ix, iy) = (x - self.x0, y - self.y0);
        (ix >= 0 && iy >= 0 && (ix as usize) < self.nx && (iy as usize) < self.ny).then(|| self.s[iy as usize * self.nx + ix as usize])
    }
}

fn score_grid(g: &Gray, t: &Template, x0: i64, x1: i64, y0: i64, y1: i64) -> Option<Grid> {
    let max_x = g.w as i64 - t.w as i64;
    let max_y = g.h as i64 - t.h as i64;
    let (x0, x1, y0, y1) = (x0.max(0), x1.min(max_x), y0.max(0), y1.min(max_y));
    if x1 < x0 || y1 < y0 {
        return None;
    }
    let (nx, ny) = ((x1 - x0 + 1) as usize, (y1 - y0 + 1) as usize);
    // Integralbilder (Summe, Quadratsumme) über den Bereich, den alle Fenster berühren.
    let (rw, rh) = (nx + t.w - 1, ny + t.h - 1);
    let stride = rw + 1;
    let mut isum = vec![0u64; stride * (rh + 1)];
    let mut isq = vec![0u64; stride * (rh + 1)];
    for y in 0..rh {
        let row = &g.d[(y0 as usize + y) * g.w + x0 as usize..][..rw];
        let (mut rs, mut rq) = (0u64, 0u64);
        for (x, &v) in row.iter().enumerate() {
            rs += v as u64;
            rq += v as u64 * v as u64;
            isum[(y + 1) * stride + x + 1] = isum[y * stride + x + 1] + rs;
            isq[(y + 1) * stride + x + 1] = isq[y * stride + x + 1] + rq;
        }
    }
    let n = (t.w * t.h) as f64;
    let mut s = vec![0f32; nx * ny];
    for iy in 0..ny {
        for ix in 0..nx {
            let rect = |a: &[u64]| a[(iy + t.h) * stride + ix + t.w] + a[iy * stride + ix] - a[iy * stride + ix + t.w] - a[(iy + t.h) * stride + ix];
            let sum = rect(&isum) as f64;
            let var = rect(&isq) as f64 - sum * sum / n;
            if var < n {
                continue; // praktisch einfarbig: keine Aussage
            }
            let mut num = 0f32;
            for j in 0..t.h {
                let off = (y0 as usize + iy + j) * g.w + x0 as usize + ix;
                num += dot(&t.data[j * t.w..(j + 1) * t.w], &g.d[off..off + t.w]);
            }
            s[iy * nx + ix] = (num as f64 / (t.norm * var.sqrt())) as f32;
        }
    }
    Some(Grid { x0, y0, nx, ny, s })
}

/// Parabelspitze aus drei Werten (Abweichung in Pixeln, ±0,5).
fn parabola(a: f32, b: f32, c: f32) -> f64 {
    let d = a - 2.0 * b + c;
    if d >= -1e-6 {
        0.0
    } else {
        (0.5 * (a - c) / d).clamp(-0.5, 0.5) as f64
    }
}

/// Bester Punkt eines Gitters: NCC minus kleiner Abstrafung für Abstand zur Vorhersage (bei
/// sich wiederholendem Inhalt gewinnt die erwartete Stelle). `to_full` rechnet in volle Pixel um.
fn best_of(grid: &Grid, pred: (f64, f64), radius: f64, to_full: impl Fn(i64, i64) -> (f64, f64)) -> (i64, i64, f32) {
    let mut best = (grid.x0, grid.y0, f64::NEG_INFINITY, 0f32);
    for iy in 0..grid.ny {
        for ix in 0..grid.nx {
            let raw = grid.s[iy * grid.nx + ix];
            let (fx, fy) = to_full(grid.x0 + ix as i64, grid.y0 + iy as i64);
            let d = ((fx - pred.0).powi(2) + (fy - pred.1).powi(2)).sqrt() / radius.max(1.0);
            let adj = raw as f64 - 0.04 * d * d;
            if adj > best.2 {
                best = (grid.x0 + ix as i64, grid.y0 + iy as i64, adj, raw);
            }
        }
    }
    (best.0, best.1, best.3)
}

struct Tracker {
    full: Template,
    /// Obere linke Ecke der Vorlage im Arbeitsbild.
    tx: usize,
    ty: usize,
    /// Balken relativ zur Vorlage (Arbeitsbild-Pixel); nicht 0, wenn die Vorlage vergrößert wurde.
    off: (f64, f64),
    /// Grobe Suche: Faktor, Vorlage auf dem verkleinerten Bild, Restversatz der Ecke.
    coarse: Option<(usize, Template, usize, usize)>,
}

impl Tracker {
    /// Vorlage aus `rect` (Arbeitsbild-Pixel): mindestens 12 px je Seite; zu glatte Vorlagen
    /// (Streuung < 3) werden um die halbe Größe rundum erweitert, höchstens zweimal.
    fn new(g: &Gray, rect: Rect) -> Option<Tracker> {
        let grow = |lo: &mut f64, hi: &mut f64, min: f64| {
            if *hi - *lo < min {
                let mid = (*lo + *hi) / 2.0;
                *lo = mid - min / 2.0;
                *hi = mid + min / 2.0;
            }
        };
        let (mut x0, mut x1) = (rect.x.floor(), (rect.x + rect.width).ceil());
        let (mut y0, mut y1) = (rect.y.floor(), (rect.y + rect.height).ceil());
        grow(&mut x0, &mut x1, 12.0);
        grow(&mut y0, &mut y1, 12.0);
        let mut chosen = None;
        for round in 0..3 {
            let (cx0, cx1) = (x0.max(0.0), x1.min(g.w as f64));
            let (cy0, cy1) = (y0.max(0.0), y1.min(g.h as f64));
            if cx1 - cx0 < 4.0 || cy1 - cy0 < 4.0 {
                return None;
            }
            let t = Template::new(g, cx0 as usize, cy0 as usize, (cx1 - cx0) as usize, (cy1 - cy0) as usize)?;
            let ok = t.std >= MIN_STD;
            chosen = Some((cx0 as usize, cy0 as usize, t));
            if ok || round == 2 {
                break;
            }
            let (hw, hh) = ((x1 - x0) / 2.0, (y1 - y0) / 2.0);
            x0 -= hw;
            x1 += hw;
            y0 -= hh;
            y1 += hh;
        }
        let (tx, ty, full) = chosen?;
        let area = full.w * full.h;
        let mut k = if area <= 2500 { 1 } else if area <= 10000 { 2 } else { 4 };
        while k > 1 && full.w.min(full.h) / k < 8 {
            k /= 2;
        }
        let coarse = if k > 1 {
            let small = g.down(k);
            Template::new(&small, tx / k, ty / k, full.w / k, full.h / k)
                .filter(|t| t.std >= 2.0)
                .map(|t| (k, t, tx - (tx / k) * k, ty - (ty / k) * k))
        } else {
            None
        };
        Some(Tracker { full, tx, ty, off: (rect.x - tx as f64, rect.y - ty as f64), coarse })
    }

    /// Sucht die Vorlage um `pred` (Ecke, Arbeitsbild) im Radius `r`. Liefert Ecke (Teilpixel)
    /// und NCC am Treffer.
    fn locate(&self, g: &Gray, small: Option<&Gray>, pred: (f64, f64), r: f64) -> Option<((f64, f64), f32)> {
        let ri = r.ceil() as i64;
        // Mittelpunkt und Halbbreite des Feinsuchbereichs (volle Auflösung)
        let (cx, cy, half) = match (&self.coarse, small) {
            (Some((k, ct, mx, my)), Some(sg)) => {
                let kk = *k as f64;
                let pc = ((pred.0 - *mx as f64) / kk, (pred.1 - *my as f64) / kk);
                let rc = (r / kk).ceil() as i64;
                let (px, py) = (pc.0.round() as i64, pc.1.round() as i64);
                let grid = score_grid(sg, ct, px - rc, px + rc, py - rc, py + rc)?;
                let (bx, by, _) = best_of(&grid, pred, r, |x, y| ((x * *k as i64 + *mx as i64) as f64, (y * *k as i64 + *my as i64) as f64));
                ((bx * *k as i64 + *mx as i64), (by * *k as i64 + *my as i64), *k as i64 + 1)
            }
            _ => (pred.0.round() as i64, pred.1.round() as i64, ri),
        };
        // Ein Pixel Rand für die Teilpixel-Spitze.
        let grid = score_grid(g, &self.full, cx - half - 1, cx + half + 1, cy - half - 1, cy + half + 1)?;
        let (bx, by, raw) = best_of(&grid, pred, r, |x, y| (x as f64, y as f64));
        let sx = match (grid.at(bx - 1, by), grid.at(bx, by), grid.at(bx + 1, by)) {
            (Some(a), Some(b), Some(c)) => parabola(a, b, c),
            _ => 0.0,
        };
        let sy = match (grid.at(bx, by - 1), grid.at(bx, by), grid.at(bx, by + 1)) {
            (Some(a), Some(b), Some(c)) => parabola(a, b, c),
            _ => 0.0,
        };
        Some(((bx as f64 + sx, by as f64 + sy), raw))
    }
}

/// Verfolgt den Inhalt unter `rect` vorwärts bis `end` und rückwärts bis `start`. Größe bleibt fest,
/// nur die Position folgt; verloren → an der letzten sicheren Stelle stehen bleiben. Danach in
/// Bewegungsrichtung um das Sechsfache der Geschwindigkeit pro Bild vergrößern (wie auf dem Mac).
/// `frame_at(t)` darf verkleinerte Bilder liefern (≤ 1280 px); Koordinaten werden umgerechnet.
pub fn track(
    params: &TrackParams,
    frame_at: &mut dyn FnMut(f64) -> Option<RgbaImage>,
    progress: &mut dyn FnMut(f64),
) -> Result<Vec<TrackPoint>> {
    let fps = if params.fps.is_finite() { params.fps } else { 30.0 };
    let step = 1.0 / fps.clamp(15.0, 60.0); // jedes Bild: kleine Sprünge verfolgt die Vorlage zuverlässig
    let eps = 1e-9;
    let mut forward = Vec::new();
    let mut k = 1.0;
    while params.t0 + k * step <= params.end + eps {
        forward.push(params.t0 + k * step);
        k += 1.0;
    }
    let mut backward = Vec::new();
    let mut k = 1.0;
    while params.t0 - k * step >= params.start - eps {
        backward.push(params.t0 - k * step);
        k += 1.0;
    }
    let total = (forward.len() + backward.len()).max(1) as f64;
    let mut done = 0.0;
    let rect = params.rect;

    // Arbeitsgröße aus dem Bild bei t0.
    let first = frame_at(params.t0);
    let session = first.as_ref().and_then(|img| {
        let longest = img.width().max(img.height()) as f64;
        let f = (WORK_MAX / longest).min(1.0);
        let (w, h) = (((img.width() as f64 * f).round() as usize).max(1), ((img.height() as f64 * f).round() as usize).max(1));
        let (sx, sy) = (w as f64 / params.video_width, h as f64 / params.video_height);
        let g0 = Gray::from_rgba(img, w, h);
        let work_rect = Rect::new(rect.x * sx, rect.y * sy, rect.width * sx, rect.height * sy);
        Tracker::new(&g0, work_rect).map(|t| (t, w, h, sx, sy))
    });
    drop(first);

    let mut pass = |times: &[f64]| -> Result<Vec<TrackPoint>> {
        let mut points = Vec::with_capacity(times.len());
        let Some((tracker, w, h, sx, sy)) = &session else {
            // Keine Vorlage (kein Bild bei t0, Fläche zu klein): Balken bleibt stehen.
            for &t in times {
                if params.cancel.load(Ordering::Relaxed) {
                    bail!("abgebrochen");
                }
                points.push(TrackPoint { time: t, rect });
                done += 1.0;
                progress(done / total);
            }
            return Ok(points);
        };
        let mut pos = (tracker.tx as f64, tracker.ty as f64);
        let mut vel = (0.0f64, 0.0f64);
        let mut lost = 0u32;
        let mut steps = 0u32;
        let mut current = rect;
        for &t in times {
            if params.cancel.load(Ordering::Relaxed) {
                bail!("abgebrochen");
            }
            done += 1.0;
            let Some(img) = frame_at(t) else {
                progress(done / total);
                continue;
            };
            let g = Gray::from_rgba(&img, *w, *h);
            let small = tracker.coarse.as_ref().map(|(k, ..)| g.down(*k));
            let ahead = (lost + 1).min(4) as f64;
            let pred = (pos.0 + vel.0 * ahead, pos.1 + vel.1 * ahead);
            let speed = vel.0.abs().max(vel.1.abs());
            let base = if steps < 2 { FIRST_RADIUS } else { MIN_RADIUS.max(2.0 * speed + 16.0) };
            let radius = (base + 10.0 * lost.min(10) as f64).min(MAX_RADIUS);
            if let Some((p, score)) = tracker.locate(&g, small.as_ref(), pred, radius) {
                if score >= CONFIDENT {
                    vel = ((p.0 - pos.0) / (lost + 1) as f64, (p.1 - pos.1) / (lost + 1) as f64);
                    pos = p;
                    lost = 0;
                    current = Rect::new((pos.0 + tracker.off.0) / sx, (pos.1 + tracker.off.1) / sy, rect.width, rect.height);
                } else {
                    lost += 1;
                }
            } else {
                lost += 1;
            }
            steps += 1;
            // Verloren: an der letzten sicheren Stelle stehen bleiben.
            points.push(TrackPoint { time: t, rect: current });
            progress(done / total);
        }
        Ok(points)
    };
    let ahead = pass(&forward)?;
    let behind = pass(&backward)?;

    let mut points: Vec<TrackPoint> = behind.into_iter().rev().collect();
    points.push(TrackPoint { time: params.t0, rect });
    points.extend(ahead);
    points.sort_by(|a, b| a.time.partial_cmp(&b.time).unwrap_or(std::cmp::Ordering::Equal));
    Ok(grow_by_velocity(&points))
}

/// Nachbearbeitung wie auf dem Mac: Balken in Bewegungsrichtung um das Sechsfache der
/// Geschwindigkeit pro Bild vergrößern (Verfolger hinken bei schnellem Scrollen hinterher).
fn grow_by_velocity(points: &[TrackPoint]) -> Vec<TrackPoint> {
    let n = points.len();
    (0..n)
        .map(|i| {
            let lo = i.saturating_sub(1);
            let hi = (i + 1).min(n - 1);
            let (prev, next) = (points[lo].rect, points[hi].rect);
            let frames = (hi - lo) as f64;
            if frames <= 0.0 {
                return points[i];
            }
            let vx = (next.mid_x() - prev.mid_x()).abs() / frames;
            let vy = (next.mid_y() - prev.mid_y()).abs() / frames;
            let r = points[i].rect;
            let grown = r.inset(-(vx * 6.0).min(r.width), -(vy * 6.0).min(r.height));
            TrackPoint { time: points[i].time, rect: grown }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;

    fn hash(a: u32, b: u32, seed: u32) -> u32 {
        let mut h = a.wrapping_mul(0x9E3779B1) ^ b.wrapping_mul(0x85EBCA6B) ^ seed.wrapping_mul(0xC2B2AE35);
        h ^= h >> 15;
        h = h.wrapping_mul(0x2C1B3C6D);
        h ^= h >> 12;
        h = h.wrapping_mul(0x297A2D39);
        h ^ (h >> 15)
    }

    /// „Text-ähnlicher“ Inhalt: Blöcke 5×8 px mit zufälliger Helligkeit, ein Teil leer.
    fn content(x: u32, y: i64, seed: u32) -> u8 {
        let by = y.div_euclid(8) as u32;
        let h = hash(x / 5, by, seed);
        if h.is_multiple_of(3) { 235 } else { (30 + (h >> 8) % 160) as u8 }
    }

    const HEADER: u32 = 36;

    fn frame(w: u32, h: u32, offset: i64, seed: u32) -> RgbaImage {
        RgbaImage::from_fn(w, h, |x, y| {
            let v = if y < HEADER {
                // feste Kopfleiste
                if (x / 7 + y / 6) % 2 == 0 { 20 } else { 90 }
            } else {
                content(x, y as i64 + offset, seed)
            };
            Rgba([v, v, v, 255])
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn run(
        w: u32,
        h: u32,
        fps: f64,
        speed: i64,
        rect: Rect,
        t0: f64,
        start: f64,
        end: f64,
        lose_after: Option<usize>,
    ) -> Vec<TrackPoint> {
        let cancel = AtomicBool::new(false);
        let params = TrackParams { rect, t0, start, end, fps, video_width: w as f64, video_height: h as f64, cancel: &cancel };
        let mut frame_at = |t: f64| {
            let idx = (t * fps).round() as i64;
            let seed = if lose_after.is_some_and(|l| idx as usize > l) { 777 } else { 1 };
            Some(frame(w, h, idx * speed, seed))
        };
        track(&params, &mut frame_at, &mut |_| {}).unwrap()
    }

    /// Erwartete Mitte des Balkens: bewegt sich mit `speed` px/Bild nach oben.
    fn expected_cy(rect: Rect, t0: f64, t: f64, fps: f64, speed: i64) -> f64 {
        rect.mid_y() - ((t - t0) * fps).round() * speed as f64
    }

    #[test]
    fn follows_scrolling_content_at_various_speeds() {
        let (w, h, fps) = (900u32, 700u32, 30.0);
        let rect = Rect::new(300.0, 560.0, 220.0, 24.0);
        for speed in [4i64, 9, 14, 20, 38] {
            // so viele Bilder, dass der Balken noch unter der Kopfleiste bleibt
            let frames = ((560 - HEADER as i64 - 30) / speed).min(25) as f64;
            let pts = run(w, h, fps, speed, rect, 0.0, 0.0, frames / fps, None);
            assert_eq!(pts.len() as f64, frames + 1.0, "Speed {speed}");
            for p in &pts {
                let want = expected_cy(rect, 0.0, p.time, fps, speed);
                assert!((p.rect.mid_y() - want).abs() < 2.0, "speed {speed} t={:.3}: y {} vs {}", p.time, p.rect.mid_y(), want);
                assert!((p.rect.mid_x() - rect.mid_x()).abs() < 2.0, "x-Drift bei speed {speed}");
            }
        }
    }

    #[test]
    fn growth_in_motion_direction_only() {
        let (w, h, fps) = (900u32, 700u32, 30.0);
        let rect = Rect::new(300.0, 560.0, 220.0, 24.0);
        let pts = run(w, h, fps, 4, rect, 0.0, 0.0, 10.0 / fps, None);
        // Mitte der Reihe: vy = 4 → Höhe 24 + 2·min(24, 24)=72? (vx·6 = 0 für x)
        let mid = &pts[5];
        assert!((mid.rect.width - 220.0).abs() < 1.5, "Breite {}", mid.rect.width);
        assert!((mid.rect.height - (24.0 + 2.0 * 24.0)).abs() < 3.0, "Höhe {}", mid.rect.height);
    }

    #[test]
    fn backward_and_forward_from_middle() {
        let (w, h, fps) = (900u32, 700u32, 30.0);
        // t0 bei Bild 10: Inhalt liegt dort um 10·6 px nach oben verschoben
        let speed = 6;
        let rect = Rect::new(250.0, 400.0, 200.0, 22.0);
        let pts = run(w, h, fps, speed, rect, 10.0 / fps, 0.0, 20.0 / fps, None);
        assert_eq!(pts.len(), 21);
        for p in &pts {
            let want = expected_cy(rect, 10.0 / fps, p.time, fps, speed);
            assert!((p.rect.mid_y() - want).abs() < 2.0, "t={:.3}: {} vs {}", p.time, p.rect.mid_y(), want);
        }
        // sortiert
        assert!(pts.windows(2).all(|p| p[0].time < p[1].time));
    }

    #[test]
    fn stays_put_when_lost() {
        let (w, h, fps) = (900u32, 700u32, 30.0);
        let rect = Rect::new(300.0, 560.0, 220.0, 24.0);
        let speed = 6;
        // Ab Bild 8 ist der Inhalt ein völlig anderer (verloren)
        let pts = run(w, h, fps, speed, rect, 0.0, 0.0, 16.0 / fps, Some(8));
        let last_good = expected_cy(rect, 0.0, 8.0 / fps, fps, speed);
        for p in &pts[..=8] {
            let want = expected_cy(rect, 0.0, p.time, fps, speed);
            assert!((p.rect.mid_y() - want).abs() < 2.0);
        }
        for p in &pts[10..] {
            assert!((p.rect.mid_y() - last_good).abs() < 2.0, "t={:.3}: {} vs {}", p.time, p.rect.mid_y(), last_good);
            assert!((p.rect.mid_x() - rect.mid_x()).abs() < 2.0);
        }
    }

    #[test]
    fn recovers_after_short_loss() {
        let (w, h, fps) = (900u32, 700u32, 30.0);
        let rect = Rect::new(300.0, 560.0, 220.0, 24.0);
        let cancel = AtomicBool::new(false);
        let speed = 5i64;
        let params = TrackParams { rect, t0: 0.0, start: 0.0, end: 20.0 / fps, fps, video_width: w as f64, video_height: h as f64, cancel: &cancel };
        // Bilder 6 und 7 sind Aussetzer (anderer Inhalt), danach wieder normal
        let mut frame_at = |t: f64| {
            let idx = (t * fps).round() as i64;
            let seed = if idx == 6 || idx == 7 { 555 } else { 1 };
            Some(frame(w, h, idx * speed, seed))
        };
        let pts = track(&params, &mut frame_at, &mut |_| {}).unwrap();
        for p in &pts[10..] {
            let want = expected_cy(rect, 0.0, p.time, fps, speed);
            assert!((p.rect.mid_y() - want).abs() < 3.0, "t={:.3}: {} vs {}", p.time, p.rect.mid_y(), want);
        }
    }

    #[test]
    fn scaled_frames_are_converted_back() {
        // Video 1800×1000, Bilder kommen mit halber Größe (900×500)
        let (vw, vh, fps) = (1800.0, 1000.0, 30.0);
        let speed_small = 5i64; // Bildpunkte im verkleinerten Bild
        let rect = Rect::new(500.0, 800.0, 440.0, 48.0);
        let cancel = AtomicBool::new(false);
        let params = TrackParams { rect, t0: 0.0, start: 0.0, end: 12.0 / fps, fps, video_width: vw, video_height: vh, cancel: &cancel };
        let mut frame_at = |t: f64| {
            let idx = (t * fps).round() as i64;
            Some(frame(900, 500, idx * speed_small, 1))
        };
        let pts = track(&params, &mut frame_at, &mut |_| {}).unwrap();
        for p in &pts {
            let idx = (p.time * fps).round();
            let want = rect.mid_y() - idx * speed_small as f64 * 2.0;
            assert!((p.rect.mid_y() - want).abs() < 3.0, "t={:.3}: {} vs {}", p.time, p.rect.mid_y(), want);
        }
    }

    #[test]
    fn large_frames_are_downscaled_internally() {
        // 2560×1440, Balken folgt weiter korrekt (Arbeitsbild 1280×720)
        let (w, h, fps) = (2560u32, 1440u32, 30.0);
        let rect = Rect::new(600.0, 1100.0, 500.0, 44.0);
        let cancel = AtomicBool::new(false);
        let params = TrackParams { rect, t0: 0.0, start: 0.0, end: 8.0 / fps, fps, video_width: w as f64, video_height: h as f64, cancel: &cancel };
        let speed = 12i64;
        let mut frame_at = |t: f64| Some(frame(w, h, ((t * fps).round() as i64) * speed, 1));
        let pts = track(&params, &mut frame_at, &mut |_| {}).unwrap();
        for p in &pts {
            let want = rect.mid_y() - (p.time * fps).round() * speed as f64;
            assert!((p.rect.mid_y() - want).abs() < 5.0, "t={:.3}: {} vs {}", p.time, p.rect.mid_y(), want);
        }
    }

    #[test]
    fn cancel_and_missing_frames_and_flat_template() {
        let (w, h, fps) = (400u32, 300u32, 30.0);
        let cancel = AtomicBool::new(true);
        let params = TrackParams { rect: Rect::new(100.0, 200.0, 100.0, 20.0), t0: 0.0, start: 0.0, end: 0.5, fps, video_width: w as f64, video_height: h as f64, cancel: &cancel };
        let mut fa = |t: f64| Some(frame(w, h, (t * fps) as i64, 1));
        assert!(track(&params, &mut fa, &mut |_| {}).is_err());
        // Keine Bilder → Balken bleibt stehen, alle Zeitpunkte vorhanden
        let cancel = AtomicBool::new(false);
        let params = TrackParams { cancel: &cancel, ..params };
        let mut none = |_t: f64| None;
        let pts = track(&params, &mut none, &mut |_| {}).unwrap();
        assert_eq!(pts.len(), 16);
        assert!(pts.iter().all(|p| (p.rect.mid_y() - 210.0).abs() < 1e-6));
        // Einfarbige Fläche → kein Ausreißer, bleibt stehen
        let mut flat = |_t: f64| Some(RgbaImage::from_pixel(w, h, Rgba([200, 200, 200, 255])));
        let pts = track(&params, &mut flat, &mut |_| {}).unwrap();
        assert!(pts.iter().all(|p| (p.rect.mid_y() - 210.0).abs() < 1e-6));
    }

    #[test]
    fn progress_reaches_one() {
        let (w, h, fps) = (400u32, 300u32, 30.0);
        let cancel = AtomicBool::new(false);
        let params = TrackParams { rect: Rect::new(100.0, 200.0, 100.0, 20.0), t0: 0.2, start: 0.0, end: 0.4, fps, video_width: w as f64, video_height: h as f64, cancel: &cancel };
        let mut fa = |t: f64| Some(frame(w, h, (t * fps).round() as i64 * 2, 1));
        let mut last = 0.0;
        track(&params, &mut fa, &mut |p| last = p).unwrap();
        assert!((last - 1.0).abs() < 1e-9);
    }

    #[test]
    #[ignore]
    fn perf_track() {
        let (w, h, fps) = (1280u32, 720u32, 30.0);
        let n = 60;
        let frames: Vec<RgbaImage> = (0..=n).map(|i| frame(w, h, i * 12, 1)).collect();
        for rect in [Rect::new(400.0, 600.0, 220.0, 22.0), Rect::new(300.0, 500.0, 600.0, 120.0)] {
            let cancel = AtomicBool::new(false);
            let params = TrackParams { rect, t0: 0.0, start: 0.0, end: 40.0 / fps, fps, video_width: w as f64, video_height: h as f64, cancel: &cancel };
            let mut fa = |t: f64| Some(frames[(t * fps).round() as usize].clone());
            let t = std::time::Instant::now();
            let pts = track(&params, &mut fa, &mut |_| {}).unwrap();
            let el = t.elapsed();
            println!("track {}x{}: {} Schritte in {:?} ({:?} pro Bild, inkl. Bildkopie)", rect.width, rect.height, pts.len(), el, el / pts.len() as u32);
        }
    }
}
