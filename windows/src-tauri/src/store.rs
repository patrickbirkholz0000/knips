//! Aufnahmen verwalten (`CaptureStore.swift`). Sichtbare Datei im Ablageordner = immer die
//! gerenderte (zensierte) Fassung; Original, Bearbeitungsstand und Vorschaubild liegen in
//! `<items>\<id>\`. Kodieren und Schreiben laufen im Hintergrund, je Aufnahme in Reihe.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use knips_core::imageops;
use knips_core::model::{CaptureItem, CaptureKind, Id, ImageDocument, ImageFormat, VideoDocument};
use knips_core::RgbaImage;
use parking_lot::{Condvar, Mutex};
use uuid::Uuid;

use crate::paths;
use crate::promise::{output_promise, ImagePromise};
use crate::settings::SettingsStore;

/// Ende eines Schreibvorgangs — `wait` blockiert, bis er fertig ist.
#[derive(Clone, Default)]
struct Done(Arc<(Mutex<bool>, Condvar)>);

impl Done {
    fn finish(&self) {
        let (lock, cv) = &*self.0;
        *lock.lock() = true;
        cv.notify_all();
    }
    fn wait(&self) {
        let (lock, cv) = &*self.0;
        let mut done = lock.lock();
        while !*done {
            cv.wait(&mut done);
        }
    }
}

#[derive(Default)]
struct Inner {
    items: Vec<CaptureItem>,
    /// Letzter Schreibvorgang je Aufnahme; der nächste wartet darauf.
    writes: HashMap<Id, Done>,
    pending: HashMap<Id, usize>,
    /// Zuletzt aufgenommene Originale im Speicher — der Editor öffnet sie ohne Umweg über die Platte.
    memory: VecDeque<(Id, Arc<RgbaImage>)>,
    memory_until: Option<Instant>,
    /// Dateinamen, die vergeben, aber noch nicht geschrieben sind.
    reserved: HashSet<PathBuf>,
}

pub struct Store {
    settings: Arc<SettingsStore>,
    inner: Mutex<Inner>,
    on_change: Mutex<Option<Box<dyn Fn(Vec<CaptureItem>) + Send + Sync>>>,
}

impl Store {
    pub fn new(settings: Arc<SettingsStore>) -> Self {
        paths::ensure(&paths::items_dir());
        let store = Self { settings, inner: Mutex::new(Inner::default()), on_change: Mutex::new(None) };
        store.load();
        store
    }

    /// Wird nach jeder Änderung der Liste aufgerufen (App sendet `items-changed`).
    pub fn set_on_change(&self, f: impl Fn(Vec<CaptureItem>) + Send + Sync + 'static) {
        *self.on_change.lock() = Some(Box::new(f));
    }

    fn changed(&self) {
        let items = self.items();
        if let Some(f) = self.on_change.lock().as_ref() {
            f(items);
        }
    }

    pub fn items(&self) -> Vec<CaptureItem> {
        self.inner.lock().items.clone()
    }

    pub fn item(&self, id: Id) -> Option<CaptureItem> {
        self.inner.lock().items.iter().find(|i| i.id == id).cloned()
    }

    pub fn directory(&self, id: Id) -> PathBuf {
        paths::items_dir().join(id.to_string())
    }
    pub fn original_path(&self, item: &CaptureItem) -> PathBuf {
        let name = match item.kind {
            CaptureKind::Image => "original.png",
            CaptureKind::Gif => "original.gif",
            CaptureKind::Video => "original.mp4",
        };
        self.directory(item.id).join(name)
    }
    pub fn document_path(&self, id: Id) -> PathBuf {
        self.directory(id).join("document.json")
    }
    pub fn thumbnail_path(&self, id: Id) -> PathBuf {
        self.directory(id).join("thumb.png")
    }
    fn meta_path(&self, id: Id) -> PathBuf {
        self.directory(id).join("item.json")
    }

    // ------------------------------------------------------------ Anlegen

