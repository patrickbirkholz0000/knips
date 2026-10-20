//! Export: zensiertes/gekürztes MP4, GIF, Testvideo. Alles synchron auf dem aufrufenden Thread.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

use anyhow::{anyhow, bail, Result};
use knips_core::gifenc::GifWriter;
use knips_core::imageops;
use knips_core::model::VideoDocument;
use knips_core::redact;
use knips_core::RgbaImage;

use super::pure;
use super::reader::{AudioReader, FrameReader};
use super::util::*;
use super::writer::{hevc_encoder_available, Mp4Writer, VideoSpec};
use super::{probe, VideoInfo};

const CANCELLED: &str = "Der Export wurde abgebrochen.";

/// RGBA-Bild → NV12 in der Größe `ew × eh` (gerade; schneidet bei ungeraden Maßen den Rest ab).
fn to_nv12(img: &RgbaImage, ew: u32, eh: u32, nv12: &mut Vec<u8>) {
    let bgra = imageops::to_bgra(img);
    let (w, h) = (img.width() as usize, img.height() as usize);
    let (ew, eh) = (ew as usize, eh as usize);
    nv12.resize(pure::nv12_len(ew, eh), 0);
    if (w, h) == (ew, eh) {
        pure::bgra_to_nv12(&bgra, ew, eh, nv12);
    } else {
        let mut cropped = vec![0u8; ew * eh * 4];
        pure::crop_scale_bgra(&bgra, w * 4, (0, 0, ew.min(w), eh.min(h)), &mut cropped, ew, eh);
        pure::bgra_to_nv12(&cropped, ew, eh, nv12);
    }
}

fn remove(path: &Path) {
    let _ = std::fs::remove_file(path);
}

type AudioBlock = (i64, i64, windows::Win32::Media::MediaFoundation::IMFSample);

/// Schreibt Tonblöcke im Bereich `[start_t, end_t)` mit auf den Exportanfang verschobener Zeit.
/// Mit `limit` (Zeit im Ausgang) hält sie an, sobald ein Block darüber liegt (der Block bleibt in
/// `pending`). Liefert `true`, wenn der Ton zu Ende ist.
fn pump_audio(
    a: &AudioReader,
    writer: &Mp4Writer,
    pending: &mut Option<AudioBlock>,
    start_t: i64,
    end_t: i64,
    limit: Option<i64>,
) -> Result<bool> {
    loop {
        let item = match pending.take() {
            Some(p) => Some(p),
            None => a.next()?,
        };
        let Some((ts, dur, sample)) = item else { return Ok(true) };
        if ts >= end_t {
            return Ok(true);
        }
        if ts + dur <= start_t {
            continue;
        }
        let rel = (ts - start_t).max(0);
        if limit.is_some_and(|l| rel > l) {
            *pending = Some((ts, dur, sample));
            return Ok(false);
        }
        // SAFETY: Die Probe gehört uns; Zeit und Dauer werden nur gesetzt.
        unsafe {
            sample.SetSampleTime(rel).ctx("Tonzeit")?;
            sample.SetSampleDuration(dur).ctx("Tondauer")?;
        }
        writer.write_audio(&sample)?;
    }
}

/// Zensiertes, gekürztes MP4 (H.264; HEVC-Quellen bleiben HEVC). Ton wird mitgenommen.
///
/// Das Ergebnis hat konstante Bildrate (`pure::export_fps` der wirksamen Quellrate: 24…60, sonst 30):
/// Zensurfelder können mitten in einem langen, unveränderten Quellbild beginnen oder sich bewegen,
/// das gelingt nur, wenn jedes Ausgabebild seine eigene Zeit bekommt. Bildschirmaufnahmen haben
/// variable Bildrate — stehende Quellbilder werden zeitgenau wiederholt (`frame_at`).
pub fn export_mp4(
    src: &Path,
    dst: &Path,
    doc: &VideoDocument,
    scale: f64,
    progress: &mut dyn FnMut(f64),
    cancel: &AtomicBool,
) -> Result<()> {
    let _com = enter()?;
    let r = export_mp4_inner(src, dst, doc, scale, progress, cancel);
    if r.is_err() {
        remove(dst);
    }
    r
}

