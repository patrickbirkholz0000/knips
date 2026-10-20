//! Bild des Taskleisten-Symbols: das Zeichen von Knips (docs/design.md, „Logo und Wortmarke“) — vier Ecken und
//! ein Balken, einfarbig; während eines Videos statt des Balkens ein roter Punkt. Gleiche Rechnung wie
//! `BrandGeometry.templateImage` (Sources/Knips/UI/BrandMark.swift): Das Zeichen füllt 14 von 16 px, Strich und
//! Kanten liegen auf ganzen Pixeln, damit es bei 100 % (16 px) bis 200 % (32 px) scharf bleibt.
//! Reine Rechnung ohne Tauri, damit sie sich überall prüfen lässt.

/// Hell auf dunkler Taskleiste (Papier), dunkel auf heller (Tinte).
const PAPER: [u8; 3] = [0xF4, 0xF5, 0xF7];
const INK: [u8; 3] = [0x15, 0x16, 0x1A];
/// Aufnahme-Rot (nur während eines Videos).
const RECORD: [u8; 3] = [0xE8, 0x52, 0x3F];

// Geometrie in Einheiten 0…100 wie `BrandGeometry`.
const LO: f32 = 22.0;
const HI: f32 = 78.0;
const ARM: f32 = 17.0;
const STROKE: f32 = 9.0;
const BAR_HALF: f32 = 17.0; // Balken x 33…67
const DOT_R: f32 = 9.0;

/// RGBA (nicht vormultipliziert), `size`×`size`. `light_taskbar`: Taskleiste im hellen Modus.
pub fn render(size: u32, light_taskbar: bool, recording: bool) -> Vec<u8> {
    let s = size as f32;
    let extent = HI - LO + STROKE; // Außenkante zu Außenkante: 65 Einheiten
    let unit = s * 14.0 / 16.0 / extent;
    let w = (STROKE * unit).round().max(1.0);
    // Mittellinien so, dass die Kanten auf Pixelgrenzen liegen.
    let near = (s / 2.0 - extent / 2.0 * unit).round() + w / 2.0;
    let far = s - near;
    // Schenkel so lang, dass ihr rundes Ende auf einer Pixelgrenze endet.
    let arm = (ARM * unit + w).round() - w;
    // Balken mittig mit Enden auf Pixelgrenzen; bei ungerader Strichstärke eine halbe Zeile tiefer, damit die
    // Kanten scharf bleiben.
    let mid_x = s / 2.0;
    let mid_y = (s / 2.0 - w / 2.0).round() + w / 2.0;
    let half = mid_x - (mid_x - BAR_HALF * unit).round();
    let dot = (DOT_R * unit).round().max(1.5);

    let mut segments = Vec::with_capacity(8);
    for (x, y, dx, dy) in [(near, near, 1.0, 1.0), (far, near, -1.0, 1.0), (far, far, -1.0, -1.0), (near, far, 1.0, -1.0)] {
        segments.push(((x, y + dy * arm), (x, y)));
        segments.push(((x, y), (x + dx * arm, y)));
    }
    let ink = if light_taskbar { INK } else { PAPER };

    let mut rgba = vec![0u8; (size * size * 4) as usize];
    for py in 0..size {
        for px in 0..size {
            let p = (px as f32 + 0.5, py as f32 + 0.5);
            let d_corners = segments.iter().map(|&(a, b)| dist_segment(p, a, b)).fold(f32::MAX, f32::min) - w / 2.0;
            let d_mark = if recording {
                ((p.0 - s / 2.0).powi(2) + (p.1 - s / 2.0).powi(2)).sqrt() - dot
            } else {
                dist_segment(p, (mid_x - half + w / 2.0, mid_y), (mid_x + half - w / 2.0, mid_y)) - w / 2.0
            };
            // Abdeckung ≈ Kastenfilter über das Pixel.
            let a1 = (0.5 - d_corners).clamp(0.0, 1.0);
            let a2 = (0.5 - d_mark).clamp(0.0, 1.0);
            let alpha = (a1 + a2).min(1.0);
            if alpha <= 0.0 {
                continue;
            }
            let mark = if recording { RECORD } else { ink };
            let i = ((py * size + px) * 4) as usize;
            for c in 0..3 {
                rgba[i + c] = ((ink[c] as f32 * a1 + mark[c] as f32 * a2) / (a1 + a2)).round() as u8;
            }
            rgba[i + 3] = (alpha * 255.0).round() as u8;
        }
    }
    rgba
}

fn dist_segment(p: (f32, f32), a: (f32, f32), b: (f32, f32)) -> f32 {
    let (pax, pay, bax, bay) = (p.0 - a.0, p.1 - a.1, b.0 - a.0, b.1 - a.1);
    let len = bax * bax + bay * bay;
    let h = if len > 0.0 { ((pax * bax + pay * bay) / len).clamp(0.0, 1.0) } else { 0.0 };
    ((pax - bax * h).powi(2) + (pay - bay * h).powi(2)).sqrt()
}

#[cfg(test)]
mod tests {
    use super::render;

    fn alpha(img: &[u8], size: u32, x: u32, y: u32) -> u8 {
        img[((y * size + x) * 4 + 3) as usize]
    }

    #[test]
    fn crisp_corners_and_mark_at_every_scale() {
        for size in [16, 20, 24, 32, 40] {
            // Gleiche Rechnung wie `render`: erste Zeile des oberen Schenkels.
            let s = size as f32;
            let unit = s * 14.0 / 16.0 / 65.0;
            let w = (9.0 * unit).round().max(1.0);
            let top = (s / 2.0 - 32.5 * unit).round() as u32;
            for (light, recording) in [(false, false), (true, false), (false, true)] {
                let img = render(size, light, recording);
                assert_eq!(img.len(), (size * size * 4) as usize);
                assert_eq!(alpha(&img, size, 0, 0), 0, "{size}: Rand frei");
                let m = size / 2;
                assert_eq!(alpha(&img, size, m, m), 255, "{size}: Mitte gedeckt");
                // Oberer Schenkel links: ganze Zeilen voll deckend, darüber nichts (scharfe Kante).
                for row in top..top + w as u32 {
                    assert_eq!(alpha(&img, size, top + w as u32, row), 255, "{size}: Schenkel Zeile {row}");
                }
                assert_eq!(alpha(&img, size, top + w as u32, top - 1), 0, "{size}: über dem Schenkel frei");
            }
        }
    }

    #[test]
    fn colors_follow_taskbar_and_recording() {
        let size = 32;
        let m = (size / 2) as usize;
        let i = (m * size as usize + m) * 4;
        assert_eq!(&render(size, false, false)[i..i + 3], &[0xF4, 0xF5, 0xF7]);
        assert_eq!(&render(size, true, false)[i..i + 3], &[0x15, 0x16, 0x1A]);
        assert_eq!(&render(size, true, true)[i..i + 3], &[0xE8, 0x52, 0x3F]);
    }
}
