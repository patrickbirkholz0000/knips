//! Ablageorte (`Paths` in Utilities.swift). Selbsttests laufen isoliert in `KNIPS_TEST_DIR`.
//!
//! Daten und Einstellungen liegen in den Ordnern der App-Kennung (`%LOCALAPPDATA%\de.birkgroup.knips`,
//! `%APPDATA%\de.birkgroup.knips`) — dort, wo auch WebView2 und die Logs liegen und was „App-Daten
//! löschen“ beim Deinstallieren entfernt. Nie im Installationsordner (`%LOCALAPPDATA%\Knips`): Bis
//! Version 1.0.0 lagen die Originale genau dort und blieben nach dem Deinstallieren zurück;
//! `migrate_legacy` holt sie beim ersten Start an den neuen Ort.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, SystemTime};

/// Kennung der App (`identifier` in tauri.conf.json).
pub const IDENTIFIER: &str = "de.birkgroup.knips";

/// Testwurzel aus `KNIPS_TEST_DIR` — nur in Entwickler-Builds (Feature `dev`).
pub fn test_root() -> Option<&'static Path> {
    static ROOT: OnceLock<Option<PathBuf>> = OnceLock::new();
    ROOT.get_or_init(|| {
        if cfg!(feature = "dev") {
            std::env::var_os("KNIPS_TEST_DIR").map(PathBuf::from)
        } else {
            None
        }
    })
    .as_deref()
}

/// `%APPDATA%` (Roaming).
fn roaming() -> PathBuf {
    dirs::config_dir().unwrap_or_else(std::env::temp_dir)
}

/// `%LOCALAPPDATA%`.
fn local() -> PathBuf {
    dirs::data_local_dir().unwrap_or_else(std::env::temp_dir)
}

/// Einstellungen: `%APPDATA%\de.birkgroup.knips`.
pub fn config_dir() -> PathBuf {
    if let Some(root) = test_root() {
        return root.join("support");
    }
    roaming().join(IDENTIFIER)
}

/// Originale, Bearbeitungsstand, Vorschaubilder: `%LOCALAPPDATA%\de.birkgroup.knips`.
pub fn data_dir() -> PathBuf {
    if let Some(root) = test_root() {
        return root.join("support");
    }
    local().join(IDENTIFIER)
}

pub fn items_dir() -> PathBuf {
    data_dir().join("items")
}

/// Zwischendateien: `%TEMP%\Knips` (Vorschaubilder des Video-Editors, laufende Aufnahmen und
/// Exporte, Pins). Wird beim Start geleert (`clean_temp`).
pub fn temp_dir() -> PathBuf {
    let dir = temp_root();
    ensure(&dir);
    dir
}

fn temp_root() -> PathBuf {
    match test_root() {
        Some(root) => root.join("tmp"),
        None => std::env::temp_dir().join("Knips"),
    }
}

/// Vorschaubilder des Video-Editors (unzensierte Einzelbilder): `<temp>\video-thumbs\<id>-<rev>-<i>.jpg`.
pub fn video_thumbs_dir() -> PathBuf {
    temp_root().join("video-thumbs")
}

/// Standard-Ablageordner: Bilder\Knips.
pub fn default_save_folder() -> PathBuf {
    if let Some(root) = test_root() {
        return root.join("ablage");
    }
    dirs::picture_dir()
        .or_else(|| dirs::home_dir().map(|h| h.join("Pictures")))
        .unwrap_or_else(std::env::temp_dir)
        .join("Knips")
}

pub fn ensure(dir: &Path) {
    let _ = std::fs::create_dir_all(dir);
}

// ------------------------------------------------------------------ Umzug aus älteren Versionen

/// Ablageorte bis Version 1.0.0: (Einstellungen, Daten) = (`%APPDATA%\Knips`, `%LOCALAPPDATA%\Knips`).
/// Der Datenordner ist zugleich der Installationsordner. In der Test-Sandbox unter `legacy\`.
pub fn legacy_dirs() -> (PathBuf, PathBuf) {
    match test_root() {
        Some(root) => (root.join("legacy").join("Roaming").join("Knips"), root.join("legacy").join("Local").join("Knips")),
        None => (roaming().join("Knips"), local().join("Knips")),
    }
}

/// Ergebnis von `migrate_legacy`.
#[derive(Debug, Default, PartialEq)]
pub struct Migration {
    pub settings: bool,
    pub items: usize,
    pub failed: usize,
}

