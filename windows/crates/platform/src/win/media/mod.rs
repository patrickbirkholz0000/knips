//! Video unter Windows: Aufnahme (Windows.Graphics.Capture → Media Foundation), Lesen, Export.
//! Signaturen exakt wie in `mock/mod.rs`. Reine Rechen-Helfer (testbar auf dem Mac): `pure.rs`.

use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

use anyhow::Result;
use knips_core::model::VideoDocument;
use knips_core::RgbaImage;

use crate::types::{IRect, Monitor};

mod export;
mod pure;
mod reader;
mod recorder;
mod util;
mod writer;

pub use reader::FrameReader;
pub use recorder::Recorder;

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

/// Fehlermeldung, wenn Media Foundation fehlt (Windows N/KN ohne Media Feature Pack).
pub const MISSING_HINT: &str = "Für Videos braucht Windows das „Media Feature Pack“. Diese Windows-Ausgabe (N/KN) enthält es nicht. \
Installieren unter Einstellungen → Apps → Optionale Features → Feature hinzufügen → „Media Feature Pack“, danach neu starten. \
Screenshots funktionieren auch ohne.";

/// Media Foundation vorhanden? Ohne sind Aufnahme, Video-Editor und Video-/GIF-Export gesperrt.
pub fn available() -> bool {
    util::mf_available()
}

pub fn probe(path: &Path) -> Result<VideoInfo> {
    reader::probe(path)
}

pub fn hevc_encoder_available() -> bool {
    writer::hevc_encoder_available()
}

/// HEVC nutzbar: Encoder vorhanden **und** das Ergebnis lässt sich wieder lesen (Decoder aus der
/// „HEVC-Videoerweiterung“). Ein Grafiktreiber bringt oft nur den Encoder mit — dann wäre jede
/// HEVC-Aufnahme unlesbar. Einmal pro Prozess mit einem winzigen Testvideo geprüft (≈ 0,3 s).
pub fn hevc_available() -> bool {
    export::hevc_usable()
}

pub fn thumbnail(path: &Path, max_pixel: u32) -> Result<RgbaImage> {
    reader::thumbnail(path, max_pixel)
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

/// Zensiertes, gekürztes MP4 (H.264; HEVC-Quellen bleiben HEVC). Ton wird mitgenommen.
pub fn export_mp4(
    src: &Path,
    dst: &Path,
    doc: &VideoDocument,
    scale: f64,
    progress: &mut dyn FnMut(f64),
    cancel: &AtomicBool,
) -> Result<()> {
    export::export_mp4(src, dst, doc, scale, progress, cancel)
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
    export::export_gif(src, dst, doc, scale, fps, width, progress, cancel)
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
    export::write_test_video(path, width, height, fps, count, hevc, frame)
}

/// Testvideo mit variabler Bildrate (wie eine Bildschirmaufnahme): Bild `i` ab `times[i]` Sekunden,
/// das letzte bis `duration` (Selbsttest `video`).
pub fn write_test_video_vfr(
    path: &Path,
    width: u32,
    height: u32,
    times: &[f64],
    duration: f64,
    frame: &mut dyn FnMut(usize) -> RgbaImage,
) -> Result<()> {
    export::write_test_video_vfr(path, width, height, times, duration, frame)
}