fn export_mp4_inner(
    src: &Path,
    dst: &Path,
    doc: &VideoDocument,
    scale: f64,
    progress: &mut dyn FnMut(f64),
    cancel: &AtomicBool,
) -> Result<()> {
    let info: VideoInfo = probe(src)?;
    let start = doc.trim_start.unwrap_or(0.0).clamp(0.0, info.duration.max(0.0));
    let end = doc.trim_end.unwrap_or(info.duration).clamp(start, info.duration.max(start));
    let fps = pure::export_fps(info.fps);
    let count = pure::export_frame_count(end - start, fps);
    log::info!("Export: Quelle {:.2} fps (wirksam) → {fps} fps, {count} Bilder", info.fps);
    let (ew, eh) = (pure::even(info.width), pure::even(info.height));

    let mut frames = FrameReader::open(src, None)?;
    let mut audio = if info.has_audio { AudioReader::open(src) } else { None };
    if let Some(a) = &audio {
        a.seek(pure::secs_to_ticks(start))?;
    }

    let hevc = info.hevc && hevc_encoder_available();
    let spec = VideoSpec { w: ew, h: eh, fps, hevc, bitrate: pure::export_bitrate(ew, eh, fps, hevc), hardware: true };
    let created = Mp4Writer::create_with_fallback(dst, &spec, audio.as_ref().map(|a| &a.pcm))?;
    if audio.is_some() && !created.audio {
        audio = None;
    }
    let writer = created.writer;

    let start_t = pure::secs_to_ticks(start);
    let end_t = pure::secs_to_ticks(end);
    let mut pending_audio: Option<AudioBlock> = None;
    let mut audio_done = audio.is_none();
    let mut nv12 = Vec::new();

    for i in 0..count {
        if cancel.load(Ordering::Relaxed) {
            bail!(CANCELLED);
        }
        let pts = pure::cfr_pts(i, fps);
        let t = start + pure::ticks_to_secs(pts);
        let mut frame = frames.frame_at(t)?.ok_or_else(|| anyhow!("Das Video enthält kein Bild."))?;
        let active = doc.active_at(t);
        if !active.is_empty() {
            redact::apply(&mut frame, &active, scale);
        }
        to_nv12(&frame, ew, eh, &mut nv12);
        let dur = pure::cfr_pts(i + 1, fps) - pts;
        writer.write_video(&nv12, pts, dur)?;

        // Ton bis eine Sekunde über das aktuelle Bild hinaus schreiben (Verschachtelung).
        if let (Some(a), false) = (&audio, audio_done) {
            audio_done = pump_audio(a, &writer, &mut pending_audio, start_t, end_t, Some(pts + pure::TICKS))?;
        }
        progress(((i + 1) as f64 / count as f64).min(0.99));
    }
    // Restlichen Ton schreiben.
    if let (Some(a), false) = (&audio, audio_done) {
        pump_audio(a, &writer, &mut pending_audio, start_t, end_t, None)?;
    }
    if cancel.load(Ordering::Relaxed) {
        bail!(CANCELLED);
    }
    writer.finalize()?;
    progress(1.0);
    Ok(())
}

/// GIF mit `fps` Bildern pro Sekunde, Breite ≤ `width`. Liefert die Bildgröße.
#[allow(clippy::too_many_arguments)]
pub fn export_gif(
    src: &Path,
    dst: &Path,
    doc: &VideoDocument,
    scale: f64,
    fps: u32,
    width: u32,
    progress: &mut dyn FnMut(f64),
    cancel: &AtomicBool,
) -> Result<(u32, u32)> {
    let _com = enter()?;
    let r = export_gif_inner(src, dst, doc, scale, fps.max(1), width, progress, cancel);
    if r.is_err() {
        remove(dst);
    }
    r
}

#[allow(clippy::too_many_arguments)]
fn export_gif_inner(
    src: &Path,
    dst: &Path,
    doc: &VideoDocument,
    scale: f64,
    fps: u32,
    width: u32,
    progress: &mut dyn FnMut(f64),
    cancel: &AtomicBool,
) -> Result<(u32, u32)> {
    let info = probe(src)?;
    let start = doc.trim_start.unwrap_or(0.0).clamp(0.0, info.duration.max(0.0));
    let end = doc.trim_end.unwrap_or(info.duration).clamp(start, info.duration.max(start));
    let count = pure::gif_count(end - start, fps);
    let delay = 1.0 / fps as f64;
    let mut frames = FrameReader::open(src, None)?;
    let (vw, vh) = frames.size();
    let (gw, gh) = pure::fit_width(vw, vh, width);
    let mut gif = GifWriter::create(dst, gw, gh)?;
    let mut scaled = vec![0u8; gw as usize * gh as usize * 4];
    for i in 0..count {
        if cancel.load(Ordering::Relaxed) {
            bail!("Der Export wurde abgebrochen.");
        }
        let t = start + i as f64 * delay;
        let mut frame = frames.frame_at(t)?.ok_or_else(|| anyhow!("Das Video enthält kein Bild."))?;
        let active = doc.active_at(t);
        if !active.is_empty() {
            redact::apply(&mut frame, &active, scale);
        }
        let small = if (frame.width(), frame.height()) == (gw, gh) {
            frame
        } else {
            let bgra = imageops::to_bgra(&frame);
            pure::crop_scale_bgra(&bgra, frame.width() as usize * 4, (0, 0, frame.width() as usize, frame.height() as usize), &mut scaled, gw as usize, gh as usize);
            imageops::from_bgra(gw, gh, gw as usize * 4, &scaled, true)
        };
        gif.push(&small, delay)?;
        progress((i + 1) as f64 / count as f64);
    }
    let written = gif.finish()?;
    log::info!("GIF: {written} von {count} Bildern geschrieben");
    Ok((gw, gh))
}