/// Verschieben; zwischen Laufwerken kopieren und löschen.
fn move_path(src: &Path, dst: &Path) -> std::io::Result<()> {
    if std::fs::rename(src, dst).is_ok() {
        return Ok(());
    }
    if src.is_dir() {
        std::fs::create_dir_all(dst)?;
        for entry in std::fs::read_dir(src)? {
            let entry = entry?;
            move_path(&entry.path(), &dst.join(entry.file_name()))?;
        }
        std::fs::remove_dir(src)
    } else {
        std::fs::copy(src, dst)?;
        std::fs::remove_file(src)
    }
}

/// Einstellungen und Aufnahmen älterer Versionen an den neuen Ort holen — einmal beim Start, bevor
/// etwas geladen wird. Was schon am neuen Ort liegt, gewinnt (die alte Kopie fällt weg). Leere alte
/// Ordner werden entfernt; der Installationsordner selbst bleibt (er enthält das Programm).
pub fn migrate_legacy() -> Migration {
    let (old_config, old_data) = legacy_dirs();
    let mut result = Migration::default();
    // Einstellungen (inkl. Nutzungsstatistik-Zustand).
    let old_settings = old_config.join("settings.json");
    if old_settings.is_file() {
        let new_settings = config_dir().join("settings.json");
        ensure(&config_dir());
        if new_settings.exists() {
            let _ = std::fs::remove_file(&old_settings);
        } else {
            match move_path(&old_settings, &new_settings) {
                Ok(()) => result.settings = true,
                Err(err) => {
                    log::error!("Einstellungen nicht übernommen ({}): {err}", old_settings.display());
                    result.failed += 1;
                }
            }
        }
    }
    let _ = std::fs::remove_file(old_config.join("settings.json.tmp"));
    let _ = std::fs::remove_dir(&old_config);
    // Originale + Bearbeitungsstand.
    let old_items = old_data.join("items");
    if let Ok(entries) = std::fs::read_dir(&old_items) {
        let new_items = items_dir();
        ensure(&new_items);
        for entry in entries.flatten() {
            let target = new_items.join(entry.file_name());
            let outcome = if target.exists() {
                std::fs::remove_dir_all(entry.path()).or_else(|_| std::fs::remove_file(entry.path()))
            } else {
                move_path(&entry.path(), &target).map(|_| result.items += 1)
            };
            if let Err(err) = outcome {
                log::error!("Aufnahme nicht übernommen ({}): {err}", entry.path().display());
                result.failed += 1;
            }
        }
        let _ = std::fs::remove_dir(&old_items);
    }
    let _ = std::fs::remove_dir(&old_data);
    if result != Migration::default() {
        log::info!("Daten älterer Version übernommen: {result:?}");
    }
    result
}

// ------------------------------------------------------------------ Zwischendateien

/// Zwischendateien entfernen: unzensierte Video-Einzelbilder, nach einem Absturz liegengebliebene
/// Aufnahmen/Exporte, Pins. `older_than`: nur, was so lange unverändert ist; `keep`: was gerade
/// gebraucht wird. Dateien, die ein Programm offen hält, lässt Windows ohnehin nicht löschen.
/// Liefert die Zahl der entfernten Dateien.
pub fn clean_temp(older_than: Option<Duration>, keep: &dyn Fn(&Path) -> bool) -> usize {
    fn walk(dir: &Path, older_than: Option<Duration>, keep: &dyn Fn(&Path) -> bool, now: SystemTime) -> usize {
        let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
        let mut removed = 0;
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                removed += walk(&path, older_than, keep, now);
                let _ = std::fs::remove_dir(&path);
                continue;
            }
            if keep(&path) {
                continue;
            }
            let age = meta.modified().ok().and_then(|m| now.duration_since(m).ok()).unwrap_or_default();
            if older_than.is_some_and(|min| age < min) {
                continue;
            }
            if std::fs::remove_file(&path).is_ok() {
                removed += 1;
            }
        }
        removed
    }
    walk(&temp_root(), older_than, keep, SystemTime::now())
}

/// Vorschaubilder einer Aufnahme im Video-Editor entfernen (`except`: die gerade erzeugten behalten).
pub fn remove_video_thumbs(id: &str, except: &[PathBuf]) {
    let Ok(entries) = std::fs::read_dir(video_thumbs_dir()) else { return };
    let prefix = format!("{id}-");
    for entry in entries.flatten() {
        let path = entry.path();
        if entry.file_name().to_string_lossy().starts_with(&prefix) && !except.contains(&path) {
            let _ = std::fs::remove_file(&path);
        }
    }
}
