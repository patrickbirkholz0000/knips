//! Reine Hilfsfunktionen für Video (ohne Windows-Aufrufe, auf dem Mac testbar):
//! Bitrate, Zeitrechnung (100-ns-Einheiten), Bildumrechnung BGRA → NV12, Skalierung,
//! Klick-Ringe, Bildraten-Begrenzung und Halten des letzten Bildes.

#![allow(dead_code, clippy::chunks_exact_to_as_chunks)]

/// Media-Foundation-Zeit: 100 ns.
pub const TICKS: i64 = 10_000_000;

/// Sekunden → 100-ns-Einheiten (gerundet).
pub fn secs_to_ticks(s: f64) -> i64 {
    (s * TICKS as f64).round() as i64
}

pub fn ticks_to_secs(t: i64) -> f64 {
    t as f64 / TICKS as f64
}

/// Auf die nächste gerade Zahl abrunden, mindestens 2 (Encoder verlangen gerade Maße).
pub fn even(v: u32) -> u32 {
    (v & !1).max(2)
}

/// Bitrate wie auf dem Mac: `max(1,5 Mbit/s, min(40 Mbit/s, w·h·fps·bpp))`, bpp 0,09 (H.264) / 0,05 (HEVC).
pub fn bitrate(w: u32, h: u32, fps: u32, hevc: bool) -> u32 {
    let bpp = if hevc { 0.05 } else { 0.09 };
    let raw = (w as f64 * h as f64 * fps as f64 * bpp) as u64;
    raw.clamp(1_500_000, 40_000_000) as u32
}

/// Export: „höchste Qualität“ ≈ 1,5-fache Aufnahme-Bitrate.
pub fn export_bitrate(w: u32, h: u32, fps: u32, hevc: bool) -> u32 {
    let b = bitrate(w, h, fps, hevc) as u64 * 3 / 2;
    b.min(80_000_000) as u32
}

/// Schlüsselbild-Abstand: zwei Sekunden.
pub fn gop(fps: u32) -> u32 {
    fps.max(1) * 2
}

/// `MF_MT_FRAME_SIZE` / `FRAME_RATE` / `PIXEL_ASPECT_RATIO`: zwei u32 in einem u64.
pub fn pack(hi: u32, lo: u32) -> u64 {
    ((hi as u64) << 32) | lo as u64
}

pub fn unpack(v: u64) -> (u32, u32) {
    ((v >> 32) as u32, v as u32)
}

/// Breite/Höhe für das GIF: `min(width, video_w)`, Seitenverhältnis bleibt, mindestens 1.
pub fn fit_width(vw: u32, vh: u32, max_w: u32) -> (u32, u32) {
    let w = max_w.min(vw).max(1);
    let h = ((vh as f64 * w as f64 / vw.max(1) as f64).round() as u32).max(1);
    (w, h)
}

/// Bildanzahl und Zeitpunkte des GIF-Exports: `max(1, floor(dauer·fps))`, Zeit `start + i/fps`.
pub fn gif_count(duration: f64, fps: u32) -> usize {
    ((duration * fps as f64).floor() as i64).max(1) as usize
}

/// Bildanzahl des MP4-Exports mit konstanter Bildrate (aufgerundet, mindestens 1).
pub fn export_frame_count(duration: f64, fps: u32) -> usize {
    ((duration * fps as f64 - 1e-6).ceil() as i64).max(1) as usize
}

/// Zeitstempel des i-ten Ausgabebildes bei konstanter Bildrate, ohne Rundungsdrift.
pub fn cfr_pts(i: usize, fps: u32) -> i64 {
    (i as i128 * TICKS as i128 / fps.max(1) as i128) as i64
}

/// Bildrate für den Export: wirksame Quellrate (`effective_fps`) gerundet, höchstens 60. Unter 24
/// (oder unbekannt) 30 — sonst würden Bewegungen ruckeln und Zensurfelder nur grob zur Zeit passen;
/// stehende Quellbilder werden dafür zeitgenau wiederholt.
pub fn export_fps(src_fps: f64) -> u32 {
    if src_fps.is_finite() && src_fps >= 23.5 {
        (src_fps.round() as u32).clamp(24, 60)
    } else {
        30
    }
}