    /// Legt den Eintrag sofort an; Kodieren und Schreiben laufen im Hintergrund. Das Original bleibt
    /// in voller Auflösung, die Datei im Ablageordner kommt aus `output` (ggf. verkleinert).
    pub fn add_image(self: &Arc<Self>, image: RgbaImage, scale: f64, output: Option<ImagePromise>, name: Option<String>) -> Result<CaptureItem> {
        let settings = self.settings.get();
        let factor = settings.output_factor(scale);
        let image = Arc::new(image);
        let promise = output.unwrap_or_else(|| {
            let src = image.clone();
            output_promise(factor, settings.image_format, move || Some(src.as_ref().clone()))
        });
        let base = name.unwrap_or_else(|| format!("Knips {}", knips_core::format::file_date_now()));
        let output_path = self.unique_output_path(&base, promise.format.extension())?;
        let id = Uuid::new_v4();
        let item = CaptureItem {
            id,
            kind: CaptureKind::Image,
            created_at: chrono::Utc::now().timestamp_millis(),
            file_path: output_path.to_string_lossy().into_owned(),
            pixel_width: ((image.width() as f64) * factor).round() as u32,
            pixel_height: ((image.height() as f64) * factor).round() as u32,
            scale,
            duration: None,
            revision: 1,
            output_scale: Some(scale * factor),
        };
        paths::ensure(&self.directory(id));
        // Vorschaubild sofort (wenige ms) — die Karte zeigt es direkt.
        write_thumbnail(&image, &self.thumbnail_path(id));
        self.persist(&item);
        {
            let mut inner = self.inner.lock();
            inner.reserved.insert(output_path.clone());
            inner.items.insert(0, item.clone());
            remember(&mut inner, id, image.clone());
        }
        // Original verlustfrei in voller Auflösung; bei gleicher Ausgabe dieselben Daten wiederverwenden.
        let same = factor >= 0.999 && promise.format == ImageFormat::Png;
        let original = if same { promise.clone() } else { ImagePromise::of(image.as_ref().clone(), ImageFormat::Png) };
        let original_path = self.original_path(&item);
        let done = self.begin_write(id);
        let this = self.clone();
        std::thread::spawn(move || {
            if let Some(data) = original.data() {
                write_atomic(&original_path, &data);
            }
            if let Some(data) = promise.data() {
                write_atomic(&output_path, &data);
            }
            this.inner.lock().reserved.remove(&output_path);
            this.end_write(id, &done);
        });
        self.changed();
        Ok(item)
    }

    pub fn add_video(&self, temp: &Path, scale: f64) -> Result<CaptureItem> {
        let info = knips_platform::media::probe(temp)?;
        let output = self.unique_output_path(&format!("Knips Aufnahme {}", knips_core::format::file_date_now()), "mp4")?;
        let mut item = CaptureItem {
            id: Uuid::new_v4(),
            kind: CaptureKind::Video,
            created_at: chrono::Utc::now().timestamp_millis(),
            file_path: output.to_string_lossy().into_owned(),
            pixel_width: info.width,
            pixel_height: info.height,
            scale,
            duration: Some(info.duration),
            revision: 0,
            output_scale: None,
        };
        paths::ensure(&self.directory(item.id));
        let original = self.original_path(&item);
        move_file(temp, &original)?;
        link_or_copy(&original, &output)?;
        match knips_platform::media::thumbnail(&output, 640) {
            Ok(thumb) => write_thumbnail(&thumb, &self.thumbnail_path(item.id)),
            Err(err) => log::warn!("Video-Vorschaubild fehlgeschlagen: {err:#}"),
        }
        item.revision = 1;
        self.persist(&item);
        self.inner.lock().items.insert(0, item.clone());
        self.changed();
        Ok(item)
    }

