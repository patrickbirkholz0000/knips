//! TODO(Windows): Startfassung = Kopie der Attrappe. Durch die echte Implementierung ersetzen,
//! Signaturen exakt beibehalten (Referenz: `mock/mod.rs`).

use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

use anyhow::{bail, Result};
use knips_core::model::VideoDocument;
use knips_core::RgbaImage;

use crate::types::{IRect, Monitor};

#[derive(Clone, Debug, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoInfo {
    pub duration: f64,
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    pub hevc: bool,
    pub has_audio: bool,
}

pub fn probe(path: &Path) -> Result<VideoInfo> {
    let _ = path;
    bail!("Video nur unter Windows")
}

pub fn hevc_encoder_available() -> bool {
    false
}

/// Bilder aus einem Video lesen, optional verkleinert (längste Kante ≤ `max_size`).
pub struct FrameReader {
    _private: (),
}

impl FrameReader {
    pub fn open(path: &Path, max_size: Option<u32>) -> Result<Self> {
        let _ = (path, max_size);
        bail!("Video nur unter Windows")
    }
    /// Bild, das zum Zeitpunkt `t` (Sekunden) zu sehen ist — genau, nicht das nächste Schlüsselbild.
    pub fn frame_at(&mut self, t: f64) -> Result<Option<RgbaImage>> {
        let _ = t;
        Ok(None)
    }
}

pub fn thumbnail(path: &Path, max_pixel: u32) -> Result<RgbaImage> {
    let _ = (path, max_pixel);
    bail!("Video nur unter Windows")
}

pub struct RecordOptions {
    pub monitor: Monitor,
    /// Aufgenommener Bereich, monitor-lokal, physische Pixel.
    pub rect: IRect,
    /// Ausgabegröße (gerade Zahlen).
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub show_cursor: bool,
    pub show_clicks: bool,
    pub microphone: bool,
    pub hevc: bool,
    pub path: PathBuf,
}

/// Bildschirmaufnahme (Windows.Graphics.Capture → Media Foundation, H.264/HEVC-MP4, AAC-Mikro).
pub struct Recorder {
    _private: (),
}

impl Recorder {
    /// `on_error` kommt, wenn die Aufnahme von selbst abbricht (Monitor weg, Encoder-Fehler).
    pub fn start(opts: RecordOptions, on_error: Box<dyn Fn(String) + Send + Sync>) -> Result<Recorder> {
        let _ = (opts, on_error);
        bail!("Bildschirmaufnahme nur unter Windows")
    }
    /// Beendet und schreibt die Datei fertig; liefert die Dauer in Sekunden.
    pub fn stop(self) -> Result<f64> {
        bail!("Bildschirmaufnahme nur unter Windows")
    }
    /// Verwirft die Aufnahme und löscht die Datei.
    pub fn cancel(self) {}
}

/// Zensiertes, gekürztes MP4 (H.264; HEVC-Quellen bleiben HEVC). Ton wird mitgenommen.
pub fn export_mp4(
    src: &Path,
    dst: &Path,
    doc: &VideoDocument,
    scale: f64,
    progress: &mut dyn FnMut(f64),
    cancel: &AtomicBool,
) -> Result<()> {
    let _ = (src, dst, doc, scale, progress, cancel);
    bail!("Video nur unter Windows")
}

/// GIF mit `fps` Bildern pro Sekunde, Breite ≤ `width`. Liefert die Bildgröße.
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
    let _ = (src, dst, doc, scale, fps, width, progress, cancel);
    bail!("Video nur unter Windows")
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
    let _ = (path, width, height, fps, count, hevc, frame);
    bail!("Video nur unter Windows")
}