/// Wirksame Bildrate eines Videos mit variabler Bildrate. Bildschirmaufnahmen schreiben nur bei
/// Änderungen ein Bild; die MP4-Angabe (`nominal`) ist dann der Durchschnitt — bei einer Aufnahme mit
/// 30 fps und viel Stillstand z. B. 2,4 fps. Maßgeblich ist der typische kürzeste Abstand zweier Bilder
/// (`pts` in 100 ns, beliebige Reihenfolge): Median aller Abstände bis zum 1,5-Fachen des
/// 5-%-Quantils. Nie weniger als `nominal`; zu wenige Bilder → `nominal`.
pub fn effective_fps(nominal: f64, pts: &[i64]) -> f64 {
    let nominal = if nominal.is_finite() && nominal > 0.0 { nominal } else { 0.0 };
    let mut t = pts.to_vec();
    t.sort_unstable();
    t.dedup();
    // Abstände unter 1/240 s sind Rundungs-/Umordnungsreste, kein Bildabstand.
    let mut d: Vec<i64> = t.windows(2).map(|w| w[1] - w[0]).filter(|&x| x >= TICKS / 240).collect();
    if d.len() < 3 {
        return nominal;
    }
    d.sort_unstable();
    let low = d[d.len() / 20];
    let near: Vec<i64> = d.iter().copied().take_while(|&x| x <= low + low / 2).collect();
    let typical = near[near.len() / 2].max(1);
    (TICKS as f64 / typical as f64).clamp(nominal, 240.0_f64.max(nominal))
}

// ───────────────────────── Bildraten-Begrenzung ─────────────────────────