/// HEVC schreiben **und** lesen können (siehe `media::hevc_available`): winziges Testvideo im
/// Temp-Ordner, einmal pro Prozess.
pub fn hevc_usable() -> bool {
    static R: OnceLock<bool> = OnceLock::new();
    *R.get_or_init(|| {
        if !hevc_encoder_available() {
            return false;
        }
        let path = std::env::temp_dir().join(format!("knips-hevc-probe-{}.mp4", std::process::id()));
        let r = (|| -> Result<bool> {
            let img = RgbaImage::from_pixel(640, 360, image::Rgba([70, 110, 190, 255]));
            write_test_video(&path, 640, 360, 30, 3, true, &mut |_| img.clone())?;
            let info = probe(&path)?;
            if !info.hevc {
                return Ok(false); // Schreiber ist auf H.264 ausgewichen
            }
            let mut reader = FrameReader::open(&path, None)?;
            Ok(reader.frame_at(0.0)?.is_some())
        })();
        remove(&path);
        match r {
            Ok(ok) => {
                log::info!("HEVC {}", if ok { "nutzbar" } else { "nicht nutzbar (Encoder weicht auf H.264 aus)" });
                ok
            }
            Err(e) => {
                log::info!("HEVC nicht nutzbar (Decoder fehlt?): {e:#}");
                false
            }
        }
    })
}

/// Testvideo aus erzeugten Bildern schreiben (Selbsttests `track`, `video`).
pub fn write_test_video(
    path: &Path,
    width: u32,
    height: u32,
    fps: u32,
    count: usize,
    hevc: bool,
    frame: &mut dyn FnMut(usize) -> RgbaImage,
) -> Result<()> {
    let fps = fps.max(1);
    let bounds: Vec<i64> = (0..=count).map(|i| pure::cfr_pts(i, fps)).collect();
    write_timed(path, width, height, fps, &bounds, hevc, frame)
}

/// Testvideo mit variabler Bildrate wie eine Bildschirmaufnahme: Bild `i` beginnt bei `times[i]`
/// (Sekunden, aufsteigend) und steht bis zum nächsten bzw. bis `duration`. Angabe im Container 30 fps.
pub fn write_test_video_vfr(
    path: &Path,
    width: u32,
    height: u32,
    times: &[f64],
    duration: f64,
    frame: &mut dyn FnMut(usize) -> RgbaImage,
) -> Result<()> {
    let mut bounds: Vec<i64> = times.iter().map(|&t| pure::secs_to_ticks(t)).collect();
    bounds.push(pure::secs_to_ticks(duration));
    if bounds.windows(2).any(|w| w[1] <= w[0]) {
        bail!("Zeiten müssen aufsteigen und vor dem Ende liegen.");
    }
    write_timed(path, width, height, 30, &bounds, false, frame)
}

/// `bounds`: Beginn jedes Bildes und zuletzt das Ende (Länge = Bildanzahl + 1), 100 ns.
fn write_timed(
    path: &Path,
    width: u32,
    height: u32,
    fps: u32,
    bounds: &[i64],
    hevc: bool,
    frame: &mut dyn FnMut(usize) -> RgbaImage,
) -> Result<()> {
    let _com = enter()?;
    if bounds.len() < 2 {
        bail!("Keine Bilder zum Schreiben.");
    }
    let (w, h) = (pure::even(width), pure::even(height));
    let hevc = hevc && hevc_encoder_available();
    let spec = VideoSpec { w, h, fps, hevc, bitrate: pure::bitrate(w, h, fps, hevc), hardware: true };
    let r = (|| -> Result<()> {
        let writer = Mp4Writer::create_with_fallback(path, &spec, None)?.writer;
        let mut nv12 = Vec::new();
        for (i, span) in bounds.windows(2).enumerate() {
            let img = frame(i);
            to_nv12(&img, w, h, &mut nv12);
            writer.write_video(&nv12, span[0], span[1] - span[0])?;
        }
        writer.finalize()
    })();
    if r.is_err() {
        remove(path);
    }
    r
}
