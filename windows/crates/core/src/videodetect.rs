//! Auto-Zensur im Video (`VideoRedactor.detect`): Texterkennung auf Einzelbildern alle `step`
//! Sekunden, Treffer werden zu Zeitbereichen verbunden.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{bail, Result};

use crate::geometry::Rect;
use crate::model::{Finding, RedactStyle, SensitiveKind, TextLine, VideoRedaction};
use crate::sensitive;
use crate::signature::FrameSignature;
use crate::RgbaImage;

pub struct DetectParams<'a> {
    pub start: f64,
    pub end: f64,
    pub step: f64,
    /// Volle Videogröße in Pixeln; Bilder von `frame_at` dürfen kleiner sein (≤ 2048), Funde werden hochgerechnet.
    pub video_width: f64,
    pub video_height: f64,
    pub style: RedactStyle,
    pub kinds: &'a BTreeSet<SensitiveKind>,
    pub cancel: &'a AtomicBool,
}

struct Track {
    rect: Rect,
    text: String,
    first: f64,
    last: f64,
}

fn iou(a: &Rect, b: &Rect) -> f64 {
    let i = a.intersection(b);
    if i.is_null() {
        return 0.0;
    }
    let inter = i.width * i.height;
    inter / (a.width * a.height + b.width * b.height - inter)
}