/// Bildschirmaufnahme liefert Bilder nur bei Änderungen. Zu schnelle Bilder (näher als 1/fps)
/// werden zurückgestellt und erst zum Fälligkeitszeitpunkt ausgegeben, damit das letzte Bild
/// einer Änderungsserie nie verloren geht.
pub struct FrameGate {
    interval: i64,
    last: Option<i64>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Gate {
    /// Sofort ausgeben mit diesem Zeitstempel.
    Emit(i64),
    /// Zurückstellen; fällig zum angegebenen Zeitstempel.
    Defer(i64),
}

impl FrameGate {
    pub fn new(fps: u32) -> Self {
        Self { interval: TICKS / fps.max(1) as i64, last: None }
    }
    pub fn interval(&self) -> i64 {
        self.interval
    }
    pub fn last(&self) -> Option<i64> {
        self.last
    }
    /// Bild mit Zeit `t` (relativ zum ersten Bild).
    pub fn check(&mut self, t: i64) -> Gate {
        match self.last {
            None => {
                self.last = Some(t.max(0));
                Gate::Emit(t.max(0))
            }
            Some(last) => {
                // 10 % Toleranz: ein Bild bei 29,9 statt 30 fps ist kein „zu früh“.
                if t - last >= self.interval * 9 / 10 {
                    let pts = t.max(last + 1);
                    self.last = Some(pts);
                    Gate::Emit(pts)
                } else {
                    Gate::Defer(last + self.interval)
                }
            }
        }
    }
    /// Zurückgestelltes Bild jetzt ausgeben; liefert den Zeitstempel (`last + interval`).
    pub fn emit_deferred(&mut self) -> i64 {
        let pts = self.last.map(|l| l + self.interval).unwrap_or(0);
        self.last = Some(pts);
        pts
    }
    /// Bild zu beliebiger Zeit `t` ausgeben (Klick-Animation), streng aufsteigend.
    pub fn emit_at(&mut self, t: i64) -> i64 {
        let pts = match self.last {
            Some(l) => t.max(l + 1),
            None => t.max(0),
        };
        self.last = Some(pts);
        pts
    }
}

/// Hält das jeweils letzte Bild zurück, bis Anfang des nächsten (oder Ende) bekannt ist:
/// so bekommt jedes Bild seine genaue Dauer (auch bei stehendem Bildschirm viele Sekunden).
#[derive(Default)]
pub struct HoldSequencer {
    held: Option<i64>,
}

impl HoldSequencer {
    /// Neues Bild bei `pts`. Liefert (Zeit, Dauer) des bisher gehaltenen Bildes zum Schreiben.
    pub fn push(&mut self, pts: i64) -> Option<(i64, i64)> {
        let prev = self.held.replace(pts)?;
        Some((prev, (pts - prev).max(1)))
    }
    /// Ende bei `end`: letztes Bild bekommt die Restdauer.
    pub fn finish(&mut self, end: i64, min_dur: i64) -> Option<(i64, i64)> {
        let prev = self.held.take()?;
        Some((prev, (end - prev).max(min_dur.max(1))))
    }
    pub fn held(&self) -> Option<i64> {
        self.held
    }
}

/// Endzeit der Aufnahme: Stopp-Zeitpunkt, sofern plausibel, sonst letztes Bild + ein Intervall.
pub fn end_time(stop_rel: i64, last_pts: i64, interval: i64) -> i64 {
    let gap = stop_rel - last_pts;
    if !(0..=3600 * TICKS).contains(&gap) {
        last_pts + interval
    } else {
        stop_rel.max(last_pts + interval.min(gap.max(1)))
    }
}

// ───────────────────────── Mikrofon-Zeit ─────────────────────────

/// Bildet Zeitstempel des Mikrofons auf die Videozeit ab (0 = erstes Videobild).
/// Passen die Zeitstempel zur Systemuhr (QPC), werden sie direkt verwendet, sonst zählt die
/// Ankunftszeit des ersten Blocks und danach die Blocklängen.
#[derive(Default)]
pub struct AudioClock {
    mode: Option<AudioMode>,
}

enum AudioMode {
    Direct,
    Arrival { base: i64, acc: i64 },
}

impl AudioClock {
    /// `ts`/`dur` des Blocks, `now` = Systemzeit beim Eintreffen, `video_first` = Systemzeit des
    /// ersten Videobildes (alles 100 ns). `None` = Block verwerfen (vor Aufnahmebeginn).
    pub fn map(&mut self, ts: i64, dur: i64, now: i64, video_first: i64) -> Option<i64> {
        let mode = self.mode.get_or_insert_with(|| {
            if (ts - now).abs() < 3 * TICKS {
                AudioMode::Direct
            } else {
                AudioMode::Arrival { base: now - dur - video_first, acc: 0 }
            }
        });
        let pts = match mode {
            AudioMode::Direct => ts - video_first,
            AudioMode::Arrival { base, acc } => {
                let p = *base + *acc;
                *acc += dur;
                p
            }
        };
        if pts + dur <= 0 {
            None
        } else {
            Some(pts.max(0))
        }
    }
}

// ───────────────────────── Pixel ─────────────────────────

/// Ausschnitt `(rx, ry, rw, rh)` aus BGRA-Zeilen (`stride` Bytes) auf `dw × dh` verkleinern/vergrößern
/// (Flächenmittel). `src` beginnt beim Bildursprung der Quelle. Läuft auf mehreren Threads.
pub fn crop_scale_bgra(
    src: &[u8],
    stride: usize,
    rect: (usize, usize, usize, usize),
    dst: &mut [u8],
    dw: usize,
    dh: usize,
) {
    let (rx, ry, rw, rh) = rect;
    assert!(rw > 0 && rh > 0 && dw > 0 && dh > 0);
    assert!(dst.len() >= dw * dh * 4);
    assert!(src.len() >= (ry + rh - 1) * stride + (rx + rw) * 4);
    let dst = &mut dst[..dw * dh * 4];
    let threads = if dw * dh < 160_000 {
        1
    } else {
        std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2).clamp(1, 8)
    };
    let rows_per = dh.div_ceil(threads);
    std::thread::scope(|s| {
        for (ci, chunk) in dst.chunks_mut(rows_per * dw * 4).enumerate() {
            let first = ci * rows_per;
            s.spawn(move || scale_rows(src, stride, rect, chunk, dw, dh, first));
        }
    });
}

