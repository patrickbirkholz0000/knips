//! Video-Editor: Laden, Vorschaubilder, Auto-Zensur, mitlaufende Balken, Export
//! (`VideoEditorModel.swift`, `VideoRedactor.swift`). Lange Arbeiten melden Fortschritt als
//! `video-progress` und lassen sich abbrechen.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::{anyhow, Result};
use knips_core::geometry::Rect;
use knips_core::model::{CaptureItem, Id, RedactStyle, SensitiveKind, TrackPoint, VideoDocument, VideoRedaction};
use knips_core::{imageops, tracker, videodetect, OCR_MAX_PIXEL};
use knips_platform::media::{self, FrameReader, VideoInfo};
use parking_lot::Mutex;
use serde::Serialize;

use crate::app::knips;
use crate::paths;

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct VideoSession {
    pub item: CaptureItem,
    pub document: VideoDocument,
    pub source_path: String,
    pub info: VideoInfo,
    pub scale: f64,
}

#[derive(Serialize, Clone)]
struct Progress {
    id: String,
    progress: f64,
}

#[derive(Default)]
pub struct VideoJobs {
    cancels: Mutex<HashMap<String, Arc<AtomicBool>>>,
}

fn item_of(id: Id) -> Result<CaptureItem> {
    knips().store.item(id).ok_or_else(|| anyhow!("Aufnahme nicht gefunden"))
}

/// Original, sonst die Datei im Ablageordner.
fn source_of(item: &CaptureItem) -> PathBuf {
    let original = knips().store.original_path(item);
    if original.exists() {
        original
    } else {
        PathBuf::from(&item.file_path)
    }
}

impl VideoJobs {
    fn begin(&self, id: Id) -> Arc<AtomicBool> {
        let flag = Arc::new(AtomicBool::new(false));
        self.cancels.lock().insert(id.to_string(), flag.clone());
        flag
    }

    fn end(&self, id: Id) {
        self.cancels.lock().remove(&id.to_string());
    }

    pub fn cancel(&self, id: &str) {
        if let Some(flag) = self.cancels.lock().get(id) {
            flag.store(true, Ordering::SeqCst);
        }
    }

    fn progress(id: Id) -> impl FnMut(f64) {
        let id = id.to_string();
        let mut last = -1.0;
        move |p: f64| {
            // Höchstens alle 1 % senden.
            if (p - last).abs() >= 0.01 || p >= 1.0 {
                last = p;
                knips().emit("video-progress", Progress { id: id.clone(), progress: p.clamp(0.0, 1.0) });
            }
        }
    }

    pub fn open(&self, id: Id) -> Result<VideoSession> {
        let item = item_of(id)?;
        let source = source_of(&item);
        let info = media::probe(&source)?;
        Ok(VideoSession {
            document: knips().store.load_video_document(id),
            source_path: source.to_string_lossy().into_owned(),
            info,
            scale: item.scale.max(1.0),
            item,
        })
    }

    /// `count` Vorschaubilder gleichmäßig über die Länge (Dateien im Temp-Ordner). Es sind Bilder des
    /// Originals, also unzensiert: Ältere dieser Aufnahme werden gelöscht, sobald die neuen da sind;
    /// Löschen der Aufnahme, „Originale löschen“ und der Start der App räumen den Rest weg.
    pub fn thumbnails(&self, id: Id, count: usize) -> Result<Vec<String>> {
        let item = item_of(id)?;
        let source = source_of(&item);
        let duration = media::probe(&source)?.duration;
        let mut reader = FrameReader::open(&source, Some(220))?;
        let dir = paths::video_thumbs_dir();
        paths::ensure(&dir);
        let mut out = vec![];
        for i in 0..count {
            let t = duration * (i as f64 + 0.5) / count as f64;
            if let Ok(Some(frame)) = reader.frame_at(t) {
                let path = dir.join(format!("{id}-{}-{i}.jpg", item.revision));
                std::fs::write(&path, imageops::encode(&frame, knips_core::model::ImageFormat::Jpeg)?)?;
                out.push(path);
            }
        }
        paths::remove_video_thumbs(&id.to_string(), &out);
        Ok(out.into_iter().map(|p| p.to_string_lossy().into_owned()).collect())
    }

