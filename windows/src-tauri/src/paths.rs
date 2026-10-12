//! Ablageorte (`Paths` in Utilities.swift). Selbsttests laufen isoliert in `KNIPS_TEST_DIR`.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

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

/// Einstellungen: `%APPDATA%\Knips`.
pub fn config_dir() -> PathBuf {
    if let Some(root) = test_root() {
        return root.join("support");
    }
    dirs::config_dir().unwrap_or_else(std::env::temp_dir).join("Knips")
}

/// Originale, Bearbeitungsstand, Vorschaubilder: `%LOCALAPPDATA%\Knips`.
pub fn data_dir() -> PathBuf {
    if let Some(root) = test_root() {
        return root.join("support");
    }
    dirs::data_local_dir().unwrap_or_else(std::env::temp_dir).join("Knips")
}

pub fn items_dir() -> PathBuf {
    data_dir().join("items")
}

pub fn temp_dir() -> PathBuf {
    let dir = match test_root() {
        Some(root) => root.join("tmp"),
        None => std::env::temp_dir().join("Knips"),
    };
    ensure(&dir);
    dir
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