fn scale_rows(src: &[u8], stride: usize, rect: (usize, usize, usize, usize), out: &mut [u8], dw: usize, dh: usize, first_row: usize) {
    let (rx, ry, rw, rh) = rect;
    if rw == dw && rh == dh {
        for (i, row) in out.chunks_mut(dw * 4).enumerate() {
            let o = (ry + first_row + i) * stride + rx * 4;
            row.copy_from_slice(&src[o..o + dw * 4]);
        }
        return;
    }
    // Spaltengrenzen einmal berechnen.
    let xr: Vec<(usize, usize)> = (0..dw)
        .map(|x| {
            let x0 = x * rw / dw;
            let x1 = (((x + 1) * rw).div_ceil(dw)).clamp(x0 + 1, rw);
            (x0, x1)
        })
        .collect();
    for (i, row) in out.chunks_mut(dw * 4).enumerate() {
        let y = first_row + i;
        let y0 = y * rh / dh;
        let y1 = (((y + 1) * rh).div_ceil(dh)).clamp(y0 + 1, rh);
        for (x, &(x0, x1)) in xr.iter().enumerate() {
            let (mut b, mut g, mut r, mut a) = (0u32, 0u32, 0u32, 0u32);
            for sy in y0..y1 {
                let base = (ry + sy) * stride + rx * 4;
                for px in src[base + x0 * 4..base + x1 * 4].chunks_exact(4) {
                    b += px[0] as u32;
                    g += px[1] as u32;
                    r += px[2] as u32;
                    a += px[3] as u32;
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            let h = n / 2;
            let o = x * 4;
            row[o] = ((b + h) / n) as u8;
            row[o + 1] = ((g + h) / n) as u8;
            row[o + 2] = ((r + h) / n) as u8;
            row[o + 3] = ((a + h) / n) as u8;
        }
    }
}

/// Größe eines NV12-Bildes (Y-Ebene + gemischte UV-Ebene).
pub fn nv12_len(w: usize, h: usize) -> usize {
    w * h * 3 / 2
}

/// BGRA (dicht gepackt, gerade Maße) → NV12, BT.709, begrenzter Wertebereich (16–235 / 16–240).
pub fn bgra_to_nv12(bgra: &[u8], w: usize, h: usize, nv12: &mut [u8]) {
    assert!(w.is_multiple_of(2) && h.is_multiple_of(2) && w > 0 && h > 0);
    assert!(bgra.len() >= w * h * 4 && nv12.len() >= nv12_len(w, h));
    let (y_plane, uv_plane) = nv12[..nv12_len(w, h)].split_at_mut(w * h);
    let threads = if w * h < 160_000 {
        1
    } else {
        std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2).clamp(1, 8)
    };
    // In Zeilenpaaren aufteilen (UV hat halb so viele Zeilen).
    let pairs = h / 2;
    let pairs_per = pairs.div_ceil(threads);
    std::thread::scope(|s| {
        let y_chunks = y_plane.chunks_mut(pairs_per * 2 * w);
        let uv_chunks = uv_plane.chunks_mut(pairs_per * w);
        for (ci, (yc, uvc)) in y_chunks.zip(uv_chunks).enumerate() {
            let first_pair = ci * pairs_per;
            s.spawn(move || {
                for (p, (yrows, uvrow)) in yc.chunks_mut(2 * w).zip(uvc.chunks_mut(w)).enumerate() {
                    let row0 = (first_pair + p) * 2;
                    let a = &bgra[row0 * w * 4..(row0 + 1) * w * 4];
                    let b = &bgra[(row0 + 1) * w * 4..(row0 + 2) * w * 4];
                    let (y0, y1) = yrows.split_at_mut(w);
                    for x in (0..w).step_by(2) {
                        let mut sr = 0i32;
                        let mut sg = 0i32;
                        let mut sb = 0i32;
                        for (dx, (src, yo)) in [(a, &mut *y0), (b, &mut *y1)].into_iter().enumerate() {
                            let _ = dx;
                            for k in 0..2 {
                                let o = (x + k) * 4;
                                let (bb, gg, rr) = (src[o] as i32, src[o + 1] as i32, src[o + 2] as i32);
                                yo[x + k] = (((47 * rr + 157 * gg + 16 * bb + 128) >> 8) + 16) as u8;
                                sr += rr;
                                sg += gg;
                                sb += bb;
                            }
                        }
                        // Mittel aus vier Pixeln.
                        let (r, g, bl) = ((sr + 2) >> 2, (sg + 2) >> 2, (sb + 2) >> 2);
                        let u = ((-26 * r - 87 * g + 113 * bl + 128) >> 8) + 128;
                        let v = ((112 * r - 102 * g - 10 * bl + 128) >> 8) + 128;
                        uvrow[x] = u.clamp(16, 240) as u8;
                        uvrow[x + 1] = v.clamp(16, 240) as u8;
                    }
                }
            });
        }
    });
}

/// Zeilen ggf. von unten nach oben vertauschen (RGB32 mit negativem Stride). Gibt dicht gepackte
/// Zeilen oben-nach-unten in `out` (BGRA).
pub fn rows_to_top_down(src: &[u8], stride: i64, w: usize, h: usize, out: &mut Vec<u8>) {
    out.clear();
    out.reserve(w * h * 4);
    let abs = stride.unsigned_abs() as usize;
    for y in 0..h {
        // Positiver Stride: Zeile 0 liegt am Anfang. Negativ: Zeile 0 (oben) liegt am Ende.
        let row = if stride >= 0 { y } else { h - 1 - y };
        out.extend_from_slice(&src[row * abs..row * abs + w * 4]);
    }
}

/// Klick-Dauer in Sekunden.
pub const CLICK_SECS: f64 = 0.35;
/// Ring-Radius in Punkten.
pub const CLICK_RADIUS_PT: f64 = 22.0;

/// Klick-Visualisierung: dunkle, halbtransparente Füllung mit weißem Ring, blendet über
/// `CLICK_SECS` aus. `cx`,`cy` in Bildpixeln, `radius` in Pixeln, `age` in Sekunden.
pub fn draw_click(bgra: &mut [u8], w: usize, h: usize, cx: f64, cy: f64, radius: f64, age: f64) {
    let p = (age / CLICK_SECS).clamp(0.0, 1.0);
    if p >= 1.0 || radius < 1.0 {
        return;
    }
    let fade = 1.0 - p;
    // Ring zieht sich beim Klick leicht zusammen/öffnet sich: 0,75 → 1,0 (ease-out).
    let grow = 0.75 + 0.25 * (1.0 - (1.0 - p) * (1.0 - p));
    let r = radius * grow;
    let ring_w = (radius * 0.14).max(1.5);
    let x0 = ((cx - r - ring_w - 1.0).floor().max(0.0)) as usize;
    let x1 = ((cx + r + ring_w + 1.0).ceil().min(w as f64)) as usize;
    let y0 = ((cy - r - ring_w - 1.0).floor().max(0.0)) as usize;
    let y1 = ((cy + r + ring_w + 1.0).ceil().min(h as f64)) as usize;
    for y in y0..y1 {
        for x in x0..x1 {
            let d = ((x as f64 + 0.5 - cx).powi(2) + (y as f64 + 0.5 - cy).powi(2)).sqrt();
            // Füllung: innerhalb des Rings, Kante 1 px weich.
            let inside = (r - d + 0.5).clamp(0.0, 1.0);
            // Ring: Band der Breite ring_w um r (innen bündig).
            let ring = (1.0 - ((d - (r - ring_w * 0.5)).abs() - ring_w * 0.5 + 0.5).clamp(0.0, 1.0)).clamp(0.0, 1.0);
            if inside <= 0.0 && ring <= 0.0 {
                continue;
            }
            let o = (y * w + x) * 4;
            let px = &mut bgra[o..o + 4];
            let a_fill = 0.35 * fade * inside;
            for c in &mut px[..3] {
                *c = (*c as f64 * (1.0 - a_fill)) as u8;
            }
            let a_ring = 0.95 * fade * ring;
            for c in &mut px[..3] {
                *c = (*c as f64 * (1.0 - a_ring) + 255.0 * a_ring).round() as u8;
            }
        }
    }
}

// ───────────────────────── Tests ─────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bitrate_wie_mac() {
        assert_eq!(bitrate(1920, 1080, 30, false), 5_598_720);
        assert_eq!(bitrate(1920, 1080, 30, true), 3_110_400);
        assert_eq!(bitrate(320, 200, 10, false), 1_500_000);
        assert_eq!(bitrate(3840, 2160, 60, false), 40_000_000);
        assert_eq!(export_bitrate(1920, 1080, 30, false), 8_398_080);
        assert_eq!(gop(30), 60);
    }

    #[test]
    fn zeit() {
        assert_eq!(secs_to_ticks(1.5), 15_000_000);
        assert_eq!(cfr_pts(1, 30), 333_333);
        assert_eq!(cfr_pts(30, 30), TICKS);
        assert_eq!(export_frame_count(1.0, 30), 30);
        assert_eq!(export_frame_count(0.0, 30), 1);
        assert_eq!(export_frame_count(1.02, 30), 31);
        assert_eq!(gif_count(2.0, 10), 20);
        assert_eq!(gif_count(0.05, 10), 1);
        assert_eq!(export_fps(0.0), 30);
        assert_eq!(export_fps(59.94), 60);
        assert_eq!(export_fps(144.0), 60);
        // Variable Bildrate mit viel Stillstand (CI: 30 fps eingestellt → 2,4 fps im Durchschnitt)
        assert_eq!(export_fps(2.4), 30);
        assert_eq!(export_fps(15.0), 30);
        assert_eq!(export_fps(f64::NAN), 30);
        assert_eq!(export_fps(23.976), 24);
        assert_eq!(export_fps(25.0), 25);
        assert_eq!(unpack(pack(1920, 1080)), (1920, 1080));
        assert_eq!(fit_width(1920, 1080, 800), (800, 450));
        assert_eq!(fit_width(640, 480, 800), (640, 480));
    }

    #[test]
    fn wirksame_bildrate() {
        let f = |i: i64| i * TICKS / 30;
        // Konstant 30 fps
        let cfr: Vec<i64> = (0..90).map(f).collect();
        assert!((effective_fps(30.0, &cfr) - 30.0).abs() < 0.1);
        // Aufnahme mit 30 fps: 0,5 s Bewegung, dann 4 s Stillstand mit drei einzelnen Bildern.
        // Durchschnitt ≈ 4 fps, wirksam 30.
        let mut vfr: Vec<i64> = (0..15).map(f).collect();
        vfr.extend([TICKS, 2 * TICKS, 4 * TICKS + TICKS / 2]);
        let avg = vfr.len() as f64 / 4.5;
        assert!(avg < 5.0);
        let e = effective_fps(avg, &vfr);
        assert!((e - 30.0).abs() < 0.5, "{e}");
        assert_eq!(export_fps(e), 30);
        // Ungleichmäßige Abstände wie aus `FrameGate` (≥ 0,9 Intervall, oft etwas mehr)
        let mut t = 0i64;
        let mut jitter = vec![0i64];
        for k in 0..60 {
            t += [300_000i64, 333_333, 360_000, 333_333, 450_000][k % 5];
            jitter.push(t);
        }
        assert_eq!(export_fps(effective_fps(1.0, &jitter)), 30);
        // 60 fps, unsortiert und mit doppelten Zeiten
        let mut s60: Vec<i64> = (0..40).map(|i| i * TICKS / 60).rev().collect();
        s60.push(0);
        assert_eq!(export_fps(effective_fps(10.0, &s60)), 60);
        // Zu wenige Bilder → Angabe des Containers
        assert_eq!(effective_fps(2.0, &[0, TICKS]), 2.0);
        assert_eq!(effective_fps(f64::NAN, &[]), 0.0);
        // Nie unter der Angabe (CFR mit B-Bildern: Abstände stimmen, Angabe gleich)
        assert!(effective_fps(25.0, &(0..50).map(|i| i * TICKS / 25).collect::<Vec<_>>()) >= 25.0);
    }

    #[test]
    fn gate_begrenzt_und_stellt_zurueck() {
        let mut g = FrameGate::new(30); // 333_333
        assert_eq!(g.check(5_000), Gate::Emit(5_000));
        assert_eq!(g.check(100_000), Gate::Defer(5_000 + 333_333));
        assert_eq!(g.emit_deferred(), 338_333);
        // 10 % Toleranz
        assert_eq!(g.check(338_333 + 300_000), Gate::Emit(638_333));
        // Streng aufsteigend auch bei gleichen Zeiten
        assert_eq!(g.emit_at(0), 638_334);
    }

    #[test]
    fn halten_gibt_exakte_dauer() {
        let mut s = HoldSequencer::default();
        assert_eq!(s.push(0), None);
        assert_eq!(s.push(5 * TICKS), Some((0, 5 * TICKS)));
        assert_eq!(s.finish(8 * TICKS, 333_333), Some((5 * TICKS, 3 * TICKS)));
        assert_eq!(s.finish(8 * TICKS, 333_333), None);
        let mut s = HoldSequencer::default();
        s.push(100);
        // Ende vor/auf dem Bild: Mindestdauer
        assert_eq!(s.finish(100, 333_333), Some((100, 333_333)));
    }

    #[test]
    fn endzeit() {
        assert_eq!(end_time(10 * TICKS, 4 * TICKS, 333_333), 10 * TICKS);
        // Stopp „vor“ dem letzten Bild (Uhren-Unterschied) → letztes + Intervall
        assert_eq!(end_time(3 * TICKS, 4 * TICKS, 333_333), 4 * TICKS + 333_333);
        // Stopp unmittelbar nach dem letzten Bild: mindestens ein (hier kürzeres) Stück
        assert_eq!(end_time(4 * TICKS + 10, 4 * TICKS, 333_333), 4 * TICKS + 10);
    }

    #[test]
    fn mikrofon_zeit() {
        let first = 100 * TICKS;
        let mut c = AudioClock::default();
        // Direkt: Block beginnt 1 s nach dem ersten Bild
        assert_eq!(c.map(101 * TICKS, 100_000, 101 * TICKS + 50, first), Some(TICKS));
        // Block komplett vor dem ersten Bild → verworfen
        let mut c = AudioClock::default();
        assert_eq!(c.map(99 * TICKS, 100_000, 99 * TICKS, first), None);
        // Block über dem Anfang → ab 0
        let mut c = AudioClock::default();
        assert_eq!(c.map(first - 50_000, 100_000, first + 10, first), Some(0));
        // Fremde Zeitbasis → Ankunftszeit
        let mut c = AudioClock::default();
        let a = c.map(5, 100_000, first + TICKS, first).unwrap();
        assert_eq!(a, TICKS - 100_000);
        let b = c.map(100_005, 100_000, first + TICKS + 100_000, first).unwrap();
        assert_eq!(b, TICKS);
    }

    fn solid(w: usize, h: usize, b: u8, g: u8, r: u8) -> Vec<u8> {
        (0..w * h).flat_map(|_| [b, g, r, 255]).collect()
    }

    #[test]
    fn nv12_weiss_schwarz_farbe() {
        let (w, h) = (4, 4);
        let mut out = vec![0u8; nv12_len(w, h)];
        bgra_to_nv12(&solid(w, h, 255, 255, 255), w, h, &mut out);
        assert!(out[..16].iter().all(|&y| y == 235), "{:?}", &out[..16]);
        assert!(out[16..].iter().all(|&c| c == 128));
        bgra_to_nv12(&solid(w, h, 0, 0, 0), w, h, &mut out);
        assert!(out[..16].iter().all(|&y| y == 16));
        // Rot: Y≈63, U≈102, V≈240
        bgra_to_nv12(&solid(w, h, 0, 0, 255), w, h, &mut out);
        assert!((out[0] as i32 - 63).abs() <= 1, "{}", out[0]);
        assert!((out[16] as i32 - 102).abs() <= 1, "{}", out[16]);
        assert!((out[17] as i32 - 240).abs() <= 1, "{}", out[17]);
        // Blau: Y≈32, U≈240, V≈118
        bgra_to_nv12(&solid(w, h, 255, 0, 0), w, h, &mut out);
        assert!((out[0] as i32 - 32).abs() <= 1);
        assert_eq!(out[16], 240);
        assert!((out[17] as i32 - 118).abs() <= 1, "{}", out[17]);
    }

    #[test]
    fn nv12_viele_threads_gleich_einthread() {
        // Großes Bild nimmt den Mehr-Thread-Weg; Ergebnis muss pro Zeilenpaar stimmen.
        let (w, h) = (640, 360);
        let img: Vec<u8> = (0..w * h * 4).map(|i| ((i * 7 + i / 13) % 251) as u8).collect();
        let mut big = vec![0u8; nv12_len(w, h)];
        bgra_to_nv12(&img, w, h, &mut big);
        // Referenz: 2×2-Blöcke einzeln
        for by in [0usize, 100, 179] {
            for bx in [0usize, 50, 319] {
                let mut blk = vec![0u8; 16];
                for yy in 0..2 {
                    for xx in 0..2 {
                        let s = ((by * 2 + yy) * w + bx * 2 + xx) * 4;
                        let d = (yy * 2 + xx) * 4;
                        // 2×2-Block als 2×2-Bild
                        blk[d..d + 4].copy_from_slice(&img[s..s + 4]);
                    }
                }
                let mut small = vec![0u8; nv12_len(2, 2)];
                bgra_to_nv12(&blk, 2, 2, &mut small);
                assert_eq!(big[by * 2 * w + bx * 2], small[0]);
                assert_eq!(big[w * h + by * w + bx * 2], small[4]);
                assert_eq!(big[w * h + by * w + bx * 2 + 1], small[5]);
            }
        }
    }

    #[test]
    fn skalieren_mittelt() {
        // 4×4, linke Hälfte schwarz, rechte weiß → 2×2: je Spalte unverändert
        let (w, h) = (4usize, 4usize);
        let mut src = vec![0u8; w * h * 4];
        for y in 0..h {
            for x in 0..w {
                let v = if x >= 2 { 255 } else { 0 };
                src[(y * w + x) * 4..][..4].copy_from_slice(&[v, v, v, 255]);
            }
        }
        let mut dst = vec![0u8; 2 * 2 * 4];
        crop_scale_bgra(&src, w * 4, (0, 0, 4, 4), &mut dst, 2, 2);
        assert_eq!(&dst[..4], &[0, 0, 0, 255]);
        assert_eq!(&dst[4..8], &[255, 255, 255, 255]);
        // 1 Pixel breit → 4 Mittelung aus 4
        let mut dst = vec![0u8; 4];
        crop_scale_bgra(&src, w * 4, (0, 0, 4, 4), &mut dst, 1, 1);
        assert_eq!(dst[0], 128);
    }

    #[test]
    fn ausschnitt_ohne_skalierung_und_mit_stride() {
        let stride = 10 * 4 + 8; // Zeilenpolster
        let mut src = vec![0u8; stride * 6];
        for y in 0..6 {
            for x in 0..10 {
                src[y * stride + x * 4..][..4].copy_from_slice(&[x as u8, y as u8, 0, 255]);
            }
        }
        let mut dst = vec![0u8; 3 * 2 * 4];
        crop_scale_bgra(&src, stride, (4, 2, 3, 2), &mut dst, 3, 2);
        assert_eq!(&dst[..4], &[4, 2, 0, 255]);
        assert_eq!(&dst[(3 + 2) * 4..][..4], &[6, 3, 0, 255]);
    }

    #[test]
    fn grosses_bild_mehrere_threads() {
        let (w, h) = (800usize, 600usize);
        let src: Vec<u8> = (0..w * h * 4).map(|i| (i % 255) as u8).collect();
        let mut dst = vec![0u8; 400 * 300 * 4];
        crop_scale_bgra(&src, w * 4, (0, 0, w, h), &mut dst, 400, 300);
        // Referenz: erster Zielpixel = Mittel der ersten 2×2
        let avg = |c: usize| -> u8 {
            let s: u32 = [0usize, 4, w * 4, w * 4 + 4].iter().map(|o| src[o + c] as u32).sum();
            ((s + 2) / 4) as u8
        };
        assert_eq!(dst[0], avg(0));
        assert_eq!(dst[2], avg(2));
    }

    #[test]
    fn zeilen_umdrehen() {
        let src = [1u8, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4];
        let mut out = Vec::new();
        rows_to_top_down(&src, 8, 2, 2, &mut out);
        assert_eq!(out, src);
        rows_to_top_down(&src, -8, 2, 2, &mut out);
        assert_eq!(out, [3, 3, 3, 3, 4, 4, 4, 4, 1, 1, 1, 1, 2, 2, 2, 2]);
    }

    #[test]
    fn klick_ring() {
        let (w, h) = (100usize, 100usize);
        let mut img = solid(w, h, 200, 200, 200);
        draw_click(&mut img, w, h, 50.0, 50.0, 20.0, 0.0);
        // Mitte dunkler als Umgebung, Ring (Abstand ~ r) heller/weiß, außerhalb unverändert
        let at = |x: usize, y: usize| img[(y * w + x) * 4];
        assert!(at(50, 50) < 200);
        assert!(at(50, 5) == 200);
        let ring_px = (0..100).map(|x| at(x, 50)).max().unwrap();
        assert!(ring_px > 220, "{ring_px}");
        // Nach Ablauf: nichts mehr
        let mut img2 = solid(w, h, 200, 200, 200);
        draw_click(&mut img2, w, h, 50.0, 50.0, 20.0, CLICK_SECS);
        assert!(img2.iter().step_by(4).all(|&b| b == 200));
        // Am Rand: kein Absturz
        draw_click(&mut img2, w, h, -5.0, 120.0, 20.0, 0.1);
        draw_click(&mut img2, w, h, 99.0, 0.0, 20.0, 0.1);
    }
}