    pub fn add_gif(&self, path: &Path, size: (u32, u32), duration: f64) -> CaptureItem {
        let item = CaptureItem {
            id: Uuid::new_v4(),
            kind: CaptureKind::Gif,
            created_at: chrono::Utc::now().timestamp_millis(),
            file_path: path.to_string_lossy().into_owned(),
            pixel_width: size.0,
            pixel_height: size.1,
            scale: 1.0,
            duration: Some(duration),
            revision: 1,
            output_scale: None,
        };
        paths::ensure(&self.directory(item.id));
        if let Ok(first) = imageops::load(path) {
            write_thumbnail(&first, &self.thumbnail_path(item.id));
        }
        self.persist(&item);
        self.inner.lock().items.insert(0, item.clone());
        self.changed();
        item
    }

    pub fn import_image(self: &Arc<Self>, path: &Path) -> Result<CaptureItem> {
        let image = imageops::load(path).context("Die Datei konnte nicht gelesen werden.")?;
        let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "Bild".into());
        self.add_image(image, 1.0, None, Some(format!("{stem} bearbeitet")))
    }

    // ------------------------------------------------------------ Schreiben

    fn begin_write(&self, id: Id) -> (Option<Done>, Done) {
        let mut inner = self.inner.lock();
        let done = Done::default();
        let previous = inner.writes.insert(id, done.clone());
        *inner.pending.entry(id).or_default() += 1;
        (previous, done)
    }

    fn end_write(&self, id: Id, (_, done): &(Option<Done>, Done)) {
        done.finish();
        let mut inner = self.inner.lock();
        if let Some(n) = inner.pending.get_mut(&id) {
            *n -= 1;
            if *n == 0 {
                inner.pending.remove(&id);
            }
        }
    }

    /// Wartet, bis alle Schreibvorgänge dieser Aufnahme auf der Platte sind.
    pub fn wait_until_written(&self, id: Id) {
        let last = self.inner.lock().writes.get(&id).cloned();
        if let Some(done) = last {
            done.wait();
        }
    }

    pub fn memory_image(&self, id: Id) -> Option<Arc<RgbaImage>> {
        let mut inner = self.inner.lock();
        // Nach einer Minute zählt der Zeitvorteil nicht mehr — dann lädt der Editor von der Platte.
        if inner.memory_until.is_some_and(|t| Instant::now() > t) {
            inner.memory.clear();
            inner.memory_until = None;
        }
        inner.memory.iter().find(|(i, _)| *i == id).map(|(_, img)| img.clone())
    }

    /// Original laden: aus dem Speicher, sonst von der Platte (wartet auf laufende Schreibvorgänge).
    pub fn load_original(&self, item: &CaptureItem) -> Result<Arc<RgbaImage>> {
        if let Some(img) = self.memory_image(item.id) {
            return Ok(img);
        }
        self.wait_until_written(item.id);
        imageops::load(&self.original_path(item))
            .or_else(|_| imageops::load(Path::new(&item.file_path)))
            .map(Arc::new)
            .map_err(|_| anyhow!("Das Original zu „{}“ ist nicht mehr vorhanden.", item.title()))
    }

    pub fn load_image_document(&self, id: Id) -> ImageDocument {
        std::fs::read(self.document_path(id)).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    pub fn load_video_document(&self, id: Id) -> VideoDocument {
        std::fs::read(self.document_path(id)).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    /// Schreibt die gerenderte Fassung in den Ablageordner und merkt sich den Bearbeitungsstand.
    /// Kehrt sofort zurück; geschrieben wird im Hintergrund, in Reihe nach früheren Schreibvorgängen.
    pub fn save_image(self: &Arc<Self>, promise: ImagePromise, document: &ImageDocument, item: &CaptureItem, size: (u32, u32), output_scale: f64) -> CaptureItem {
        let updated = self
            .bump(item.id, |i| {
                i.pixel_width = size.0;
                i.pixel_height = size.1;
                i.output_scale = Some(output_scale);
            })
            .unwrap_or_else(|| item.clone());
        let id = item.id;
        let doc = serde_json::to_vec(document).ok();
        let doc_path = self.document_path(id);
        let output = PathBuf::from(&item.file_path);
        let thumb_path = self.thumbnail_path(id);
        let handles = self.begin_write(id);
        let this = self.clone();
        std::thread::spawn(move || {
            if let Some(prev) = &handles.0 {
                prev.wait();
            }
            if let Some(doc) = doc {
                write_atomic(&doc_path, &doc);
            }
            if let Some(data) = promise.data() {
                write_atomic(&output, &data);
            }
            if let Some(rendered) = promise.image() {
                write_thumbnail(&rendered, &thumb_path);
                // Neues Vorschaubild → Oberfläche neu laden lassen.
                this.bump(id, |_| {});
                this.changed();
            }
            this.end_write(id, &handles);
        });
        self.changed();
        updated
    }

    /// Video speichern: exportierte Fassung (oder wieder das Original) in den Ablageordner.
    pub fn save_video(&self, exported: Option<&Path>, document: &VideoDocument, item: &CaptureItem) -> Result<CaptureItem> {
        write_atomic(&self.document_path(item.id), &serde_json::to_vec(document)?);
        let file = PathBuf::from(&item.file_path);
        if file.exists() {
            std::fs::remove_file(&file)?;
        }
        match exported {
            Some(src) => move_file(src, &file)?,
            // Keine Änderungen: Ablage wieder auf das Original zeigen lassen.
            None => link_or_copy(&self.original_path(item), &file)?,
        }
        let duration = knips_platform::media::probe(&file).ok().map(|i| i.duration);
        if let Ok(thumb) = knips_platform::media::thumbnail(&file, 640) {
            write_thumbnail(&thumb, &self.thumbnail_path(item.id));
        }
        let updated = self
            .bump(item.id, |i| {
                if duration.is_some() {
                    i.duration = duration;
                }
            })
            .unwrap_or_else(|| item.clone());
        self.changed();
        Ok(updated)
    }

    pub fn delete(&self, item: &CaptureItem) {
        let pending = {
            let mut inner = self.inner.lock();
            inner.items.retain(|i| i.id != item.id);
            inner.memory.retain(|(i, _)| *i != item.id);
            inner.writes.remove(&item.id)
        };
        let dir = self.directory(item.id);
        let file = PathBuf::from(&item.file_path);
        // Erst nach dem letzten Schreibvorgang löschen, sonst legt er die Datei wieder an.
        std::thread::spawn(move || {
            if let Some(done) = pending {
                done.wait();
            }
            if file.exists() {
                if let Err(err) = knips_platform::shell::trash(&file) {
                    log::warn!("Papierkorb fehlgeschlagen ({err:#}), lösche direkt");
                    let _ = std::fs::remove_file(&file);
                }
            }
            let _ = std::fs::remove_dir_all(&dir);
        });
        self.changed();
    }

    /// Platzbedarf der Originale in Bytes.
    pub fn storage_size(&self) -> u64 {
        fn walk(p: &Path) -> u64 {
            let Ok(entries) = std::fs::read_dir(p) else { return 0 };
            entries
                .flatten()
                .map(|e| match e.metadata() {
                    Ok(m) if m.is_dir() => walk(&e.path()),
                    Ok(m) => m.len(),
                    Err(_) => 0,
                })
                .sum()
        }
        walk(&paths::items_dir())
    }

    /// Entfernt alle Originale (Bearbeitung danach nicht mehr umkehrbar). Dateien im Ablageordner bleiben.
    pub fn purge_originals(&self) {
        let _ = std::fs::remove_dir_all(paths::items_dir());
        paths::ensure(&paths::items_dir());
        {
            let mut inner = self.inner.lock();
            inner.items.clear();
            inner.memory.clear();
        }
        self.changed();
    }

    // ------------------------------------------------------------ Intern

    /// Ändert eine Aufnahme und erhöht die Revision (Vorschaubilder laden dadurch neu).
    /// `None`, wenn sie inzwischen gelöscht wurde.
    pub fn bump(&self, id: Id, change: impl FnOnce(&mut CaptureItem)) -> Option<CaptureItem> {
        let updated = {
            let mut inner = self.inner.lock();
            let item = inner.items.iter_mut().find(|i| i.id == id)?;
            change(item);
            item.revision += 1;
            item.clone()
        };
        self.persist(&updated);
        Some(updated)
    }

    fn persist(&self, item: &CaptureItem) {
        if let Ok(data) = serde_json::to_vec(item) {
            write_atomic(&self.meta_path(item.id), &data);
        }
    }

    fn load(&self) {
        let Ok(dirs) = std::fs::read_dir(paths::items_dir()) else { return };
        // Originale + Bearbeitungsstand verfallen nach der eingestellten Frist; die Dateien im Ablageordner bleiben.
        let days = self.settings.get().retention_days;
        let cutoff = if days > 0 { chrono::Utc::now().timestamp_millis() - days as i64 * 86_400_000 } else { i64::MIN };
        let mut loaded = vec![];
        for dir in dirs.flatten().map(|e| e.path()).filter(|p| p.is_dir()) {
            let item: Option<CaptureItem> =
                std::fs::read(dir.join("item.json")).ok().and_then(|d| serde_json::from_slice(&d).ok());
            match item {
                Some(item) if item.created_at >= cutoff => loaded.push(item),
                _ => {
                    let _ = std::fs::remove_dir_all(&dir);
                }
            }
        }
        loaded.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        self.inner.lock().items = loaded;
    }

    fn unique_output_path(&self, base: &str, ext: &str) -> Result<PathBuf> {
        let folder = self.settings.save_folder();
        std::fs::create_dir_all(&folder).with_context(|| format!("Ablageordner {} nicht beschreibbar", folder.display()))?;
        let inner = self.inner.lock();
        let mut path = folder.join(format!("{base}.{ext}"));
        let mut n = 2;
        while path.exists() || inner.reserved.contains(&path) {
            path = folder.join(format!("{base} ({n}).{ext}"));
            n += 1;
        }
        Ok(path)
    }
}

/// Ein 4K-Original belegt ~33 MB — höchstens 4 im Speicher, eine Minute lang.
fn remember(inner: &mut Inner, id: Id, image: Arc<RgbaImage>) {
    inner.memory.retain(|(i, _)| *i != id);
    inner.memory.push_front((id, image));
    inner.memory.truncate(4);
    inner.memory_until = Some(Instant::now() + Duration::from_secs(60));
}

fn write_atomic(path: &Path, data: &[u8]) {
    let tmp = path.with_extension(format!("{}.tmp", path.extension().and_then(|e| e.to_str()).unwrap_or("")));
    let result = std::fs::write(&tmp, data).and_then(|_| std::fs::rename(&tmp, path));
    if let Err(err) = result {
        log::error!("Schreiben fehlgeschlagen ({}): {err}", path.display());
        let _ = std::fs::remove_file(&tmp);
    }
}

pub fn write_thumbnail(image: &RgbaImage, path: &Path) {
    let thumb = imageops::downscale(image, 640);
    match imageops::encode(&thumb, ImageFormat::Png) {
        Ok(data) => write_atomic(path, &data),
        Err(err) => log::error!("Vorschaubild fehlgeschlagen: {err:#}"),
    }
}

fn move_file(src: &Path, dst: &Path) -> Result<()> {
    if std::fs::rename(src, dst).is_err() {
        std::fs::copy(src, dst)?;
        let _ = std::fs::remove_file(src);
    }
    Ok(())
}

/// Hardlink spart bei Videos den doppelten Platz; beim Speichern wird die Ablage ersetzt,
/// das Original bleibt dadurch unberührt.
fn link_or_copy(src: &Path, dst: &Path) -> Result<()> {
    if std::fs::hard_link(src, dst).is_err() {
        std::fs::copy(src, dst)?;
    }
    Ok(())
}
