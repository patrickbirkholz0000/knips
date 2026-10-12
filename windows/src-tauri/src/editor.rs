//! Bild-Editor: Sitzungen, Texterkennung im Hintergrund, Speichern der gerenderten Pixel
//! (`EditorWindowController` in EditorWindow.swift). Gerendert wird in der Seite
//! (`src/editor/renderer.ts`); hier kommen die fertigen Pixel an.

use std::collections::{BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, Result};
use knips_core::model::{CaptureItem, Finding, Id, ImageDocument, ImageFormat, SensitiveKind, TextLine};
use knips_core::RgbaImage;
use parking_lot::Mutex;
use serde::Serialize;

use crate::app::knips;
use crate::promise::output_promise;

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct EditorSession {
    pub item: CaptureItem,
    pub document: ImageDocument,
    pub original_path: String,
    pub scale: f64,
    pub initial_tool: Option<String>,
}

#[derive(Default)]
struct Entry {
    staged: Option<ImageDocument>,
    lines: Option<Arc<Vec<TextLine>>>,
    tool: Option<String>,
}

#[derive(Default)]
pub struct Editors {
    entries: Mutex<HashMap<Id, Entry>>,
    /// Hält die Texterkennung je Aufnahme in Reihe (nur ein Lauf gleichzeitig).
    ocr_lock: Mutex<()>,
}

impl Editors {
    /// Werkzeug für das nächste Öffnen (z. B. „Zensieren“ aus dem Verlauf).
    pub fn set_initial_tool(&self, id: Id, tool: Option<String>) {
        self.entries.lock().entry(id).or_default().tool = tool;
    }

    pub fn open(&self, id: Id) -> Result<EditorSession> {
        let k = knips();
        let item = k.store.item(id).ok_or_else(|| anyhow!("Aufnahme nicht gefunden"))?;
        // Original muss auf der Platte liegen, bevor die Seite es lädt.
        k.store.wait_until_written(id);
        let original = k.store.original_path(&item);
        let original_path = if original.exists() { original } else { PathBuf::from(&item.file_path) };
        if !original_path.exists() {
            return Err(anyhow!("Das Original zu „{}“ ist nicht mehr vorhanden.", item.title()));
        }
        let initial_tool = self.entries.lock().entry(id).or_default().tool.take();
        Ok(EditorSession {
            document: k.store.load_image_document(id),
            original_path: original_path.to_string_lossy().into_owned(),
            scale: item.scale.max(1.0),
            initial_tool,
            item,
        })
    }

    /// Erkannte Zeilen des Originals (einmal je Sitzung).
    pub fn text_lines(&self, id: Id) -> Result<Arc<Vec<TextLine>>> {
        if let Some(lines) = self.entries.lock().get(&id).and_then(|e| e.lines.clone()) {
            return Ok(lines);
        }
        let _guard = self.ocr_lock.lock();
        if let Some(lines) = self.entries.lock().get(&id).and_then(|e| e.lines.clone()) {
            return Ok(lines);
        }
        let k = knips();
        let item = k.store.item(id).ok_or_else(|| anyhow!("Aufnahme nicht gefunden"))?;
        let image = k.store.load_original(&item)?;
        let lines = Arc::new(knips_platform::ocr::recognize(&image)?);
        self.entries.lock().entry(id).or_default().lines = Some(lines.clone());
        Ok(lines)
    }

    pub fn detect(&self, id: Id, kinds: &BTreeSet<SensitiveKind>) -> Result<Vec<Finding>> {
        let lines = self.text_lines(id)?;
        Ok(knips_core::sensitive::detect(&lines, kinds))
    }

    pub fn stage(&self, id: Id, document: ImageDocument) {
        self.entries.lock().entry(id).or_default().staged = Some(document);
    }

    /// Gerendertes Bild (volle Auflösung) übernehmen: speichern, kopieren oder anpinnen.
    pub fn commit(&self, id: Id, action: &str, image: RgbaImage) -> Result<CaptureItem> {
        let k = knips();
        let item = k.store.item(id).ok_or_else(|| anyhow!("Aufnahme nicht gefunden"))?;
        let scale = item.scale.max(1.0);
        if action == "pin" {
            k.pins.pin(Arc::new(image), scale)?;
            return Ok(item);
        }
        let document = self.entries.lock().get(&id).and_then(|e| e.staged.clone()).unwrap_or_else(|| k.store.load_image_document(id));
        let settings = k.settings.get();
        let factor = settings.output_factor(scale);
        // Das Format folgt der vorhandenen Datei, damit Endung und Inhalt zusammenpassen.
        let format = std::path::Path::new(&item.file_path)
            .extension()
            .and_then(|e| e.to_str())
            .and_then(ImageFormat::from_extension)
            .unwrap_or(settings.image_format);
        let size = (((image.width() as f64) * factor).round() as u32, ((image.height() as f64) * factor).round() as u32);
        let promise = output_promise(factor, format, move || Some(image));
        let updated = k.store.save_image(promise.clone(), &document, &item, size, scale * factor);
        if action == "copy" {
            let _ = knips_platform::clipboard::set_image(Arc::new(promise));
        }
        Ok(updated)
    }

    pub fn close(&self, id: Id) {
        self.entries.lock().remove(&id);
    }
}