    pub fn detect(&self, id: Id, start: f64, end: f64, style: RedactStyle, kinds: BTreeSet<SensitiveKind>) -> Result<Vec<VideoRedaction>> {
        let item = item_of(id)?;
        let source = source_of(&item);
        let info = media::probe(&source)?;
        let cancel = self.begin(id);
        let result = (|| {
            let mut reader = FrameReader::open(&source, Some(OCR_MAX_PIXEL))?;
            let params = videodetect::DetectParams {
                start,
                end,
                step: 0.5,
                video_width: info.width as f64,
                video_height: info.height as f64,
                style,
                kinds: &kinds,
                cancel: &cancel,
            };
            let mut frame_at = |t: f64| reader.frame_at(t).ok().flatten();
            let mut ocr = |img: &knips_core::RgbaImage| knips_platform::ocr::recognize(img).unwrap_or_default();
            let mut progress = Self::progress(id);
            videodetect::detect(&params, &mut frame_at, &mut ocr, &mut progress)
        })();
        self.end(id);
        result
    }

    pub fn track(&self, id: Id, rect: Rect, t0: f64, start: f64, end: f64) -> Result<Vec<TrackPoint>> {
        let item = item_of(id)?;
        let source = source_of(&item);
        let info = media::probe(&source)?;
        let cancel = self.begin(id);
        let result = (|| {
            let mut reader = FrameReader::open(&source, Some(1280))?;
            let params = tracker::TrackParams {
                rect,
                t0,
                start,
                end,
                fps: info.fps,
                video_width: info.width as f64,
                video_height: info.height as f64,
                cancel: &cancel,
            };
            let mut frame_at = |t: f64| reader.frame_at(t).ok().flatten();
            let mut progress = Self::progress(id);
            tracker::track(&params, &mut frame_at, &mut progress)
        })();
        self.end(id);
        result
    }

    /// Bei Änderungen exportieren (gekürzt + zensiert), sonst die Ablage wieder aufs Original zeigen lassen.
    pub fn save(&self, id: Id, document: VideoDocument) -> Result<CaptureItem> {
        let k = knips();
        let item = item_of(id)?;
        if !document.has_edits() {
            return k.store.save_video(None, &document, &item);
        }
        let source = source_of(&item);
        let tmp = paths::temp_dir().join(format!("export-{}.mp4", uuid::Uuid::new_v4()));
        let cancel = self.begin(id);
        let mut progress = Self::progress(id);
        let result = media::export_mp4(&source, &tmp, &document, item.scale.max(1.0), &mut progress, &cancel);
        self.end(id);
        if let Err(err) = result {
            let _ = std::fs::remove_file(&tmp);
            return Err(err);
        }
        let saved = k.store.save_video(Some(&tmp), &document, &item)?;
        crate::telemetry::count("export_mp4");
        Ok(saved)
    }

    /// GIF neben der Datei im Ablageordner; erscheint als Karte.
    pub fn export_gif(&self, id: Id, document: VideoDocument) -> Result<CaptureItem> {
        let k = knips();
        let item = item_of(id)?;
        let source = source_of(&item);
        let info = media::probe(&source)?;
        let settings = k.settings.get();
        let target = unique_gif_path(Path::new(&item.file_path));
        let cancel = self.begin(id);
        let mut progress = Self::progress(id);
        let result = media::export_gif(
            &source,
            &target,
            &document,
            item.scale.max(1.0),
            settings.gif_fps,
            settings.gif_width.min(info.width),
            &mut progress,
            &cancel,
        );
        self.end(id);
        let size = result.inspect_err(|_| {
            let _ = std::fs::remove_file(&target);
        })?;
        let start = document.trim_start.unwrap_or(0.0);
        let end = document.trim_end.unwrap_or(info.duration);
        let gif = k.store.add_gif(&target, size, (end - start).max(0.0));
        crate::telemetry::count("export_gif");
        k.cards.show(gif.clone(), knips_platform::monitors::at_cursor());
        Ok(gif)
    }
}

fn unique_gif_path(file: &Path) -> PathBuf {
    let base = file.with_extension("");
    let mut path = base.with_extension("gif");
    let mut n = 2;
    while path.exists() {
        path = PathBuf::from(format!("{} ({n}).gif", base.to_string_lossy()));
        n += 1;
    }
    path
}