/// `frame_at(t)` liefert das Bild zum Zeitpunkt t (oder `None`), `ocr` die Zeilen eines Bildes.
/// Unveränderte Bilder (`FrameSignature`) übernehmen die Funde des vorigen. Spuren mit gleichem
/// Text und IoU > 0,3 werden verbunden; Ergebnis: Rechteck um 25 % der Höhe erweitert, Zeitbereich
/// um `step` erweitert (auf start/end begrenzt), `auto = true`. Abbruch → `Err`.
pub fn detect(
    params: &DetectParams,
    frame_at: &mut dyn FnMut(f64) -> Option<RgbaImage>,
    ocr: &mut dyn FnMut(&RgbaImage) -> Vec<TextLine>,
    progress: &mut dyn FnMut(f64),
) -> Result<Vec<VideoRedaction>> {
    let (start, end, step) = (params.start, params.end, params.step);
    if step.is_nan() || step <= 0.0 {
        bail!("Schrittweite muss positiv sein");
    }
    let samples = (((end - start) / step).ceil().max(0.0) as usize + 1).max(1);

    let mut open: Vec<Track> = Vec::new();
    let mut done: Vec<Track> = Vec::new();
    let mut last_signature: Option<FrameSignature> = None;
    let mut last_findings: Option<Vec<Finding>> = None;
    for i in 0..samples {
        if params.cancel.load(Ordering::Relaxed) {
            bail!("abgebrochen");
        }
        let t = end.min(start + i as f64 * step);
        let Some(frame) = frame_at(t) else { continue };
        // Bildschirmaufnahmen stehen oft still: unverändertes Bild → Funde vom letzten Mal übernehmen.
        let signature = FrameSignature::new(&frame);
        let findings: Vec<Finding> = match (&last_signature, &last_findings) {
            (Some(last), Some(cached)) if signature.matches(last) => cached.clone(),
            _ => {
                let f = if frame.width() as f64 == params.video_width.trunc() { 1.0 } else { params.video_width / frame.width() as f64 };
                let lines = ocr(&frame);
                sensitive::detect(&lines, params.kinds)
                    .into_iter()
                    .map(|fd| Finding { rect: fd.rect.scaled(f), kind: fd.kind, text: fd.text })
                    .collect()
            }
        };
        last_signature = Some(signature);
        last_findings = Some(findings.clone());

        let mut seen: BTreeSet<usize> = BTreeSet::new();
        for f in &findings {
            if let Some(idx) = open.iter().position(|o| o.text == f.text && iou(&o.rect, &f.rect) > 0.3) {
                open[idx].last = t;
                open[idx].rect = open[idx].rect.union(&f.rect);
                seen.insert(idx);
            } else {
                open.push(Track { rect: f.rect, text: f.text.clone(), first: t, last: t });
                seen.insert(open.len() - 1);
            }
        }
        let mut still = Vec::new();
        for (idx, track) in open.drain(..).enumerate() {
            if seen.contains(&idx) {
                still.push(track);
            } else {
                done.push(track);
            }
        }
        open = still;
        progress((i + 1) as f64 / samples as f64);
    }
    done.append(&mut open);
    // Zwischen zwei Stichproben kann der Text schon/noch sichtbar sein — Zeitbereich großzügig erweitern.
    Ok(done
        .into_iter()
        .map(|track| {
            let pad = track.rect.height * 0.25;
            let mut r = VideoRedaction::new(track.rect.inset(-pad, -pad), start.max(track.first - step), end.min(track.last + step), params.style);
            r.auto = true;
            r
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::TextWord;
    use image::Rgba;

    fn all() -> BTreeSet<SensitiveKind> {
        SensitiveKind::ALL.into_iter().collect()
    }

    /// Fake-Video: Bild `n` hat einen Farbton je Szene, damit die Signatur Wechsel erkennt.
    fn frame(shade: u8) -> RgbaImage {
        RgbaImage::from_pixel(160, 90, Rgba([shade, shade, shade, 255]))
    }

    fn mail_line(x: f64, y: f64) -> TextLine {
        TextLine::from_words(vec![
            TextWord { text: "Mail:".into(), rect: Rect::new(x, y, 40.0, 20.0) },
            TextWord { text: "a.b@example.com".into(), rect: Rect::new(x + 50.0, y, 120.0, 20.0) },
        ])
    }

    fn params<'a>(kinds: &'a BTreeSet<SensitiveKind>, cancel: &'a AtomicBool) -> DetectParams<'a> {
        DetectParams { start: 0.0, end: 10.0, step: 1.0, video_width: 320.0, video_height: 180.0, style: RedactStyle::Solid, kinds, cancel }
    }

    #[test]
    fn merges_tracks_pads_and_scales() {
        let kinds = all();
        let cancel = AtomicBool::new(false);
        // Text von 3 s bis 6 s sichtbar (Szene mit Grauwert 200), sonst 50
        let mut frame_at = |t: f64| Some(frame(if (3.0..=6.0).contains(&t) { 200 } else { 50 }));
        let mut ocr_calls = 0;
        let mut ocr = |img: &RgbaImage| {
            ocr_calls += 1;
            if img.get_pixel(0, 0)[0] == 200 { vec![mail_line(10.0, 20.0)] } else { vec![] }
        };
        let mut last_p = 0.0;
        let res = detect(&params(&kinds, &cancel), &mut frame_at, &mut ocr, &mut |p| last_p = p).unwrap();
        assert_eq!(res.len(), 1);
        let r = &res[0];
        assert!(r.auto);
        assert_eq!(r.style, RedactStyle::Solid);
        // Bild 160 breit, Video 320 → Faktor 2; Fund 60,20 120×20 → 120,40 240×40, Rand 25 % von 40 = 10
        assert_eq!(r.rect, Rect::new(110.0, 30.0, 260.0, 60.0));
        assert_eq!((r.start, r.end), (2.0, 7.0));
        assert!((last_p - 1.0).abs() < 1e-9);
        // OCR nur bei Szenenwechsel: 0–2 (1×), 3–6 (1×), 7–10 (1×)
        assert_eq!(ocr_calls, 3);
    }

    #[test]
    fn separate_appearances_stay_separate_and_clamp_to_range() {
        let kinds = all();
        let cancel = AtomicBool::new(false);
        let visible = |t: f64| t <= 1.0 || (6.0..=10.0).contains(&t);
        let mut frame_at = |t: f64| Some(frame(if visible(t) { 200 } else { 50 }));
        let mut ocr = |img: &RgbaImage| if img.get_pixel(0, 0)[0] == 200 { vec![mail_line(10.0, 20.0)] } else { vec![] };
        let res = detect(&params(&kinds, &cancel), &mut frame_at, &mut ocr, &mut |_| {}).unwrap();
        assert_eq!(res.len(), 2);
        let mut ranges: Vec<_> = res.iter().map(|r| (r.start, r.end)).collect();
        ranges.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(ranges, vec![(0.0, 2.0), (5.0, 10.0)]);
    }

    #[test]
    fn different_text_or_position_makes_new_track() {
        let kinds = all();
        let cancel = AtomicBool::new(false);
        let mut n = 0;
        let mut frame_at = |_t: f64| {
            n += 1;
            Some(frame((n * 40) as u8)) // jedes Bild anders → immer OCR
        };
        let mut k = 0;
        let mut ocr = |_: &RgbaImage| {
            k += 1;
            vec![mail_line(10.0, if k <= 2 { 20.0 } else { 70.0 })]
        };
        let mut p = params(&kinds, &cancel);
        p.end = 3.0;
        let res = detect(&p, &mut frame_at, &mut ocr, &mut |_| {}).unwrap();
        // Bild 1+2 gleiche Stelle → eine Spur; Bild 3 und 4: neue Stelle → zweite Spur
        assert_eq!(res.len(), 2);
    }

    #[test]
    fn cancel_and_missing_frames() {
        let kinds = all();
        let cancel = AtomicBool::new(true);
        let mut frame_at = |_t: f64| Some(frame(1));
        let mut ocr = |_: &RgbaImage| vec![];
        assert!(detect(&params(&kinds, &cancel), &mut frame_at, &mut ocr, &mut |_| {}).is_err());
        let cancel = AtomicBool::new(false);
        let mut none = |_t: f64| None;
        let res = detect(&params(&kinds, &cancel), &mut none, &mut ocr, &mut |_| {}).unwrap();
        assert!(res.is_empty());
    }

    #[test]
    fn full_size_frames_not_scaled() {
        let kinds = all();
        let cancel = AtomicBool::new(false);
        let mut p = params(&kinds, &cancel);
        p.video_width = 160.0;
        p.end = 0.0;
        let mut frame_at = |_t: f64| Some(frame(9));
        let mut ocr = |_: &RgbaImage| vec![mail_line(10.0, 20.0)];
        let res = detect(&p, &mut frame_at, &mut ocr, &mut |_| {}).unwrap();
        assert_eq!(res.len(), 1);
        assert_eq!(res[0].rect, Rect::new(60.0 - 5.0, 20.0 - 5.0, 120.0 + 10.0, 20.0 + 10.0));
    }
}
